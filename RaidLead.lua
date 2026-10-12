-- The Raid lead page: what a raid leader presses, as buttons.
--
-- Ready check and its result, pull timers (Pull.lua does the counting), marks on the target,
-- loot method and threshold with an announce button, the groups with three ways to sort them,
-- and a raid check for the usual buffs.
--
-- Not here: marks on the ground. The game lets only a protected button place those, and a
-- protected button inside this window would stop the window from opening in a fight. They are
-- on the raid bar (RaidBar.lua).
--
-- Untested with a real raid (2026-10-12): the group sorts and the raid check. The functions
-- they call exist on the client; how the server answers a run of group moves, and whether other
-- players' buffs can be read out of combat, has to be seen in a raid.

local ADDON_NAME, RR = ...

local C = RR.COLOR
local secret = issecretvalue or function() return false end

local ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"
local QUALITY = { [2] = "green", [3] = "blue", [4] = "purple" }

local page
local readyLine, notReadyLine, whisperButton
local methodButtons, qualityButtons, rulesLine = {}, {}, nil
local groupColumns, countsLine, sortLine = {}, nil, nil
local checkRows, checkNote = {}, nil

-- ------------------------------------------------------------------ who is in the group

local function plain(value)
    if value == nil or secret(value) then return nil end
    return value
end

function RR.CanLead()
    local lead, assist = plain(UnitIsGroupLeader("player")), plain(UnitIsGroupAssistant("player"))
    return (lead or assist) and true or false
end

-- Everyone in the group: { name, unit, index (raid only), group, class }. Names the client
-- hides (a fight can do that) are left out.
local function Members()
    local out = {}
    local raid = RR.GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            local name, _, subgroup, _, _, class = GetRaidRosterInfo(i)
            name, subgroup, class = plain(name), plain(subgroup), plain(class)
            if name and subgroup then
                out[#out + 1] = { name = name, unit = "raid" .. i, index = i, group = subgroup, class = class or "" }
            end
        end
        return out, true
    end
    local me = plain(UnitName("player"))
    if me then out[1] = { name = me, unit = "player", group = 1, class = plain(select(2, UnitClass("player"))) or "" } end
    for i = 1, RR.GetNumPartyMembers() or 0 do
        local name = plain(UnitName("party" .. i))
        if name then out[#out + 1] = { name = name, unit = "party" .. i, group = 1, class = plain(select(2, UnitClass("party" .. i))) or "" } end
    end
    return out, false
end
RR.LeadMembers = Members

local function RoleOf(name)
    local said = RR.knownRoles and RR.knownRoles[name]
    if not said and RR.GetApplicant then
        local record = RR.GetApplicant(name)
        said = record and record.role
    end
    if type(said) ~= "string" then return "DPS", false end
    local low = string.lower(said)
    if low:find("tank", 1, true) then return "TANK", true end
    if low:find("heal", 1, true) then return "HEALER", true end
    return "DPS", true
end

local ROLE_COLOR = { TANK = "tank", HEALER = "healer", DPS = "dps" }

-- ------------------------------------------------------------------ ready check

local ready = { status = {}, total = 0, running = false }

local function ReadyCounts()
    local yes, no = 0, {}
    for name, state in pairs(ready.status) do
        if state == "ready" then yes = yes + 1 else no[#no + 1] = { name = name, state = state } end
    end
    table.sort(no, function(a, b) return a.name < b.name end)
    return yes, no
end

function RR.ReadyCheckResult()
    local yes, no = ReadyCounts()
    return ready.total, yes, no, ready.running
end

local function RefreshReady()
    if not page then return end
    local yes, no = ReadyCounts()
    if ready.total == 0 then
        readyLine:SetText("No ready check yet.")
        readyLine:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        notReadyLine:SetText("")
        whisperButton:Hide()
        return
    end
    local good = #no == 0
    readyLine:SetText(yes .. " of " .. ready.total .. " ready" .. (ready.running and "  (still running)" or ""))
    local colour = good and C.good or C.warn
    readyLine:SetTextColor(colour[1], colour[2], colour[3])
    local names = {}
    for i = 1, math.min(#no, 6) do names[i] = no[i].name end
    notReadyLine:SetText(good and "" or ("not ready: " .. table.concat(names, ", ") .. (#no > 6 and " ..." or "")))
    whisperButton:SetShown(not good and not ready.running)
end

local function OnReadyEvent(_, event, a, b)
    if event == "READY_CHECK" then
        wipe(ready.status)
        local members = Members()
        ready.total, ready.running = #members, true
        for _, m in ipairs(members) do ready.status[m.name] = "waiting" end
        local starter = plain(a)
        if starter then
            local short = Ambiguate and Ambiguate(starter, "short") or starter
            if ready.status[short] ~= nil then ready.status[short] = "ready" end
        end
    elseif event == "READY_CHECK_CONFIRM" then
        local unit, isReady = plain(a), plain(b)
        local name = unit and plain(UnitName(unit))
        if name and ready.status[name] ~= nil then ready.status[name] = isReady and "ready" or "notready" end
    elseif event == "READY_CHECK_FINISHED" then
        ready.running = false
        for name, state in pairs(ready.status) do
            if state == "waiting" then ready.status[name] = "away" end
        end
        if RR.RaidBar_ShowReadyResult then RR.RaidBar_ShowReadyResult() end
    end
    RefreshReady()
end

function RR.StartReadyCheck()
    if not IsInGroup() then RR.Print("ready check: you are not in a group.") return end
    DoReadyCheck()
end

-- A whisper to a player who was not ready. One chat line per click is all the game allows an
-- addon, so the first click writes to the first, the next click to the next.
local whisperAt = 0
function RR.WhisperNotReady(name)
    local _, no = ReadyCounts()
    if not name then
        if #no == 0 then return end
        whisperAt = whisperAt % #no + 1
        name = no[whisperAt].name
        whisperButton.text:SetText(whisperAt < #no and ("Whisper next (" .. (#no - whisperAt) .. ")") or "Whisper them")
    end
    SendChatMessage("Ready check: are you there?", "WHISPER", nil, name)
end

-- ------------------------------------------------------------------ loot

local function Announce(text)
    if RR.Announce then RR.Announce(text) else SendChatMessage(text, IsInRaid() and "RAID" or "PARTY") end
end

local METHODS = {
    { key = Enum.LootMethod.Group, label = "Group loot", name = "group" },
    { key = Enum.LootMethod.Masterlooter, label = "Master looter", name = "master" },
    { key = Enum.LootMethod.Needbeforegreed, label = "Need / greed", name = "needbeforegreed" },
}

local function CurrentMethod()
    local method = plain(RR.GetLootMethod and RR.GetLootMethod())
    if type(method) == "string" then
        for _, m in ipairs(METHODS) do
            if method == m.name then return m.key end
        end
        return nil
    end
    return method
end

local function RefreshLoot()
    if not page then return end
    local method, threshold = CurrentMethod(), plain(GetLootThreshold())
    for _, m in ipairs(METHODS) do
        methodButtons[m.key]:SetColor(method == m.key and C.accent or nil)
    end
    for quality, button in pairs(qualityButtons) do
        button:SetColor(threshold == quality and C.accent or nil)
    end
    -- the rules line says what is switched on, nothing more: MS +1 only when ticked in Options
    rulesLine:SetText(RR.LootRulesOn() and "Rules: main spec before off spec, +1 on a main-spec win (Options)"
        or "Rules: highest roll wins. (MS +1 is off - Options)")
end

local function SetMethod(key)
    if not RR.CanLead() then RR.Print("loot method: only the leader can change it.") return end
    if key == Enum.LootMethod.Masterlooter then
        C_PartyInfo.SetLootMethod(key, UnitName("player"))
    else
        C_PartyInfo.SetLootMethod(key)
    end
end

-- Announces the method and threshold as they are set. Main spec / +1 is named only when that
-- rule is ticked in Options: it is not a standard (his word, 2026-10-12).
local function AnnounceRules()
    local method, threshold = CurrentMethod(), plain(GetLootThreshold())
    local label = "loot"
    for _, m in ipairs(METHODS) do
        if m.key == method then label = m.label end
    end
    local text = "Loot: " .. label
    if QUALITY[threshold] then text = text .. ", from " .. QUALITY[threshold] end
    if method == Enum.LootMethod.Masterlooter then text = text .. ". /roll when an item is called" end
    if RR.LootRulesOn() then text = text .. ". Main spec before off spec (/roll 99 = off spec), +1 on a main-spec win" end
    Announce(text .. ".")
end

-- ------------------------------------------------------------------ groups

local MELEE = { WARRIOR = true, ROGUE = true, PALADIN = true, DEATHKNIGHT = true }
local RANGED = { HUNTER = true, MAGE = true, WARLOCK = true, PRIEST = true }

local sorting         -- { want = { [name] = group }, steps = n }
local undo            -- { [name] = group } as it was before the last sort

-- One move per roster change: the server answers each before the next is asked.
local function SortStep()
    if not sorting then return end
    if InCombatLockdown() or not RR.CanLead() or sorting.steps > 60 then
        sorting = nil
        sortLine:SetText("Sort stopped.")
        return
    end
    local members = Members()
    local size, byGroup = {}, {}
    for _, m in ipairs(members) do
        size[m.group] = (size[m.group] or 0) + 1
        byGroup[m.group] = byGroup[m.group] or {}
        table.insert(byGroup[m.group], m)
    end
    for _, m in ipairs(members) do
        local want = sorting.want[m.name]
        if want and want ~= m.group then
            sorting.steps = sorting.steps + 1
            if (size[want] or 0) < 5 then
                SetRaidSubgroup(m.index, want)
                return
            end
            for _, other in ipairs(byGroup[want] or {}) do
                if sorting.want[other.name] ~= want then
                    SwapRaidSubgroup(m.index, other.index)
                    return
                end
            end
        end
    end
    sorting = nil
    sortLine:SetText("Sorted.")
end

local function StartSort(kind)
    local members, isRaid = Members()
    if not isRaid then sortLine:SetText("Sorting needs a raid group.") return end
    if not RR.CanLead() then sortLine:SetText("Only the leader or an assistant can move players.") return end
    if InCombatLockdown() then sortLine:SetText("Not in a fight.") return end

    local want = {}
    if kind == "undo" then
        if not undo then sortLine:SetText("Nothing to undo.") return end
        want = undo
        undo = nil
    else
        undo = {}
        for _, m in ipairs(members) do undo[m.name] = m.group end
        if kind == "roles" then
            -- a tank and a healer into each group first, then everyone else
            local tanks, healers, rest = {}, {}, {}
            for _, m in ipairs(members) do
                local role = RoleOf(m.name)
                if role == "TANK" then tanks[#tanks + 1] = m elseif role == "HEALER" then healers[#healers + 1] = m else rest[#rest + 1] = m end
            end
            local groups = math.ceil(#members / 5)
            local seats = {}
            for g = 1, groups do seats[g] = {} end
            local function deal(list)
                local leftover = {}
                for i, m in ipairs(list) do
                    if i <= groups then table.insert(seats[i], m) else leftover[#leftover + 1] = m end
                end
                return leftover
            end
            for _, m in ipairs(deal(tanks)) do rest[#rest + 1] = m end
            for _, m in ipairs(deal(healers)) do rest[#rest + 1] = m end
            for g = 1, groups do
                while #seats[g] < 5 and #rest > 0 do table.insert(seats[g], table.remove(rest, 1)) end
                for _, m in ipairs(seats[g]) do want[m.name] = g end
            end
        else
            local order = {}
            for _, m in ipairs(members) do order[#order + 1] = m end
            if kind == "range" then
                -- melee into the first groups, ranged after; a hybrid class goes by its role
                local function rank(m)
                    if MELEE[m.class] then return 1 end
                    if RANGED[m.class] then return 3 end
                    return RoleOf(m.name) == "HEALER" and 3 or 2
                end
                table.sort(order, function(a, b)
                    local ra, rb = rank(a), rank(b)
                    if ra ~= rb then return ra < rb end
                    return a.name < b.name
                end)
            else
                table.sort(order, function(a, b)
                    if a.class ~= b.class then return a.class < b.class end
                    return a.name < b.name
                end)
            end
            for i, m in ipairs(order) do want[m.name] = math.floor((i - 1) / 5) + 1 end
        end
    end
    sorting = { want = want, steps = 0 }
    sortLine:SetText("Sorting ...")
    SortStep()
end

local function RefreshGroups()
    if not page then return end
    local members = Members()
    local perGroup, counts = {}, { TANK = 0, HEALER = 0, DPS = 0 }
    for _, m in ipairs(members) do
        perGroup[m.group] = perGroup[m.group] or {}
        table.insert(perGroup[m.group], m)
        local role = RoleOf(m.name)
        counts[role] = counts[role] + 1
    end
    for g = 1, 8 do
        local column = groupColumns[g]
        local list = perGroup[g] or {}
        for i = 1, 5 do
            local row, m = column.rows[i], list[i]
            if m then
                local colour = C[ROLE_COLOR[RoleOf(m.name)]]
                row.dot:SetColorTexture(colour[1], colour[2], colour[3], 1)
                row.dot:Show()
                row.name:SetText(m.name)
            else
                row.dot:Hide()
                row.name:SetText("")
            end
        end
    end
    countsLine:SetText("Tanks " .. counts.TANK .. "   Healers " .. counts.HEALER .. "   DPS " .. counts.DPS .. "     " .. #members .. " in the group")
end

-- ------------------------------------------------------------------ raid check

-- What each line looks for in a buff's name (English client).
local CHECKS = {
    { label = "Flask / elixir", words = { "Flask", "Elixir" } },
    { label = "Food buff", words = { "Well Fed" } },
    { label = "Fortitude", words = { "Fortitude" } },
    { label = "Intellect", words = { "Arcane Intellect", "Arcane Brilliance" } },
    { label = "Mark of the Wild", words = { "Mark of the Wild", "Gift of the Wild" } },
}

local lastCheck      -- { have = { n per check }, missing = { names per check }, total, unread }

-- Out of combat only. A player whose buffs the client hides counts as "could not be read",
-- never as missing something.
local function RunRaidCheck()
    if InCombatLockdown() then checkNote:SetText("Not in a fight.") return end
    local members = Members()
    local result = { have = {}, missing = {}, total = #members, unread = 0 }
    for i = 1, #CHECKS do result.have[i], result.missing[i] = 0, {} end
    for _, m in ipairs(members) do
        local found, readable = {}, true
        for index = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex(m.unit, index, "HELPFUL")
            if aura == nil then break end
            local name = plain(plain(aura) and aura.name)
            if not name then readable = false break end
            for i, check in ipairs(CHECKS) do
                for _, word in ipairs(check.words) do
                    if name:find(word, 1, true) then found[i] = true end
                end
            end
        end
        if readable then
            for i = 1, #CHECKS do
                if found[i] then result.have[i] = result.have[i] + 1 else table.insert(result.missing[i], m.name) end
            end
        else
            result.unread = result.unread + 1
        end
    end
    lastCheck = result
    RR.RefreshRaidLead()
end

local function RefreshCheck()
    if not page then return end
    for i, row in ipairs(checkRows) do
        if lastCheck then
            local read = lastCheck.total - lastCheck.unread
            local have = lastCheck.have[i]
            row.count:SetText(have .. " of " .. read)
            local colour = have >= read and C.good or (have == 0 and C.bad or C.warn)
            row.count:SetTextColor(colour[1], colour[2], colour[3])
        else
            row.count:SetText("-")
            row.count:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        end
    end
    if not lastCheck then
        checkNote:SetText("Out of combat only. Press Check now.")
    elseif lastCheck.unread > 0 then
        checkNote:SetText(lastCheck.unread .. " player(s) could not be read.")
    else
        local names = lastCheck.missing[1]
        checkNote:SetText(#names == 0 and "Everyone has a flask or elixir."
            or ("No flask: " .. table.concat(names, ", ", 1, math.min(#names, 6)) .. (#names > 6 and " ..." or "")))
    end
end

local function TellRaidCheck()
    if not lastCheck then return end
    local parts = {}
    for i, check in ipairs(CHECKS) do
        local names = lastCheck.missing[i]
        if #names > 0 and #names <= 8 then
            parts[#parts + 1] = check.label .. " missing: " .. table.concat(names, ", ")
        elseif #names > 8 then
            parts[#parts + 1] = check.label .. " missing on " .. #names
        end
    end
    Announce(#parts == 0 and "Raid check: everyone is buffed." or ("Raid check - " .. parts[1]))
end

-- ------------------------------------------------------------------ the page

function RR.RefreshRaidLead()
    if not page or not page:IsShown() then return end
    RefreshReady()
    RefreshLoot()
    RefreshGroups()
    RefreshCheck()
end

local function Box(parent, x, y, width, height, title)
    local box = CreateFrame("Frame", nil, parent)
    box:SetPoint("TOPLEFT", x, -y)
    box:SetSize(width, height)
    RR.UI_Section(box)
    local heading = RR.UI_Heading(box, title)
    heading:SetPoint("TOPLEFT", 10, -10)
    return box
end

local function Place(button, parent, x, y, onClick)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    button:SetScript("OnClick", onClick)
    return button
end

function RR.RaidLeadUI_Init()
    if not RR.NewPage then return end
    page = RR.NewPage("lead")
    local B, L = RR.UI_Button, RR.UI_Label

    -- before the pull
    local pull = Box(page, 10, 10, 810, 96, "BEFORE THE PULL")
    Place(B(pull, "Ready check", 150, 30), pull, 10, 30, RR.StartReadyCheck):SetColor(C.accent)
    Place(B(pull, "Pull in 10", 104, 30), pull, 168, 30, function() RR.StartPull(10) end)
    Place(B(pull, "Pull in 15", 104, 30), pull, 278, 30, function() RR.StartPull(15) end)
    Place(B(pull, "Break 5 min", 104, 30), pull, 388, 30, function() RR.StartPull(300) end)
    Place(B(pull, "Stop timer", 104, 30), pull, 498, 30, function() RR.CancelPull() end):SetColor(C.bad)
    Place(B(pull, "Role check", 120, 30), pull, 608, 30, function()
        if RR.CanLead() then InitiateRolePoll() else RR.Print("role check: only the leader or an assistant.") end
    end)
    readyLine = L(pull, "", 11, C.textDim)
    readyLine:SetPoint("TOPLEFT", 10, -70)
    notReadyLine = L(pull, "", 11, C.bad)
    notReadyLine:SetPoint("LEFT", readyLine, "RIGHT", 16, 0)
    whisperButton = Place(B(pull, "Whisper them", 130, 22), pull, 670, 66, function() RR.WhisperNotReady() end)

    -- marks
    local marks = Box(page, 10, 114, 400, 116, "MARKERS")
    local onTarget = L(marks, "On your target", 11, C.textDim)
    onTarget:SetPoint("TOPLEFT", 10, -32)
    for i = 1, 8 do
        local button = Place(B(marks, "", 32, 32), marks, 10 + (i - 1) * 36, 50, function() SetRaidTarget("target", i) end)
        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 4, -4)
        icon:SetPoint("BOTTOMRIGHT", -4, 4)
        icon:SetTexture(ICON .. i)
    end
    Place(B(marks, "Clear", 82, 26), marks, 306, 53, function() SetRaidTarget("target", 0) end)
    local ground = L(marks, "Marks on the ground are on the raid bar (the game allows them only there).", 10, C.textDim)
    ground:SetPoint("TOPLEFT", 10, -92)

    -- loot
    local loot = Box(page, 420, 114, 400, 116, "LOOT")
    local methodLabel = L(loot, "Method", 11, C.textDim)
    methodLabel:SetPoint("TOPLEFT", 10, -34)
    for i, m in ipairs(METHODS) do
        methodButtons[m.key] = Place(B(loot, m.label, 104, 22), loot, 70 + (i - 1) * 108, 30, function() SetMethod(m.key) end)
    end
    local fromLabel = L(loot, "From", 11, C.textDim)
    fromLabel:SetPoint("TOPLEFT", 10, -60)
    for i, quality in ipairs({ 2, 3, 4 }) do
        qualityButtons[quality] = Place(B(loot, ({ "Green", "Blue", "Purple" })[i], 104, 22), loot, 70 + (i - 1) * 108, 56, function()
            if RR.CanLead() then SetLootThreshold(quality) else RR.Print("loot threshold: only the leader can change it.") end
        end)
    end
    rulesLine = L(loot, "", 10, C.textDim)
    rulesLine:SetPoint("TOPLEFT", 10, -86)
    Place(B(loot, "Announce", 84, 20), loot, 306, 90, AnnounceRules)

    -- groups
    local groups = Box(page, 10, 238, 524, 320, "GROUPS")
    for g = 1, 8 do
        local column = CreateFrame("Frame", nil, groups)
        column:SetSize(124, 104)
        column:SetPoint("TOPLEFT", 10 + ((g - 1) % 4) * 127, -(30 + math.floor((g - 1) / 4) * 108))
        RR.UI_Inset(column)
        local title = L(column, "Group " .. g, 9, C.textDim)
        title:SetPoint("TOP", 0, -3)
        column.rows = {}
        for i = 1, 5 do
            local row = CreateFrame("Frame", nil, column)
            row:SetSize(118, 16)
            row:SetPoint("TOPLEFT", 3, -(16 + (i - 1) * 17))
            row.dot = row:CreateTexture(nil, "ARTWORK")
            row.dot:SetSize(7, 7)
            row.dot:SetPoint("LEFT", 3, 0)
            row.name = L(row, "", 10, C.text)
            row.name:SetPoint("LEFT", 14, 0)
            column.rows[i] = row
        end
        groupColumns[g] = column
    end
    countsLine = L(groups, "", 11, C.text)
    countsLine:SetPoint("TOPLEFT", 10, -250)
    sortLine = L(groups, "", 10, C.textDim)
    sortLine:SetPoint("TOPRIGHT", -10, -250)
    Place(B(groups, "Tank + healer per group", 166, 24), groups, 10, 270, function() StartSort("roles") end)
    Place(B(groups, "Melee / ranged", 110, 24), groups, 180, 270, function() StartSort("range") end)
    Place(B(groups, "By class", 80, 24), groups, 294, 270, function() StartSort("class") end)
    Place(B(groups, "Undo", 60, 24), groups, 378, 270, function() StartSort("undo") end)
    Place(B(groups, "To raid", 72, 24), groups, 442, 270, function()
        if IsInGroup() and not IsInRaid() and RR.CanLead() then C_PartyInfo.ConvertToRaid() end
    end)

    -- raid check
    local check = Box(page, 544, 238, 276, 320, "RAID CHECK")
    for i, entry in ipairs(CHECKS) do
        local row = CreateFrame("Frame", nil, check)
        row:SetSize(256, 22)
        row:SetPoint("TOPLEFT", 10, -(30 + (i - 1) * 24))
        RR.UI_Row(row, i)
        local label = L(row, entry.label, 10, C.text)
        label:SetPoint("LEFT", 8, 0)
        row.count = L(row, "-", 10, C.textDim)
        row.count:SetPoint("RIGHT", -8, 0)
        checkRows[i] = row
    end
    checkNote = L(check, "", 10, C.textDim)
    checkNote:SetPoint("TOPLEFT", 10, -158)
    checkNote:SetWidth(256)
    checkNote:SetJustifyH("LEFT")
    Place(B(check, "Check now", 124, 26), check, 10, 220, RunRaidCheck):SetColor(C.accent)
    Place(B(check, "Tell the raid", 124, 26), check, 142, 220, TellRaidCheck)

    -- the raid bar switch
    local barCheck = RR.UI_CheckBox(check, "Show the raid bar while I lead")
    barCheck:SetPoint("TOPLEFT", 8, -262)
    barCheck:SetScript("OnClick", function(self)
        RR.db.barShown = self:GetChecked() and true or false
        if RR.RaidBar_Update then RR.RaidBar_Update() end
    end)
    barCheck:SetScript("OnShow", function(self) self:SetChecked(RR.db.barShown ~= false) end)

    page:SetScript("OnShow", RR.RefreshRaidLead)

    local watcher = CreateFrame("Frame")
    for _, event in ipairs({ "READY_CHECK", "READY_CHECK_CONFIRM", "READY_CHECK_FINISHED" }) do watcher:RegisterEvent(event) end
    watcher:SetScript("OnEvent", OnReadyEvent)

    local roster = CreateFrame("Frame")
    roster:RegisterEvent("GROUP_ROSTER_UPDATE")
    roster:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
    roster:SetScript("OnEvent", function(_, event)
        if event == "GROUP_ROSTER_UPDATE" and sorting then C_Timer.After(0.3, SortStep) end
        RR.RefreshRaidLead()
    end)
end
