-- Working out what people in the raid actually do, by inspecting their build.
--
-- This server has no role API at all. GetInspectSpecialization is stubbed to
-- return 0 in the client's own FrameXML, there is no UnitGroupRolesAssigned
-- native in Extensions.dll, and characters are built out of whatever spells they
-- like -- so the class tells you nothing. What the client does have is its own
-- Character Advancement inspect, the same one the Inspect window's Build tab
-- uses:
--
--   C_CharacterAdvancement.InspectUnit(unit)      -- asks the server
--   INSPECT_CHARACTER_ADVANCEMENT_RESULT(result)  -- "CA_INSPECT_OK" or why not
--   C_CharacterAdvancement.GetInspectInfo(unit)   -- active spec, unlocked specs
--   C_CharacterAdvancement.GetInspectedBuild(unit, spec)  -- their spell list
--   C_CharacterAdvancement.UnitTalentRankByID(unit, id, spec)
--
-- One of the result codes is CA_INSPECT_TARGET_NOT_IN_RANGE, which is the whole
-- shape of this feature: someone standing next to you can be read, someone
-- across the raid cannot, and the ones that fail are simply tried again later.
--
-- Two kinds of raider, two ways to answer:
--
--   * A default class (Warrior, Priest, ...) has real talent trees, and the
--     client itself knows which of its specs tank and which heal
--     (C_ClassInfo.GetSpecInfo -> .Tank / .Healer). That answer is exact and is
--     not a guess of ours.
--   * A hero or custom class has no spec at all, only a list of spells. Those
--     are read one by one and the role is stated together with the evidence for
--     it -- "HEALER: 11 healing spells (Chain Heal, Holy Light)" -- so a wrong
--     call is visible as a wrong call instead of looking like fact.
--
-- Nothing here ever overrides what a player told you themselves. The order stays
-- whisper first, then main tank flags, then this.
--
-- The client deliberately gutted LibTalentQuery with the note that spam
-- inspecting everyone is pointless here, so this asks for one player at a time,
-- leaves a gap between requests, and never runs while the player has their own
-- Inspect window open -- the inspect target is shared, and stealing it would
-- empty the window they are reading.

local ADDON_NAME, RR = ...

RR.inspected = {}       -- name -> { role, why, at, spec, kind }

local queue = {}        -- names waiting to be asked about
local queued = {}       -- name -> true, so one name is never queued twice
local pending = nil     -- { name, unit, guid, at }
local ticker

local REQUEST_GAP = 1.5     -- seconds between two requests
local REQUEST_TIMEOUT = 5   -- no result by then: treat as failed and move on
local RESCAN_AFTER = 900    -- re-read someone after 15 minutes
local RETRY_AFTER = 30      -- someone out of range: try again this often

local lastRequest = 0
local retryAt = {}      -- name -> GetTime() before which not to try again

-- Availability ----------------------------------------------------------------

-- Whether this client can do build inspection at all. Ascension's Lua ships
-- ahead of its C side, so the call being named in FrameXML is not proof it
-- exists in this build.
function RR.CanInspectBuilds()
    return type(C_CharacterAdvancement) == "table"
        and type(C_CharacterAdvancement.InspectUnit) == "function"
        and type(C_CharacterAdvancement.GetInspectInfo) == "function"
end

local function InspectWindowOpen()
    local frame = _G.AscensionInspectFrame or _G.InspectFrame
    return frame and frame.IsShown and frame:IsShown()
end

-- Everyone in the raid, as unit tokens. The player is skipped: their own role is
-- not a mystery and inspecting yourself returns nothing useful.
local function GroupUnits()
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

RR.GroupUnits = GroupUnits

-- Can this unit be read right now? Range is the usual answer to "no", and it is
-- the one that fixes itself when they walk over.
local function Readable(unit)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then
        return false, "not there"
    end
    if UnitIsUnit(unit, "player") then return false, "that is you" end
    if not UnitIsVisible(unit) then return false, "too far away" end
    if type(CanInspect) == "function" then
        local ok, allowed = pcall(CanInspect, unit)
        if ok and not allowed then return false, "cannot be inspected" end
    end
    if type(CheckInteractDistance) == "function" then
        -- 1 is the inspect range, the same one the right-click menu greys out.
        local ok, close = pcall(CheckInteractDistance, unit, 1)
        if ok and not close then return false, "too far away" end
    end
    return true
end

RR.InspectReadable = Readable

-- Reading a build --------------------------------------------------------------

-- Words that decide what a spell is for. Matched against the client's own spell
-- description, so a Conquest of Azeroth ability nobody has ever heard of is
-- classified the same way a base game one is, with no list to keep up to date.
local HEAL_WORDS = { "heals ", "healing", "restores %d+ health", "restore health" }

-- Narrow on purpose, and only ever used to say "this build is not plain damage"
-- -- never to call somebody a tank. Measured against the 515 scraped Conquest of
-- Azeroth tooltips in C:\Ascension\CoA_Data: of spells that are crowd control
-- and nothing else, 10% mention "damage taken", 4.5% mention "threat" and 1.6%
-- mention "absorb" -- because damage-taken debuffs, threat drops and caster
-- shields are damage-dealer spells. In a twenty-spell build that is about three
-- false hits, which is exactly what a "three defensive spells means tank" rule
-- needed, and it is why this raid read as three tanks when it had one.
local TANK_WORDS = { "block", "parry", "shield yourself", "reduces damage taken",
                     "damage you take", "increases your armor" }

-- A taunt is not evidence, it is proof: nobody puts one in a build they do not
-- tank with. The wording has to be the real thing -- a bare "forcing" also
-- matches fears and charms ("forcing them to flee").
local DECISIVE_TANK = { "taunts", "forcing it to attack you",
                        "forcing them to attack you", "forcing the target to attack you" }

-- ... except where the tooltip is talking about not being taunted.
local NOT_A_TAUNT = { "cannot be taunted", "immune to taunt", "taunt immun",
                      "resists taunt", "unaffected by taunt" }

local function Describe(spellID)
    if not spellID then return nil, nil end
    local name
    if type(GetSpellInfo) == "function" then
        local ok, spellName = pcall(GetSpellInfo, spellID)
        if ok then name = spellName end
    end

    local desc
    if type(GetSpellDescription) == "function" then
        local ok, text = pcall(GetSpellDescription, spellID)
        if ok then desc = text end
    end
    return name, desc and string.lower(desc) or nil
end

local function MatchesAny(text, words)
    if not text then return false end
    for _, word in ipairs(words) do
        if string.find(text, word) then return true end
    end
    return false
end

-- Counts what a build is made of. Returns healing count, tanking count, the
-- names that carried the decision, and whether a taunt was found.
local function ScoreSpells(spellIDs)
    local heals, tanks = 0, 0
    local healNames, tankNames = {}, {}
    local taunt = nil

    for _, spellID in ipairs(spellIDs) do
        local name, desc = Describe(spellID)
        if desc then
            if MatchesAny(desc, DECISIVE_TANK) and not MatchesAny(desc, NOT_A_TAUNT) then
                taunt = taunt or name
            end
            if MatchesAny(desc, HEAL_WORDS) then
                heals = heals + 1
                if #healNames < 2 and name then healNames[#healNames + 1] = name end
            elseif MatchesAny(desc, TANK_WORDS) then
                tanks = tanks + 1
                if #tankNames < 2 and name then tankNames[#tankNames + 1] = name end
            end
        end
    end

    return heals, tanks, healNames, tankNames, taunt
end

local function Named(list)
    if #list == 0 then return "" end
    return " (" .. table.concat(list, ", ") .. ")"
end

-- The spell ids in an inspected build, whatever kind of character it is.
local function BuildSpellIDs(unit, spec)
    local spellIDs = {}
    local CA = C_CharacterAdvancement

    if type(CA.GetInspectedBuild) ~= "function" then return spellIDs end

    local ok, entries = pcall(CA.GetInspectedBuild, unit, spec)
    if not ok or type(entries) ~= "table" then return spellIDs end

    for _, item in ipairs(entries) do
        local entryID = item.EntryId or item.EntryID
        local rank = item.Rank or 1
        if entryID and type(CA.GetEntryByInternalID) == "function" then
            local gotEntry, entry = pcall(CA.GetEntryByInternalID, entryID)
            if gotEntry and entry and entry.Spells then
                spellIDs[#spellIDs + 1] = entry.Spells[rank] or entry.Spells[1]
            end
        end
    end
    return spellIDs
end

-- A default class carries real specs, and the client knows which of them tank
-- and heal. Work out which tree they actually invested in, the same way the
-- Inspect window's Build tab does, and take the client's word for the role.
local function RoleFromSpec(unit, spec)
    if type(IsDefaultClass) ~= "function" or not IsDefaultClass(unit) then return nil end

    local class = select(2, UnitClass(unit))
    local order = _G.CHARACTER_ADVANCEMENT_CLASS_SPEC_ORDER
    local CA = C_CharacterAdvancement
    if not class or not order or not order[class] then return nil end
    if type(CA.GetTalentsByClass) ~= "function" or type(CA.UnitKnownID) ~= "function" then
        return nil
    end

    local util = _G.CharacterAdvancementUtil
    if not util or type(util.GetClassDBCByFile) ~= "function" then return nil end

    local bestSpec, bestInvested = nil, 0
    for tab = 1, 3 do
        local specName = order[class][tab]
        if specName then
            local okClass, dbcClass = pcall(util.GetClassDBCByFile, class)
            local okSpec, dbcSpec = pcall(util.GetSpecDBCByFile, specName)
            if okClass and okSpec then
                local okTalents, talents = pcall(CA.GetTalentsByClass, dbcClass, dbcSpec, true)
                if okTalents and type(talents) == "table" then
                    local invested = 0
                    for _, entry in ipairs(talents) do
                        local okKnown, known = pcall(CA.UnitKnownID, unit, entry.ID, spec)
                        if okKnown and known then
                            local rank = 1
                            if type(CA.UnitTalentRankByID) == "function" then
                                local okRank, value = pcall(CA.UnitTalentRankByID, unit, entry.ID, spec)
                                if okRank and value then rank = value end
                            end
                            invested = invested + (entry.TECost or 1) * rank
                        end
                    end
                    if invested > bestInvested then
                        bestInvested, bestSpec = invested, specName
                    end
                end
            end
        end
    end

    if not bestSpec or bestInvested == 0 then return nil end

    local info
    if C_ClassInfo and type(C_ClassInfo.GetSpecInfo) == "function" then
        local ok, specInfo = pcall(C_ClassInfo.GetSpecInfo, class, bestSpec)
        if ok then info = specInfo end
    end
    if not info then return nil end

    local role = "DPS"
    if info.Healer then
        role = "HEALER"
    elseif info.Tank then
        role = "TANK"
    end

    return role, string.format("%s spec, by the client's own spec data", info.Name or bestSpec), info.Name or bestSpec
end

-- Everything the inspect gave us about one unit.
function RR.ReadInspected(unit)
    local CA = C_CharacterAdvancement
    local activeSpec = 1
    if type(CA.GetInspectInfo) == "function" then
        local ok, spec = pcall(CA.GetInspectInfo, unit)
        if ok and spec then activeSpec = spec end
    end

    local role, why, specName = RoleFromSpec(unit, activeSpec)
    if role then
        return { role = role, why = why, spec = specName, kind = "spec", at = time() }
    end

    local spellIDs = BuildSpellIDs(unit, activeSpec)
    if #spellIDs == 0 then
        return nil, "the build came back empty"
    end

    local heals, tanks, healNames, tankNames, taunt = ScoreSpells(spellIDs)

    if taunt then
        return {
            role = "TANK",
            why = string.format("has a taunt (%s)", taunt),
            kind = "build",
            at = time(),
        }
    end

    -- Three healing spells, not one: the same measurement says 7% of spells that
    -- do no healing at all still say "healing" somewhere in their tooltip, so a
    -- single hit in a twenty-spell build is noise. A real healer clears this
    -- easily.
    if heals >= 3 and heals > tanks then
        return {
            role = "HEALER",
            why = string.format("%d healing spells%s", heals, Named(healNames)),
            kind = "build",
            at = time(),
        }
    end

    -- No tank verdict from counting. A defensive-looking build with no taunt in
    -- it is left unknown rather than guessed at: the guess was wrong three times
    -- out of four in a live raid, and a wrong tank is worse than a question
    -- mark, which at least gets the person asked.
    if tanks >= 3 then
        return nil, string.format("a defensive-looking build with no taunt in it%s -- ask them", Named(tankNames))
    end

    return {
        role = "DPS",
        why = string.format("%d spells, nothing healing or defensive", #spellIDs),
        kind = "build",
        at = time(),
    }
end

-- The queue --------------------------------------------------------------------

function RR.QueueInspect(name, front)
    if not name or queued[name] then return end
    queued[name] = true
    if front then
        table.insert(queue, 1, name)
    else
        queue[#queue + 1] = name
    end
end

-- Everyone whose role is not known yet, or was read long enough ago to be stale.
function RR.QueueGroup(force)
    if not RR.CanInspectBuilds() then return end
    local now = time()
    for name in pairs(GroupUnits()) do
        local known = RR.inspected[name]
        if force or not known or (now - (known.at or 0)) > RESCAN_AFTER then
            RR.QueueInspect(name)
        end
    end
end

local function FinishPending(record, failure)
    local waiting = pending
    pending = nil
    if not waiting then return end

    queued[waiting.name] = nil

    if record then
        record.name = waiting.name
        RR.inspected[waiting.name] = record
        if RR.RefreshComposition then RR.RefreshComposition() end
        if RR.RefreshList then RR.RefreshList() end
    elseif failure then
        -- Out of range is not a failure worth reporting: it is the normal state
        -- of most of a raid, and it fixes itself when they walk past.
        retryAt[waiting.name] = GetTime() + RETRY_AFTER
        RR.QueueInspect(waiting.name)
    end
end

local function SendNext()
    if pending or #queue == 0 then return end
    if not RR.CanInspectBuilds() then return end
    if InspectWindowOpen() then return end
    if GetTime() - lastRequest < REQUEST_GAP then return end

    local units = GroupUnits()

    for index = 1, #queue do
        local name = queue[index]
        local unit = units[name]
        local waitUntil = retryAt[name]

        if not unit then
            -- They left the group; drop them.
            table.remove(queue, index)
            queued[name] = nil
            return
        end

        if not waitUntil or GetTime() >= waitUntil then
            if Readable(unit) then
                table.remove(queue, index)
                pending = { name = name, unit = unit, guid = UnitGUID(unit), at = GetTime() }
                lastRequest = GetTime()
                pcall(C_CharacterAdvancement.InspectUnit, unit)
                return
            end
            retryAt[name] = GetTime() + RETRY_AFTER
        end
    end
end

local function OnResult(result)
    if not pending then return end

    if result ~= "CA_INSPECT_OK" then
        FinishPending(nil, result or "CA_INSPECT_UNKNOWN")
        return
    end

    -- The unit token can have been reused by someone else between asking and
    -- answering; the GUID is what says this data belongs to who we asked about.
    if UnitGUID(pending.unit) ~= pending.guid then
        FinishPending(nil, "CA_INSPECT_UNKNOWN")
        return
    end

    local record = RR.ReadInspected(pending.unit)
    FinishPending(record, not record and "CA_INSPECT_UNKNOWN" or nil)
end

-- What the rest of the addon asks ----------------------------------------------

function RR.InspectedRole(name)
    local record = name and RR.inspected[name]
    if not record then return nil end
    return record.role, record.why, record.kind
end

function RR.InspectStatus()
    local known, waiting = 0, #queue
    for _ in pairs(RR.inspected) do known = known + 1 end
    return known, waiting, pending and pending.name or nil
end

-- Loading ----------------------------------------------------------------------

function RR.Inspect_Init()
    if not RR.CanInspectBuilds() then
        return
    end

    local watcher = CreateFrame("Frame")
    for _, event in ipairs({ "INSPECT_CHARACTER_ADVANCEMENT_RESULT",
                             "RAID_ROSTER_UPDATE", "PARTY_MEMBERS_CHANGED" }) do
        pcall(watcher.RegisterEvent, watcher, event)
    end

    watcher:SetScript("OnEvent", function(self, event, arg1)
        if event == "INSPECT_CHARACTER_ADVANCEMENT_RESULT" then
            OnResult(arg1)
        else
            RR.QueueGroup()
        end
    end)

    ticker = C_Timer.NewTicker(1, function()
        if pending and GetTime() - pending.at > REQUEST_TIMEOUT then
            FinishPending(nil, "CA_INSPECT_UNKNOWN")
        end
        SendNext()
    end)

    -- Whatever is already in the group when the addon loads.
    if C_Timer and C_Timer.After then
        C_Timer.After(5, function() RR.QueueGroup() end)
    end
end
