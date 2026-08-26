-- RaidRecruiter -- /rr
--
-- Two halves of the same job:
--   * post your "LFM ..." message to the channels you tick, on your own timer
--   * turn every whisper you get back into a row in an applicant list, with the
--     item level they quoted, their level, and the role they said they play
--
-- Nothing here is automatic beyond the posting: no auto-invite, no auto-reply.
-- Inviting is always a button you press, so a bad parse can never pull a
-- stranger into the raid.

local ADDON_NAME, RR = ...

_G.RaidRecruiter = RR

RR.ADDON_NAME = ADDON_NAME
RR.VERSION = "1.0"

-- Colours ---------------------------------------------------------------------

RR.COLOR = {
    accent      = { 0.30, 0.62, 0.95 },
    accentDim   = { 0.18, 0.36, 0.56 },
    good        = { 0.35, 0.80, 0.40 },
    warn        = { 0.95, 0.70, 0.25 },
    bad         = { 0.85, 0.30, 0.30 },
    text        = { 0.92, 0.92, 0.94 },
    textDim     = { 0.62, 0.63, 0.68 },
    panel       = { 0.06, 0.07, 0.09 },
    row         = { 0.11, 0.12, 0.15 },
    rowAlt      = { 0.09, 0.10, 0.12 },
}

function RR.Hex(color)
    return string.format("|cff%02x%02x%02x",
        math.floor(color[1] * 255), math.floor(color[2] * 255), math.floor(color[3] * 255))
end

function RR.Print(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(RR.Hex(RR.COLOR.accent) .. "RaidRecruiter|r: " .. msg)
end

-- Saved settings --------------------------------------------------------------
--
-- Per character on purpose: the message a tank posts is not the message an alt
-- posts, and a channel list is realm/character specific anyway.

RR.defaults = {
    message = "LFM <raid> - need all roles, whisper me your item level!",
    channels = {},          -- [channel name] = true, resolved to a live id at send time
    guild = false,
    say = false,
    yell = false,
    interval = 60,          -- seconds between rounds
    minIlvl = 0,            -- applicant list filter
    roleFilter = "ANY",     -- ANY / TANK / HEALER / DPS
    hideGrouped = true,
    sortKey = "time",       -- time / ilvl / level / name
    sortDesc = true,
    soundOnWhisper = true,
    maxPlayers = 25,        -- group is considered full at this many
    fullReplyEnabled = true,
    fullReply = "Full",     -- whispered back once per player while full
    window = nil,
    minimap = { hide = false },
    page = "recruit",
    rollSeconds = 15,       -- how long a loot roll stays open, announced in /rw
    rollCountdownFrom = 5,  -- start the 5,4,3,2,1 countdown at this many left
    lootMinQuality = 3,     -- blue and up; grey/green trash never needs a roll
    stash = {},             -- boss drops now in your own bags, still to hand out
    stashHours = 12,        -- how long a remembered drop stays in the list
}

RR.MIN_INTERVAL = 10
RR.MAX_INTERVAL = 600
RR.MAX_MESSAGE = 255        -- hard chat limit; longer just gets truncated by the client

function RR.GetDB()
    return RR.db
end

-- Class colours ---------------------------------------------------------------
--
-- Conquest of Azeroth hands out class tokens the stock client has no colour for
-- (CoAClassColorFix fills most of them in). Never index RAID_CLASS_COLORS blind:
-- a missing token there is a nil index error, not a missing colour.

function RR.ClassColor(class)
    if class and RAID_CLASS_COLORS then
        local color = rawget(RAID_CLASS_COLORS, class)
        if color and color.r then
            return color.r, color.g, color.b
        end
    end
    return RR.COLOR.text[1], RR.COLOR.text[2], RR.COLOR.text[3]
end

-- Group state -----------------------------------------------------------------

-- Names currently in the party/raid, so applicants who already made it in can be
-- greyed out or hidden instead of sitting in the list looking unanswered.
function RR.GroupedNames()
    local names = {}
    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            local name = GetRaidRosterInfo(i)
            if name then names[name] = true end
        end
        return names
    end

    local party = GetNumPartyMembers and GetNumPartyMembers() or 0
    for i = 1, party do
        local name = UnitName("party" .. i)
        if name then names[name] = true end
    end
    local me = UnitName("player")
    if me then names[me] = true end
    return names
end

-- "Full" is your own cap, not the game's: a 25-man raid group can hold 40, and
-- the point is to stop taking applicants at the size you are actually running.
function RR.GroupIsFull()
    local size = RR.GroupSize()
    local cap = tonumber(RR.db and RR.db.maxPlayers) or 25
    return size >= cap, size, cap
end

function RR.GroupSize()
    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then
        return raid, 40
    end
    local party = GetNumPartyMembers and GetNumPartyMembers() or 0
    if party > 0 then
        return party + 1, 5
    end
    return 1, 5
end

-- Group composition -----------------------------------------------------------
--
-- What the group is actually made of, so "12/25" also answers "of what". There
-- is no reliable class-to-role mapping on this server -- characters are built
-- out of any spells they like, so a "mage" can be the tank -- and every source
-- below is therefore something someone declared, or something read off their
-- actual build, never a guess from the class:
--
--   1. what the player whispered when they applied ("82 ilvl resto")
--   2. main tank / main assist flags set in the raid frames
--   3. their inspected build (Inspect.lua), for anyone who has been close enough
--   4. the client's own role assignment, if this client has that API at all
--
-- The whisper comes first because it is the only source that exists for every
-- member here: role assignment is an LFG feature this raid is not using, and
-- main tank flags cover two people at most.
--
-- Anything left over counts as unknown rather than being folded into DPS: an
-- unknown healer padding the DPS count is worse than an honest question mark.

local function RoleFromWords(said)
    if not said then return nil end
    -- "Tank/DPS" is two answers and the scarcer slot wins: a group short a tank
    -- cares that the option exists.
    if string.find(said, "Tank") then return "TANK" end
    if string.find(said, "Healer") then return "HEALER" end
    if string.find(said, "DPS") then return "DPS" end
    return nil
end

local function DeclaredRole(unit, name)
    if name then
        local said = RR.knownRoles and RR.knownRoles[name]
        if not said then
            local record = RR.GetApplicant and RR.GetApplicant(name)
            said = record and record.role
        end
        local role = RoleFromWords(said)
        if role then return role end
    end

    if unit and type(GetPartyAssignment) == "function" then
        local ok, isTank = pcall(GetPartyAssignment, "MAINTANK", unit)
        if ok and isTank then return "TANK" end
    end

    -- What their build says, read by inspecting them while they were close enough.
    -- Below the two declarations above on purpose: a player saying "I heal" beats
    -- anything worked out from their spell list.
    if name and RR.InspectedRole then
        local role = RR.InspectedRole(name)
        if role then return role end
    end

    if unit and type(UnitGroupRolesAssigned) == "function" then
        local ok, role = pcall(UnitGroupRolesAssigned, unit)
        if ok and (role == "TANK" or role == "HEALER" or role == "DAMAGER") then
            return role == "DAMAGER" and "DPS" or role
        end
    end

    return nil
end

function RR.GroupRoles()
    local counts = { TANK = 0, HEALER = 0, DPS = 0, UNKNOWN = 0 }

    local function Add(unit, name)
        local role = DeclaredRole(unit, name)
        if role then
            counts[role] = counts[role] + 1
        else
            counts.UNKNOWN = counts.UNKNOWN + 1
        end
    end

    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            local name = GetRaidRosterInfo(i)
            Add("raid" .. i, name)
        end
        return counts
    end

    local party = GetNumPartyMembers and GetNumPartyMembers() or 0
    if party > 0 then
        Add("player", UnitName("player"))
        for i = 1, party do
            Add("party" .. i, UnitName("party" .. i))
        end
        return counts
    end

    Add("player", UnitName("player"))
    return counts
end

-- Who is what, and why. Printed rather than asserted: a role worked out from
-- someone's spell list is only worth having if you can see what it was based on.
function RR.PrintRoles()
    local units = RR.GroupUnits and RR.GroupUnits() or {}
    local names = { UnitName("player") }
    for name in pairs(units) do names[#names + 1] = name end
    table.sort(names)

    local shown = 0
    for _, name in ipairs(names) do
        local role, why, kind

        local said = RR.knownRoles and RR.knownRoles[name]
        if not said then
            local record = RR.GetApplicant and RR.GetApplicant(name)
            said = record and record.role
        end
        if RR.InspectedRole then role, why, kind = RR.InspectedRole(name) end

        if said then
            RR.Print("%s: %s -- they told you so", name, said)
        elseif role then
            RR.Print("%s: %s -- %s", name, role, why or (kind == "spec" and "from their spec" or "from their build"))
        else
            RR.Print("%s: not read yet", name)
        end
        shown = shown + 1
    end

    if shown == 0 then
        RR.Print("you are not in a group.")
    elseif RR.InspectStatus then
        local known, waiting, busy = RR.InspectStatus()
        RR.Print("%d read, %d waiting%s", known, waiting, busy and (", reading " .. busy) or "")
    end
end

-- Time ------------------------------------------------------------------------

function RR.AgoText(stamp)
    local delta = time() - (stamp or 0)
    if delta < 60 then
        return delta .. "s"
    elseif delta < 3600 then
        return math.floor(delta / 60) .. "m"
    end
    return math.floor(delta / 3600) .. "h"
end

-- Loading ---------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        RaidRecruiterDB = RaidRecruiterDB or {}
        RR.db = RaidRecruiterDB

        for key, value in pairs(RR.defaults) do
            if RR.db[key] == nil then
                if type(value) == "table" then
                    local copy = {}
                    for k, v in pairs(value) do copy[k] = v end
                    RR.db[key] = copy
                else
                    RR.db[key] = value
                end
            end
        end

        if RR.Applicants_Init then RR.Applicants_Init() end
        if RR.Broadcast_Init then RR.Broadcast_Init() end
        if RR.Loot_Init then RR.Loot_Init() end
        if RR.LootBag_Init then RR.LootBag_Init() end
        if RR.Inspect_Init then RR.Inspect_Init() end
    elseif event == "PLAYER_LOGIN" then
        if RR.UI_Init then RR.UI_Init() end
    end
end)

SLASH_RAIDRECRUITER1 = "/rr"
SLASH_RAIDRECRUITER2 = "/raidrecruiter"
SlashCmdList["RAIDRECRUITER"] = function(msg)
    msg = msg and msg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""

    if msg == "start" then
        RR.StartBroadcast()
    elseif msg == "stop" then
        RR.StopBroadcast()
    elseif msg == "clear" then
        RR.ClearApplicants()
        RR.Print("applicant list cleared.")
    elseif msg == "reset" then
        RR.db.window = nil
        if RR.ResetWindow then RR.ResetWindow() end
        RR.Print("window position reset.")
    elseif msg == "loot" then
        if not RaidRecruiterWindow or not RaidRecruiterWindow:IsShown() then
            RR.ToggleWindow()
        end
        if RR.SelectPage then RR.SelectPage("loot") end
    elseif msg == "bag" then
        local stash = RR.StashList()
        if #stash == 0 then
            RR.Print("the loot bag is empty.")
        end
        for _, entry in ipairs(stash) do
            RR.Print("%s x%d from %s -- %d in your bags",
                entry.link, entry.count or 1, entry.source or "?", RR.BagCount(entry.link))
        end
    elseif msg == "bag clear" then
        RR.StashClear(false)
        if RR.RefreshLootUI then RR.RefreshLootUI() end
        RR.Print("loot bag emptied.")
    elseif msg == "roles" then
        RR.PrintRoles()
    elseif msg == "scan" then
        if not RR.CanInspectBuilds or not RR.CanInspectBuilds() then
            RR.Print("this client has no build inspection -- roles can only come from whispers and raid flags.")
        else
            RR.QueueGroup(true)
            local _, waiting = RR.InspectStatus()
            RR.Print("scanning %d group member(s) -- anyone out of range is retried as they come closer.", waiting)
        end
    elseif msg == "help" then
        RR.Print("/rr toggles the window. Also: loot, bag, bag clear, roles, scan, start, stop, clear, reset.")
    else
        RR.ToggleWindow()
    end
end
