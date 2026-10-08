-- The LFG feed: who is looking for a group, who is building one, who is recruiting for a
-- guild, who is selling.
--
-- It reads the public channels you are in and keeps the newest post of each player, with
-- the dungeon or raid it names and the roles it asks for. Nothing is sent anywhere and
-- nothing is shared with other players: it is a sorted view of chat you already receive.
-- On Forever the public channels reach your zone or city only, so that is what it shows.
--
-- Written for World of Warcraft: Forever: the classic dungeons and raids plus Forever's
-- own. There is no Mythic+ or other retail-only activity here.

local ADDON_NAME, RR = ...

local C = RR.COLOR

local MAX_ENTRIES = 200
local EXPIRY = 15 * 60          -- seconds a post stays in the list
local HIDE_FOR = 30 * 60        -- seconds a dismissed player stays hidden
local FEED_ROWS = 12
local FEED_ROW_H = 30

local entries = {}              -- newest first
local byName = {}
local filter = "all"            -- all | lfm | lfg | guild | trade
local search = ""

local page, rows, countText, sortButton, boostButton, restoreButton, contentButton
local needButtons = {}
local offset = 0

-- Classify ----------------------------------------------------------------------

-- Names and abbreviations as players type them, lower case. Every word is matched on word
-- boundaries, and of all the words found in a post the longest wins: "ruins of lordaeron"
-- beats "ruins of ahn", "dire maul" beats "dm".
-- Forever's own dungeons and raids are taken from what other Forever addons list; they
-- have not been seen in a live group post by this addon's author yet.
local ACTIVITIES = {
    { "Naxx", "naxx", "naxxramas" },
    { "AQ40", "aq40", "aq 40", "temple of ahn'qiraj", "temple of ahnqiraj" },
    { "AQ20", "aq20", "aq 20", "ruins of ahn'qiraj", "ruins of ahnqiraj" },
    { "BWL", "bwl", "blackwing lair" },
    { "MC", "mc", "molten core" },
    { "Onyxia", "ony", "onyxia", "onyxia's lair" },
    { "ZG", "zg", "zul'gurub", "zulgurub", "zul gurub" },
    { "Hyjal Summit", "hyjal summit", "hyjal" },
    { "Barrow Deeps", "barrow deeps", "barrow" },
    { "UBRS", "ubrs", "upper blackrock" },
    { "LBRS", "lbrs", "lower blackrock" },
    { "BRD", "brd", "blackrock depths" },
    { "Stratholme", "strat", "stratholme", "strat live", "strat ud", "strat undead" },
    { "Scholomance", "scholo", "scholomance" },
    { "Dire Maul", "dire maul", "dm east", "dm west", "dm north", "dme", "dmw", "dmn", "dmt", "tribute" },
    { "Sunken Temple", "st", "sunken temple", "atal'hakkar", "atalhakkar" },
    { "Maraudon", "mara", "maraudon" },
    { "Zul'Farrak", "zf", "zul'farrak", "zulfarrak", "zul farrak" },
    { "Uldaman", "ulda", "uldaman" },
    { "RFD", "rfd", "razorfen downs" },
    { "Scarlet Monastery", "sm", "scarlet monastery", "cath", "cathedral", "armory", "library", "graveyard" },
    { "RFK", "rfk", "razorfen kraul" },
    { "Gnomeregan", "gnomer", "gnomeregan" },
    { "Stockade", "stocks", "stockade", "stockades" },
    { "BFD", "bfd", "blackfathom" },
    { "SFK", "sfk", "shadowfang" },
    { "Deadmines", "vc", "deadmines", "dead mines" },
    { "WC", "wc", "wailing caverns" },
    { "RFC", "rfc", "ragefire" },
    { "Hall of Thanes", "hall of thanes", "thanes" },
    { "Ruins of Lordaeron", "ruins of lordaeron", "lordaeron" },
    { "Excavation Site", "excavation site", "excavation" },
    { "City of Dalaran", "city of dalaran", "dalaran" },
    { "The Drowned City", "the drowned city", "drowned city" },
    { "Krol'dok Stronghold", "krol'dok stronghold", "krol'dok", "kroldok" },
    { "Alcaz Prison", "alcaz prison", "alcaz" },
    { "Blackmaw Hold", "blackmaw hold", "blackmaw" },
    { "Shaper's Terrace", "shaper's terrace", "shapers terrace" },
}

-- Which of them are raids, for the content filter.
local RAIDS = { ["Naxx"] = true, ["AQ40"] = true, ["AQ20"] = true, ["BWL"] = true, ["MC"] = true, ["Onyxia"] = true,
    ["ZG"] = true, ["Hyjal Summit"] = true, ["Barrow Deeps"] = true }

local function WordPattern(word)
    -- %f[%w] and %f[%W] are word boundaries; punctuation in the word is taken literally
    return "%f[%w]" .. string.gsub(word, "%p", "%%%0") .. "%f[%W]"
end

local activityWords = {}
for _, entry in ipairs(ACTIVITIES) do
    for index = 2, #entry do
        activityWords[#activityWords + 1] = { pattern = WordPattern(entry[index]), length = #entry[index], label = entry[1] }
    end
end
local DM_ALONE = WordPattern("dm")

local function HasWord(text, word)
    return string.find(text, WordPattern(word)) ~= nil
end

local function HasAny(text, words)
    for _, word in ipairs(words) do
        if HasWord(text, word) then return true end
    end
    return false
end

-- A bare "DM" is The Deadmines for a low character and Dire Maul for a high one. The
-- poster's level is not known, so your own decides: people post where they level.
local function BareDM()
    return (UnitLevel("player") or 60) < 40 and "Deadmines" or "Dire Maul"
end

local function ActivityOf(text)
    local best, bestLength
    for _, word in ipairs(activityWords) do
        if (not bestLength or word.length > bestLength) and string.find(text, word.pattern) then
            best, bestLength = word.label, word.length
        end
    end
    if not best and string.find(text, DM_ALONE) then return BareDM() end
    return best
end

local BOOST_WORDS = { "boost", "boosts", "boosting", "carry", "carries", "gdkp", "services", "powerlevel", "powerleveling" }
local TRADE_WORDS = { "wts", "wtb", "wtt", "selling", "buying" }
local GUILD_WORDS = { "recruiting", "recruits", "recruit", "recruitment" }

-- Plain lower-case text: colour codes and links leave only what the player sees.
local function Plain(message)
    local text = string.gsub(message, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    text = string.gsub(text, "|H.-|h(.-)|h", "%1")
    return " " .. string.lower(text) .. " "
end

-- kind, roles, activity. No kind: an ordinary chat line, not kept.
local function Classify(message)
    local text = Plain(message)
    local asksGroup = HasWord(text, "lfm") or string.find(text, "%f[%w]lf%d+m%f[%W]") or string.find(text, "%f[%w]lf %d+")
        or string.find(text, "looking for more") or string.find(text, "need %a* ?tank")
        or string.find(text, "need %a* ?heal") or string.find(text, "need %a* ?dps")
        or HasAny(text, { "lf tank", "lf healer", "lf heal", "lf heals", "lf dps" })
    local kind
    if HasAny(text, BOOST_WORDS) then
        kind = "boost"
    elseif HasWord(text, "guild") and (HasAny(text, GUILD_WORDS) or string.find(text, "looking for members")
        or string.find(text, "lf members") or string.find(text, "lf more members")) then
        kind = "guild"
    elseif HasAny(text, TRADE_WORDS) then
        kind = "trade"
    elseif asksGroup then
        kind = "lfm"
    elseif HasWord(text, "lfg") or string.find(text, "looking for group") or HasWord(text, "lf group") then
        kind = "lfg"
    end
    if not kind then return nil end

    local roles = {}
    if string.find(text, "tank") then roles.tank = true end
    if string.find(text, "heal") then roles.heal = true end
    if string.find(text, "dps") or string.find(text, "damage") or HasWord(text, "dd") then roles.dps = true end

    local activity
    if kind == "lfm" or kind == "lfg" then activity = ActivityOf(text) end
    return kind, roles, activity
end
RR.ClassifyPost = Classify

-- Collect -----------------------------------------------------------------------

local function Trim()
    local now = GetTime()
    for index = #entries, 1, -1 do
        local entry = entries[index]
        if index > MAX_ENTRIES or now - entry.time > EXPIRY then
            if byName[entry.name] == entry then byName[entry.name] = nil end
            table.remove(entries, index)
        end
    end
end

-- Players dismissed with a right-click: name -> the clock time they come back.
local function Hidden()
    RR.db.feedHidden = RR.db.feedHidden or {}
    return RR.db.feedHidden
end

local function IsHidden(name)
    local hidden = Hidden()
    local till = hidden[name]
    if not till then return false end
    if time() >= till then
        hidden[name] = nil
        return false
    end
    return true
end

local function HiddenCount()
    local count = 0
    for name in pairs(Hidden()) do
        if IsHidden(name) then count = count + 1 end
    end
    return count
end

-- A guild mate or a friend: listed first and marked.
local function IsMate(guid)
    if type(guid) ~= "string" or (issecretvalue and issecretvalue(guid)) then return false end
    return (IsGuildMember and IsGuildMember(guid)) or (C_FriendList.IsFriend and C_FriendList.IsFriend(guid)) or false
end

function RR.AddPost(name, message, channel, guid)
    local kind, roles, activity = Classify(message)
    if not kind then return false end
    local old = byName[name]
    if old then
        for index, entry in ipairs(entries) do
            if entry == old then table.remove(entries, index) break end
        end
    end
    local now = GetTime()
    local entry = { name = name, text = message, kind = kind, roles = roles, activity = activity,
        channel = channel, time = now, first = old and old.first or now, count = (old and old.count or 0) + 1,
        mate = IsMate(guid) }
    table.insert(entries, 1, entry)
    byName[name] = entry
    Trim()
    if RR.RefreshFeedUI then RR.RefreshFeedUI() end
    return true
end

local function OnChat(_, _, text, sender, _, _, _, _, _, _, channelBaseName, _, _, guid)
    -- In an encounter the client hands chat over as secret values: such a line is skipped.
    if issecretvalue and (issecretvalue(text) or issecretvalue(sender)) then return end
    if type(text) ~= "string" or type(sender) ~= "string" then return end
    local name = Ambiguate and Ambiguate(sender, "short") or sender
    if name == RR.UnitName("player") then return end
    -- someone on your ignore list never shows
    if C_FriendList.IsIgnored and C_FriendList.IsIgnored(name) then return end
    RR.AddPost(name, text, channelBaseName or "", guid)
end

-- The list ----------------------------------------------------------------------

local KIND_LABEL = { lfm = "LFM", lfg = "LFG", guild = "Guild", trade = "Trade", boost = "Boost" }
local KIND_COLOR = { lfm = C.good, lfg = C.accent, guild = { 0.78, 0.62, 1.00 }, trade = C.warn, boost = C.textDim }

local function HideBoosts()
    return RR.db.feedHideBoosts ~= false
end

-- Role filter: tank / heal / dps -> true. With any of them on, only group posts that name
-- one of those roles stay: groups that need it, and players who offer it.
local function Needs()
    RR.db.feedNeeds = RR.db.feedNeeds or {}
    return RR.db.feedNeeds
end

local CONTENT_LABEL = { all = "Content: all", dungeon = "Content: dungeons", raid = "Content: raids" }
local CONTENT_NEXT = { all = "dungeon", dungeon = "raid", raid = "all" }

local function Content()
    return CONTENT_LABEL[RR.db.feedContent] and RR.db.feedContent or "all"
end

local function PassesFilters(entry, needs, anyNeed, content)
    if anyNeed then
        if entry.kind ~= "lfm" and entry.kind ~= "lfg" then return false end
        if not ((needs.tank and entry.roles.tank) or (needs.heal and entry.roles.heal) or (needs.dps and entry.roles.dps)) then
            return false
        end
    end
    if content ~= "all" then
        if not entry.activity then return false end
        if (RAIDS[entry.activity] or false) ~= (content == "raid") then return false end
    end
    return true
end

local function Visible()
    local list = {}
    local needle = string.lower(search or "")
    local hideBoosts = HideBoosts()
    local needs, content = Needs(), Content()
    local anyNeed = needs.tank or needs.heal or needs.dps
    for _, entry in ipairs(entries) do
        if (filter == "all" or entry.kind == filter)
            and PassesFilters(entry, needs, anyNeed, content)
            and not (hideBoosts and entry.kind == "boost")
            and not IsHidden(entry.name)
            and (needle == "" or string.find(string.lower(entry.name .. " " .. entry.text .. " "
                .. (entry.activity or "")), needle, 1, true)) then
            list[#list + 1] = entry
        end
    end
    local byDungeon = RR.db.feedSort == "dungeon"
    -- guild mates and friends first; then newest first, or grouped by dungeon
    table.sort(list, function(a, b)
        if a.mate ~= b.mate then return a.mate end
        if byDungeon and (a.activity or "~") ~= (b.activity or "~") then
            return (a.activity or "~") < (b.activity or "~")
        end
        return a.time > b.time
    end)
    return list
end

local function Ago(seconds)
    if seconds < 60 then return math.floor(seconds) .. "s" end
    return math.floor(seconds / 60) .. "m"
end

function RR.RefreshFeedUI()
    if not page or not page:IsShown() then return end
    Trim()
    local list = Visible()
    local maxOffset = math.max(0, #list - FEED_ROWS)
    if offset > maxOffset then offset = maxOffset end
    for index = 1, FEED_ROWS do
        local row = rows[index]
        local entry = list[index + offset]
        row.entry = entry
        if entry then
            local color = KIND_COLOR[entry.kind]
            row.kind:SetText(KIND_LABEL[entry.kind])
            row.kind:SetTextColor(color[1], color[2], color[3])
            row.name:SetText((entry.mate and RR.Hex(C.warn) .. "*|r " or "") .. entry.name)
            row.what:SetText(entry.activity or "")
            local roles = (entry.roles.tank and RR.Hex(C.tank) .. "T|r " or "")
                .. (entry.roles.heal and RR.Hex(C.healer) .. "H|r " or "")
                .. (entry.roles.dps and RR.Hex(C.dps) .. "D|r" or "")
            row.roles:SetText(roles)
            row.text:SetText(entry.text)
            row.ago:SetText(Ago(GetTime() - entry.time))
            row.invite:SetShown(entry.kind == "lfg")
            row:Show()
        else
            row:Hide()
        end
    end
    local hidden = HiddenCount()
    countText:SetText(string.format("%d post(s), %d shown  |  posts stay %d minutes", #entries, #list, EXPIRY / 60))
    sortButton.text:SetText(RR.db.feedSort == "dungeon" and "Sort: dungeon" or "Sort: newest")
    boostButton:SetColor(HideBoosts() and C.accent or C.accentDim)
    contentButton.text:SetText(CONTENT_LABEL[Content()])
    contentButton:SetColor(Content() ~= "all" and C.accent or C.accentDim)
    local needs = Needs()
    for _, button in ipairs(needButtons) do
        button:SetColor(needs[button.role] and button.textColor or C.accentDim)
    end
    restoreButton.text:SetText(string.format("Bring back hidden (%d)", hidden))
    restoreButton:SetShown(hidden > 0)
end

function RR.FeedCount()
    return #entries
end

-- Row actions -------------------------------------------------------------------

local function Whisper(name)
    ChatFrameUtil.SendTell(name)
end

local function Who(name)
    C_FriendList.SendWho('n-"' .. name .. '"')
end

local function Dismiss(name)
    Hidden()[name] = time() + HIDE_FOR
    RR.RefreshFeedUI()
end

-- Build -------------------------------------------------------------------------

function RR.Feed_Init()
    local events = CreateFrame("Frame")
    events:RegisterEvent("CHAT_MSG_CHANNEL")
    events:SetScript("OnEvent", OnChat)
end

function RR.FeedUI_Init()
    if not RR.NewPage then return end
    local Label, Button, EditBox = RR.UI_Label, RR.UI_Button, RR.UI_EditBox

    page = RR.NewPage("feed")
    local panel = CreateFrame("Frame", nil, page)
    panel:SetPoint("TOPLEFT", 10, -10)
    panel:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -10, 12)
    RR.UI_Section(panel)

    local title = RR.UI_Heading(panel, "WHAT PEOPLE ARE POSTING")
    title:SetPoint("TOPLEFT", 10, -10)

    local filterButtons = {}
    local function SetFilter(value)
        filter = value
        offset = 0
        for _, button in ipairs(filterButtons) do
            button:SetColor(button.value == value and C.accent or C.accentDim)
        end
        RR.RefreshFeedUI()
    end
    for index, def in ipairs({ { "all", "All" }, { "lfm", "LFM" }, { "lfg", "LFG" }, { "guild", "Guild" }, { "trade", "Trade" } }) do
        local button = Button(panel, def[2], 50, 18)
        button.value = def[1]
        if index == 1 then
            button:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
        else
            button:SetPoint("LEFT", filterButtons[index - 1], "RIGHT", 4, 0)
        end
        button:SetScript("OnClick", function(self) SetFilter(self.value) end)
        filterButtons[index] = button
    end

    local searchLabel = Label(panel, "search", 10, C.textDim)
    searchLabel:SetPoint("LEFT", filterButtons[#filterButtons], "RIGHT", 12, 0)
    local searchBox = EditBox(panel, 120, 18)
    searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 6, 0)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function(self)
        search = self:GetText() or ""
        offset = 0
        RR.RefreshFeedUI()
    end)

    local clear = Button(panel, "Clear", 50, 18)
    clear:SetPoint("TOPRIGHT", -10, -28)
    clear:SetScript("OnClick", function()
        wipe(entries)
        wipe(byName)
        RR.RefreshFeedUI()
    end)

    boostButton = Button(panel, "Hide boosts", 84, 18)
    boostButton:SetPoint("RIGHT", clear, "LEFT", -4, 0)
    boostButton:SetScript("OnClick", function()
        RR.db.feedHideBoosts = not HideBoosts()
        offset = 0
        RR.RefreshFeedUI()
    end)
    boostButton:SetScript("OnEnter", function(self)
        self:SetHover(true)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Hide boosts", 1, 1, 1)
        GameTooltip:AddLine("Leaves out posts that sell boosts, carries, GDKP runs and services.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    boostButton:SetScript("OnLeave", function(self) self:SetHover(false) GameTooltip:Hide() end)

    sortButton = Button(panel, "Sort: newest", 94, 18)
    sortButton:SetPoint("RIGHT", boostButton, "LEFT", -4, 0)
    sortButton:SetScript("OnClick", function()
        RR.db.feedSort = RR.db.feedSort == "dungeon" and "new" or "dungeon"
        offset = 0
        RR.RefreshFeedUI()
    end)
    sortButton:SetScript("OnEnter", function(self)
        self:SetHover(true)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Sort", 1, 1, 1)
        GameTooltip:AddLine("Newest first, or grouped by dungeon. Guild mates and friends (*) are always on top.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    sortButton:SetScript("OnLeave", function(self) self:SetHover(false) GameTooltip:Hide() end)

    -- second line: role and content filters
    local needLabel = Label(panel, "role", 10, C.textDim)
    needLabel:SetPoint("TOPLEFT", filterButtons[1], "BOTTOMLEFT", 2, -9)
    for index, def in ipairs({ { "tank", "Tank", C.tank }, { "heal", "Healer", C.healer }, { "dps", "DPS", C.dps } }) do
        local button = Button(panel, def[2], 54, 18)
        button.role = def[1]
        button.textColor = def[3]
        if index == 1 then
            button:SetPoint("LEFT", needLabel, "RIGHT", 8, 0)
        else
            button:SetPoint("LEFT", needButtons[index - 1], "RIGHT", 4, 0)
        end
        button:SetScript("OnClick", function(self)
            local needs = Needs()
            needs[self.role] = not needs[self.role] or nil
            offset = 0
            RR.RefreshFeedUI()
        end)
        button:SetScript("OnEnter", function(self)
            self:SetHover(true)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:AddLine("Role filter", 1, 1, 1)
            GameTooltip:AddLine("Only group posts that name this role: groups that need it and players who offer it. "
                .. "Several can be on at once.", 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function(self) self:SetHover(false) GameTooltip:Hide() end)
        needButtons[index] = button
    end
    contentButton = Button(panel, CONTENT_LABEL.all, 122, 18)
    contentButton:SetPoint("LEFT", needButtons[#needButtons], "RIGHT", 14, 0)
    contentButton:SetScript("OnClick", function()
        RR.db.feedContent = CONTENT_NEXT[Content()]
        offset = 0
        RR.RefreshFeedUI()
    end)
    contentButton:SetScript("OnEnter", function(self)
        self:SetHover(true)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Content filter", 1, 1, 1)
        GameTooltip:AddLine("All posts, only posts that name a dungeon, or only posts that name a raid. Click to change.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    contentButton:SetScript("OnLeave", function(self) self:SetHover(false) GameTooltip:Hide() end)

    local header = CreateFrame("Frame", nil, panel)
    header:SetPoint("TOPLEFT", 10, -84)
    header:SetPoint("TOPRIGHT", -10, -84)
    header:SetHeight(18)
    for _, column in ipairs({ { "", 4 }, { "Player", 46 }, { "For", 150 }, { "Needs", 262 }, { "Message", 310 } }) do
        local text = Label(header, column[1], 10, C.textDim)
        text:SetPoint("LEFT", column[2], 0)
    end

    rows = {}
    for index = 1, FEED_ROWS do
        local row = CreateFrame("Frame", nil, panel)
        row:SetHeight(FEED_ROW_H - 2)
        row:SetPoint("TOPLEFT", 10, -104 - (index - 1) * FEED_ROW_H)
        row:SetPoint("TOPRIGHT", -10, -104 - (index - 1) * FEED_ROW_H)
        RR.UI_Row(row, index)

        row.kind = Label(row, "", 10, C.text)
        row.kind:SetPoint("LEFT", 4, 0)
        row.kind:SetWidth(38)
        row.kind:SetJustifyH("LEFT")
        row.name = Label(row, "", 11, C.text)
        row.name:SetPoint("LEFT", 46, 0)
        row.name:SetWidth(100)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.what = Label(row, "", 10, C.warn)
        row.what:SetPoint("LEFT", 150, 0)
        row.what:SetWidth(108)
        row.what:SetJustifyH("LEFT")
        row.what:SetWordWrap(false)
        row.roles = Label(row, "", 10, C.good)
        row.roles:SetPoint("LEFT", 262, 0)
        row.roles:SetWidth(44)
        row.roles:SetJustifyH("LEFT")
        row.text = Label(row, "", 10, C.textDim)
        row.text:SetPoint("LEFT", 310, 0)
        row.text:SetPoint("RIGHT", -204, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.ago = Label(row, "", 10, C.textDim)
        row.ago:SetPoint("RIGHT", -166, 0)

        row.who = Button(row, "Who", 36, 20)
        row.who:SetPoint("RIGHT", -124, 0)
        row.who:SetScript("OnClick", function()
            if row.entry then Who(row.entry.name) end
        end)
        row.whisper = Button(row, "Whisper", 58, 20)
        row.whisper:SetPoint("RIGHT", -62, 0)
        row.whisper:SetScript("OnClick", function()
            if row.entry then Whisper(row.entry.name) end
        end)
        row.invite = Button(row, "Invite", 54, 20)
        row.invite:SetPoint("RIGHT", -4, 0)
        row.invite:SetScript("OnClick", function()
            if row.entry then RR.InviteUnit(row.entry.name) end
        end)

        row:EnableMouse(true)
        -- left: whisper, shift-left: who, right: hide this player for a while
        row:SetScript("OnMouseUp", function(self, button)
            local entry = self.entry
            if not entry then return end
            if button == "RightButton" then
                Dismiss(entry.name)
            elseif IsShiftKeyDown() then
                Who(entry.name)
            else
                Whisper(entry.name)
            end
        end)
        row:SetScript("OnEnter", function(self)
            local entry = self.entry
            if not entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:AddLine(entry.name, 1, 1, 1)
            GameTooltip:AddLine(entry.text, 0.9, 0.9, 0.9, true)
            if entry.channel ~= "" then GameTooltip:AddLine(entry.channel, 0.5, 0.5, 0.5) end
            if entry.count > 1 then
                GameTooltip:AddLine(string.format("Posted %d times, first %s ago", entry.count, Ago(GetTime() - entry.first)),
                    0.5, 0.5, 0.5)
            end
            if entry.mate then GameTooltip:AddLine("Guild mate or friend", C.warn[1], C.warn[2], C.warn[3]) end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click: whisper.  Shift-click: who.  Right-click: hide for 30 minutes.", 0.6, 0.8, 1, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[index] = row
    end

    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta)
        RR.RefreshFeedUI()
    end)

    countText = Label(panel, "", 10, C.textDim)
    countText:SetPoint("BOTTOMLEFT", 10, 8)
    restoreButton = Button(panel, "Bring back hidden", 136, 18)
    restoreButton:SetPoint("LEFT", countText, "RIGHT", 10, 0)
    restoreButton:SetScript("OnClick", function()
        wipe(Hidden())
        RR.RefreshFeedUI()
    end)
    restoreButton:Hide()
    local note = Label(panel, "Reads the channels you are in. On Forever they reach your zone or city only.", 10, C.textDim)
    note:SetPoint("BOTTOMRIGHT", -10, 8)

    page:SetScript("OnShow", function() RR.RefreshFeedUI() end)
    page.elapsed = 0
    page:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed >= 5 then
            self.elapsed = 0
            RR.RefreshFeedUI()
        end
    end)
    SetFilter("all")
end
