-- The LFG feed: who is looking for a group, who is building one, who is selling.
--
-- It reads the public channels you are in and keeps the newest post of each player that
-- says LFG, LFM or WTS/WTB/WTT, with the dungeon or raid it names and the roles it asks
-- for. Nothing is sent anywhere and nothing is shared with other players: it is a sorted
-- view of chat you already receive.
--
-- Written for World of Warcraft: Forever, so the activity list is the dungeons and raids
-- of the classic world. There is no Mythic+ or other retail-only activity here.

local ADDON_NAME, RR = ...

local C = RR.COLOR

local MAX_ENTRIES = 200
local EXPIRY = 15 * 60          -- seconds a post stays in the list
local FEED_ROWS = 12
local FEED_ROW_H = 30

local entries = {}              -- newest first
local byName = {}
local filter = "all"            -- all | lfm | lfg | trade
local search = ""

local page, rows, countText
local offset = 0

-- Classify ----------------------------------------------------------------------

-- Abbreviations as players type them. A pattern is matched on word boundaries against the
-- lower-case message. Order matters where one name is inside another (UBRS before BRS).
local ACTIVITIES = {
    { "Naxx", { "naxx", "naxxramas" } },
    { "AQ40", { "aq40", "aq 40", "temple of ahn" } },
    { "AQ20", { "aq20", "aq 20", "ruins of ahn" } },
    { "BWL", { "bwl", "blackwing lair" } },
    { "MC", { "mc", "molten core" } },
    { "Onyxia", { "ony", "onyxia" } },
    { "ZG", { "zg", "zul'?gurub" } },
    { "UBRS", { "ubrs", "upper blackrock" } },
    { "LBRS", { "lbrs", "lower blackrock" } },
    { "BRD", { "brd", "blackrock depths" } },
    { "Stratholme", { "strat", "stratholme" } },
    { "Scholomance", { "scholo", "scholomance" } },
    { "Dire Maul", { "dire maul", "dm ?[enw]", "dm east", "dm west", "dm north", "dmt", "tribute" } },
    { "Sunken Temple", { "st", "sunken temple", "atal'?hakkar" } },
    { "Maraudon", { "mara", "maraudon" } },
    { "Zul'Farrak", { "zf", "zul'?farrak" } },
    { "Uldaman", { "ulda", "uldaman" } },
    { "RFD", { "rfd", "razorfen downs" } },
    { "Scarlet Monastery", { "sm", "scarlet monastery", "cath", "armory", "library", "graveyard" } },
    { "RFK", { "rfk", "razorfen kraul" } },
    { "Gnomeregan", { "gnomer", "gnomeregan" } },
    { "Stockade", { "stocks", "stockade", "stockades" } },
    { "BFD", { "bfd", "blackfathom" } },
    { "SFK", { "sfk", "shadowfang" } },
    { "Deadmines", { "vc", "deadmines", "dead mines" } },
    { "WC", { "wc", "wailing caverns" } },
    { "RFC", { "rfc", "ragefire" } },
}

local function HasWord(text, pattern)
    -- %f[%w] and %f[%W] are word boundaries
    return string.find(text, "%f[%w]" .. pattern .. "%f[%W]") ~= nil
end

local function Classify(message)
    local text = " " .. string.lower(message) .. " "
    local kind
    if HasWord(text, "wts") or HasWord(text, "wtb") or HasWord(text, "wtt") or HasWord(text, "selling")
        or HasWord(text, "buying") then
        kind = "trade"
    elseif HasWord(text, "lfm") or HasWord(text, "lf%d+m") or HasWord(text, "lf %d+")
        or string.find(text, "looking for more") or string.find(text, "need %a* ?tank")
        or string.find(text, "need %a* ?heal") or string.find(text, "need %a* ?dps")
        or HasWord(text, "lf tank") or HasWord(text, "lf healer") or HasWord(text, "lf heal")
        or HasWord(text, "lf dps") then
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
    if kind ~= "trade" then
        for _, entry in ipairs(ACTIVITIES) do
            for _, pattern in ipairs(entry[2]) do
                if HasWord(text, pattern) then activity = entry[1] break end
            end
            if activity then break end
        end
    end
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

function RR.AddPost(name, message, channel)
    local kind, roles, activity = Classify(message)
    if not kind then return false end
    local old = byName[name]
    if old then
        for index, entry in ipairs(entries) do
            if entry == old then table.remove(entries, index) break end
        end
    end
    local entry = { name = name, text = message, kind = kind, roles = roles, activity = activity,
        channel = channel, time = GetTime() }
    table.insert(entries, 1, entry)
    byName[name] = entry
    Trim()
    if RR.RefreshFeedUI then RR.RefreshFeedUI() end
    return true
end

local function OnChat(_, _, text, sender, _, _, _, _, _, _, channelBaseName)
    -- In an encounter the client hands chat over as secret values: such a line is skipped.
    if issecretvalue and (issecretvalue(text) or issecretvalue(sender)) then return end
    if type(text) ~= "string" or type(sender) ~= "string" then return end
    local name = Ambiguate and Ambiguate(sender, "short") or sender
    if name == RR.UnitName("player") then return end
    RR.AddPost(name, text, channelBaseName or "")
end

-- The list ----------------------------------------------------------------------

local KIND_LABEL = { lfm = "LFM", lfg = "LFG", trade = "Trade" }
local KIND_COLOR = { lfm = C.good, lfg = C.accent, trade = C.warn }

local function Visible()
    local list = {}
    local needle = string.lower(search or "")
    for _, entry in ipairs(entries) do
        if (filter == "all" or entry.kind == filter)
            and (needle == "" or string.find(string.lower(entry.name .. " " .. entry.text .. " "
                .. (entry.activity or "")), needle, 1, true)) then
            list[#list + 1] = entry
        end
    end
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
            row.name:SetText(entry.name)
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
    countText:SetText(string.format("%d post(s), %d shown  |  posts stay %d minutes", #entries, #list, EXPIRY / 60))
end

function RR.FeedCount()
    return #entries
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
    for index, def in ipairs({ { "all", "All" }, { "lfm", "LFM" }, { "lfg", "LFG" }, { "trade", "Trade" } }) do
        local button = Button(panel, def[2], 54, 18)
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
    searchLabel:SetPoint("LEFT", filterButtons[#filterButtons], "RIGHT", 16, 0)
    local searchBox = EditBox(panel, 150, 18)
    searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 6, 0)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function(self)
        search = self:GetText() or ""
        offset = 0
        RR.RefreshFeedUI()
    end)

    local clear = Button(panel, "Clear", 54, 18)
    clear:SetPoint("TOPRIGHT", -10, -28)
    clear:SetScript("OnClick", function()
        wipe(entries)
        wipe(byName)
        RR.RefreshFeedUI()
    end)

    local header = CreateFrame("Frame", nil, panel)
    header:SetPoint("TOPLEFT", 10, -58)
    header:SetPoint("TOPRIGHT", -10, -58)
    header:SetHeight(18)
    for _, column in ipairs({ { "", 4 }, { "Player", 46 }, { "For", 150 }, { "Needs", 250 }, { "Message", 300 } }) do
        local text = Label(header, column[1], 10, C.textDim)
        text:SetPoint("LEFT", column[2], 0)
    end

    rows = {}
    for index = 1, FEED_ROWS do
        local row = CreateFrame("Frame", nil, panel)
        row:SetHeight(FEED_ROW_H - 2)
        row:SetPoint("TOPLEFT", 10, -78 - (index - 1) * FEED_ROW_H)
        row:SetPoint("TOPRIGHT", -10, -78 - (index - 1) * FEED_ROW_H)
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
        row.what:SetWidth(96)
        row.what:SetJustifyH("LEFT")
        row.what:SetWordWrap(false)
        row.roles = Label(row, "", 10, C.good)
        row.roles:SetPoint("LEFT", 250, 0)
        row.roles:SetWidth(46)
        row.roles:SetJustifyH("LEFT")
        row.text = Label(row, "", 10, C.textDim)
        row.text:SetPoint("LEFT", 300, 0)
        row.text:SetPoint("RIGHT", -168, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.ago = Label(row, "", 10, C.textDim)
        row.ago:SetPoint("RIGHT", -128, 0)

        row.whisper = Button(row, "Whisper", 60, 20)
        row.whisper:SetPoint("RIGHT", -62, 0)
        row.whisper:SetScript("OnClick", function()
            if row.entry then ChatFrameUtil.SendTell(row.entry.name) end
        end)
        row.invite = Button(row, "Invite", 54, 20)
        row.invite:SetPoint("RIGHT", -4, 0)
        row.invite:SetScript("OnClick", function()
            if row.entry then RR.InviteUnit(row.entry.name) end
        end)

        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:AddLine(self.entry.name, 1, 1, 1)
            GameTooltip:AddLine(self.entry.text, 0.9, 0.9, 0.9, true)
            if self.entry.channel ~= "" then GameTooltip:AddLine(self.entry.channel, 0.5, 0.5, 0.5) end
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
    local note = Label(panel, "Reads the public channels you are in. Nothing is sent.", 10, C.textDim)
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
