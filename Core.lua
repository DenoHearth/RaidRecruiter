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
    roles = {},             -- [name] = "Tank" / "Healer" / "DPS" / "Tank/DPS"
    rolesSavedAt = 0,       -- when that table was last written
    rolesKeepHours = 12,
    pullSeconds = 15,       -- the countdown before a boss    -- older than this and it is last week's raid, not this one
    -- Class check: the fallback when nothing else knows the raid's makeup --
    -- ask everyone in a raid warning and read the answers out of raid chat.
    roleCallMessage = "Class check -- write your role in raid chat: tank / healer / dps",
    roleCallSeconds = 60,   -- how long raid chat is read for answers
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

-- Everyone in the group except the player, name -> unit token. Lived in
-- Inspect.lua until that module was retired; it is roster bookkeeping, not
-- inspection, and /rr roles still needs it.
function RR.GroupUnits()
    local units = {}
    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            local name = GetRaidRosterInfo(i)
            if name and name ~= UnitName("player") then
                units[name] = "raid" .. i
            end
        end
        return units
    end

    local party = GetNumPartyMembers and GetNumPartyMembers() or 0
    for i = 1, party do
        local name = UnitName("party" .. i)
        if name then units[name] = "party" .. i end
    end
    return units
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
-- Two sources, both of them somebody telling you what they are:
--
--   1. what they whispered you ("82 ilvl resto")
--   2. what they wrote in chat during a class check
--
-- Nothing is worked out from a build or a talent spec. That was tried and it was
-- wrong: characters here are assembled out of whatever spells the player likes,
-- and the defensive-sounding words a tank build has are all over damage-dealer
-- tooltips too, so a raid with one tank read as three. Deniz's call, 2026-08-26.
--
-- Anything nobody has declared counts as unknown rather than being folded into
-- DPS: an unknown healer padding the DPS count is worse than an honest question
-- mark, and the question mark is what gets the person asked.

local function RoleFromWords(said)
    if not said then return nil end
    -- "Tank/DPS" is two answers and the scarcer slot wins: a group short a tank
    -- cares that the option exists.
    if string.find(said, "Tank") then return "TANK" end
    if string.find(said, "Healer") then return "HEALER" end
    if string.find(said, "DPS") then return "DPS" end
    return nil
end

local function DeclaredRole(name)
    if name then
        local said = RR.knownRoles and RR.knownRoles[name]
        if not said then
            local record = RR.GetApplicant and RR.GetApplicant(name)
            said = record and record.role
        end
        local role = RoleFromWords(said)
        if role then return role end
    end

    return nil
end

-- Counts, and the names behind the question mark. Both come out of the same
-- walk on purpose: a list of unknowns that disagrees with the number next to it
-- is worse than no list, and that is exactly what two separate loops drift into.
function RR.GroupRoles()
    local counts = { TANK = 0, HEALER = 0, DPS = 0, UNKNOWN = 0 }
    local unknown = {}

    local function Add(name)
        local role = DeclaredRole(name)
        if role then
            counts[role] = counts[role] + 1
        else
            counts.UNKNOWN = counts.UNKNOWN + 1
            if name then unknown[#unknown + 1] = name end
        end
    end

    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            local name = GetRaidRosterInfo(i)
            Add(name)
        end
        return counts, unknown
    end

    local party = GetNumPartyMembers and GetNumPartyMembers() or 0
    if party > 0 then
        Add(UnitName("player"))
        for i = 1, party do
            Add(UnitName("party" .. i))
        end
        return counts, unknown
    end

    Add(UnitName("player"))
    return counts, unknown
end

-- Everyone whose role nothing knows yet, sorted, ready to be read out or
-- nagged. Same walk as the readout, so the names always match the number.
function RR.UnknownRoleNames()
    local _, unknown = RR.GroupRoles()
    table.sort(unknown)
    return unknown
end

-- Who is what, and where it came from. Printed rather than asserted: the only
-- answers here are ones somebody gave, so this says who has not answered yet.
function RR.PrintRoles()
    local units = RR.GroupUnits and RR.GroupUnits() or {}
    local names = { UnitName("player") }
    for name in pairs(units) do names[#names + 1] = name end
    table.sort(names)

    local shown = 0
    for _, name in ipairs(names) do
        local said = RR.knownRoles and RR.knownRoles[name]
        if not said then
            local record = RR.GetApplicant and RR.GetApplicant(name)
            said = record and record.role
        end

        if said then
            RR.Print("%s: %s -- they told you so", name, said)
        else
            RR.Print("%s: has not said", name)
        end
        shown = shown + 1
    end

    if shown == 0 then
        RR.Print("you are not in a group.")
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
        if RR.Ilvl_Init then RR.Ilvl_Init() end
        if RR.Pull_Init then RR.Pull_Init() end
        if RR.RoleCall_Init then RR.RoleCall_Init() end
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
    elseif msg == "check" then
        RR.ToggleRoleCall()
    elseif msg == "pull" or string.match(msg, "^pull%s+%d+$") then
        RR.TogglePull(tonumber(string.match(msg, "(%d+)")))
    elseif msg == "ask" then
        RR.ToggleChase()
    elseif msg == "roles" then
        RR.PrintRoles()
    elseif msg == "help" then
        RR.Print("/rr toggles the window. Also: pull [seconds], loot, bag, bag clear, check, ask, roles, start, stop, clear, reset.")
    else
        RR.ToggleWindow()
    end
end
