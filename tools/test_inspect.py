# Drives Inspect.lua against a stubbed Character Advancement API: the request
# queue, the range retry, reading a default-class spec, reading a classless build,
# and the rule that what someone told you beats what their build says.
#
# The stubs answer the way the client's own Inspect window uses these calls (see
# Ascension_InspectUI/Panels/InspectBuildPanel.lua). Every assertion is checked
# against a deliberately broken build at the bottom.

import io, os, sys
from lupa.lua51 import LuaRuntime

ADDON = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ["Core.lua", "Inspect.lua"]

PRELUDE = r"""
GetTime_value = 1000
time_value = 100000
function GetTime() return GetTime_value end
function time() return time_value end
SlashCmdList = {}
RAID_CLASS_COLORS = {}
printed = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) printed[#printed + 1] = m end }

-- world
raid = {}            -- index -> { name, class, visible, inRange, canInspect, build, default, guid }
inspectWindowShown = false
requests = {}        -- units asked about, in order

function GetNumRaidMembers() return #raid end
function GetNumPartyMembers() return 0 end
function GetRaidRosterInfo(i) return raid[i] and raid[i].name end
local function member(unit)
    if unit == "player" then return { name = "Deniz", guid = "player" } end
    local i = tonumber(string.match(unit or "", "^raid(%d+)$"))
    return i and raid[i]
end
_member = member
function UnitName(unit) local m = member(unit) ; return m and m.name end
function UnitExists(unit) return member(unit) ~= nil end
function UnitIsPlayer(unit) return member(unit) ~= nil end
function UnitIsUnit(a, b) return a == b end
function UnitIsVisible(unit) local m = member(unit) ; return m and m.visible ~= false end
function UnitGUID(unit) local m = member(unit) ; return m and m.guid end
function UnitClass(unit) local m = member(unit) ; return m and m.class, m and m.class end
function UnitLevel() return 80 end
function CanInspect(unit) local m = member(unit) ; return m and m.canInspect ~= false end
function CheckInteractDistance(unit, index)
    local m = member(unit)
    return m and m.inRange ~= false
end
function GetPartyAssignment() return false end
function IsDefaultClass(unit) local m = member(unit) ; return m and m.default == true end
function IsHeroClass(unit) return not IsDefaultClass(unit) end
function IsCustomClass(unit) return false end

-- spells: id -> { name, desc }
spells = {}
function GetSpellInfo(id) return spells[id] and spells[id].name end
function GetSpellDescription(id) return spells[id] and spells[id].desc end

-- Character Advancement, shaped after the client's own inspect panel
entries = {}         -- entryID -> { Spells = { id, ... } }
talentsByClass = {}  -- "CLASS|SPEC" -> { { ID =, TECost = }, ... }
unitKnown = {}       -- "unitname|entryID" -> rank

CHARACTER_ADVANCEMENT_CLASS_SPEC_ORDER = {
    WARRIOR = { "Arms", "Fury", "Protection" },
}
CharacterAdvancementUtil = {
    GetClassDBCByFile = function(class) return class end,
    GetSpecDBCByFile = function(spec) return spec end,
}
C_ClassInfo = {
    GetSpecInfo = function(class, spec)
        local info = { Name = spec }
        if spec == "Protection" then info.Tank = true end
        if spec == "Holy" or spec == "Restoration" then info.Healer = true end
        return info
    end,
}

C_CharacterAdvancement = {
    InspectUnit = function(unit)
        requests[#requests + 1] = unit
    end,
    GetInspectInfo = function(unit) return 1, { 1 } end,
    GetInspectedBuild = function(unit, spec)
        local m = _member(unit)
        return m and m.build
    end,
    GetEntryByInternalID = function(id) return entries[id] end,
    GetTalentsByClass = function(class, spec)
        return talentsByClass[class .. "|" .. spec] or {}
    end,
    UnitKnownID = function(unit, entryID)
        local m = _member(unit)
        return m and unitKnown[m.name .. "|" .. entryID] ~= nil
    end,
    UnitTalentRankByID = function(unit, entryID)
        local m = _member(unit)
        return m and unitKnown[m.name .. "|" .. entryID]
    end,
}

AscensionInspectFrame = { IsShown = function() return inspectWindowShown end }

frames = {}
function CreateFrame(kind, name, parent)
    local f = { events = {} }
    setmetatable(f, { __index = function(t, k)
        local fn = function(...) return t end
        rawset(t, k, fn)
        return fn
    end })
    f.RegisterEvent = function(self, e) self.events[e] = true end
    f.SetScript = function(self, script, fn) self[script .. "_fn"] = fn end
    f.IsShown = function() return false end
    frames[#frames + 1] = f
    return f
end

timers, tickers = {}, {}
C_Timer = {
    After = function(delay, fn) timers[#timers + 1] = fn end,
    NewTicker = function(interval, fn)
        local t = { fn = fn, Cancel = function(self) self.cancelled = true end }
        tickers[#tickers + 1] = t
        return t
    end,
}
function Tick(times)
    for _ = 1, (times or 1) do
        GetTime_value = GetTime_value + 2   -- past the request gap
        for _, t in ipairs(tickers) do
            if not t.cancelled then t.fn() end
        end
    end
end
function FireEvent(event, ...)
    for _, f in ipairs(frames) do
        local events = rawget(f, "events")
        if type(events) == "table" and events[event] and f.OnEvent_fn then
            f.OnEvent_fn(f, event, ...)
        end
    end
end
"""


def boot(mutate=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    lua.execute("RR = {}")
    RR = lua.globals().RR
    for name in FILES:
        src = io.open(os.path.join(ADDON, name), encoding="utf-8").read().lstrip("﻿")
        if mutate:
            src = mutate(name, src)
        loader = lua.eval("function(s, n) return loadstring(s, n) end")(src, "@" + name)
        if loader is None:
            raise AssertionError("syntax error in " + name)
        loader("RaidRecruiter", RR)
    lua.execute("""
        RaidRecruiterDB = {}
        RR.db = RaidRecruiterDB
        for key, value in pairs(RR.defaults) do
            if RR.db[key] == nil then RR.db[key] = value end
        end
        RR.Inspect_Init()
    """)
    return lua


HEAL_DESC = "Heals a friendly target for 1200."
TAUNT_DESC = "Taunts the target, forcing it to attack you."
DPS_DESC = "Strikes the enemy for 400 physical damage."
DEFENSIVE_DESC = "Reduces damage taken by 20% and increases block chance."


def world(lua, extra=""):
    lua.execute("""
        spells = {
            [100] = { name = "Chain Heal", desc = "%s" },
            [101] = { name = "Holy Light", desc = "%s" },
            [200] = { name = "Growl", desc = "%s" },
            [300] = { name = "Mortal Strike", desc = "%s" },
            [400] = { name = "Shield Wall", desc = "%s" },
        }
        entries = {
            [1] = { Spells = { 100 } },
            [2] = { Spells = { 101 } },
            [3] = { Spells = { 200 } },
            [4] = { Spells = { 300 } },
            [5] = { Spells = { 400 } },
        }
    """ % (HEAL_DESC, HEAL_DESC, TAUNT_DESC, DPS_DESC, DEFENSIVE_DESC))
    lua.execute(extra)


def run(name, fn):
    try:
        fn()
    except AssertionError as exc:
        print("FAIL  %s: %s" % (name, exc))
        return False
    print("ok    %s" % name)
    return True


def test_only_asks_about_people_in_range():
    lua = boot()
    world(lua, """
        raid = {
            { name = "Borkk", guid = "g1", class = "HERO", inRange = false, build = {} },
            { name = "Aluna", guid = "g2", class = "HERO", inRange = true, build = { { EntryId = 1, Rank = 1 } } },
        }
        RR.QueueGroup(true)
    """)
    lua.execute("Tick(3)")
    asked = lua.eval("table.concat(requests, ',')")
    assert asked == "raid2", "asked the wrong people: '%s'" % asked


def test_out_of_range_is_retried_not_dropped():
    lua = boot()
    world(lua, """
        raid = { { name = "Borkk", guid = "g1", class = "HERO", inRange = false, build = { { EntryId = 1, Rank = 1 } } } }
        RR.QueueGroup(true)
    """)
    lua.execute("Tick(2)")
    assert lua.eval("#requests") == 0, "asked about someone out of range"
    _, waiting, _ = lua.eval("function() return RR.InspectStatus() end")()
    assert waiting == 1, "the out-of-range player was dropped instead of kept, waiting=%s" % waiting

    # they walk over
    lua.execute("raid[1].inRange = true ; GetTime_value = GetTime_value + 60 ; Tick(2)")
    assert lua.eval("#requests") == 1, "never retried once they were in range"


def test_healer_from_build():
    lua = boot()
    world(lua, """
        raid = { { name = "Aluna", guid = "g2", class = "HERO", inRange = true,
                   build = { { EntryId = 1, Rank = 1 }, { EntryId = 2, Rank = 1 }, { EntryId = 4, Rank = 1 } } } }
        RR.QueueGroup(true)
        Tick(2)
        FireEvent("INSPECT_CHARACTER_ADVANCEMENT_RESULT", "CA_INSPECT_OK")
    """)
    role, why, _ = lua.eval("function() return RR.InspectedRole('Aluna') end")()
    assert role == "HEALER", "expected HEALER, got %s" % role
    assert "Chain Heal" in (why or ""), "the evidence does not name the spells: %s" % why


def test_taunt_means_tank():
    lua = boot()
    world(lua, """
        raid = { { name = "Borkk", guid = "g1", class = "HERO", inRange = true,
                   build = { { EntryId = 3, Rank = 1 }, { EntryId = 4, Rank = 1 } } } }
        RR.QueueGroup(true)
        Tick(2)
        FireEvent("INSPECT_CHARACTER_ADVANCEMENT_RESULT", "CA_INSPECT_OK")
    """)
    role, why, _ = lua.eval("function() return RR.InspectedRole('Borkk') end")()
    assert role == "TANK", "a build with a taunt was read as %s" % role
    assert "Growl" in (why or ""), "the taunt is not named in the evidence: %s" % why


def test_default_class_uses_the_clients_own_spec():
    lua = boot()
    world(lua, """
        raid = { { name = "Thrak", guid = "g3", class = "WARRIOR", default = true, inRange = true,
                   build = { { EntryId = 4, Rank = 1 } } } }
        talentsByClass["WARRIOR|Arms"] = { { ID = 11, TECost = 1 } }
        talentsByClass["WARRIOR|Fury"] = { { ID = 12, TECost = 1 } }
        talentsByClass["WARRIOR|Protection"] = { { ID = 13, TECost = 5 } }
        unitKnown["Thrak|11"] = 1
        unitKnown["Thrak|13"] = 3
        RR.QueueGroup(true)
        Tick(2)
        FireEvent("INSPECT_CHARACTER_ADVANCEMENT_RESULT", "CA_INSPECT_OK")
    """)
    role, why, kind = lua.eval("function() return RR.InspectedRole('Thrak') end")()
    assert role == "TANK", "the invested Protection tree did not win: %s (%s)" % (role, why)
    assert kind == "spec", "a default class should be read from its spec, not its spell list"


def test_failed_inspect_records_nothing():
    lua = boot()
    world(lua, """
        raid = { { name = "Borkk", guid = "g1", class = "HERO", inRange = true,
                   build = { { EntryId = 3, Rank = 1 } } } }
        RR.QueueGroup(true)
        Tick(2)
        FireEvent("INSPECT_CHARACTER_ADVANCEMENT_RESULT", "CA_INSPECT_TARGET_NOT_IN_RANGE")
    """)
    role = lua.eval("function() return RR.InspectedRole('Borkk') end")()
    assert role is None, "a failed inspect was recorded as a role: %s" % role


def test_unit_swapped_under_us_is_discarded():
    lua = boot()
    world(lua, """
        raid = { { name = "Borkk", guid = "g1", class = "HERO", inRange = true,
                   build = { { EntryId = 3, Rank = 1 } } } }
        RR.QueueGroup(true)
        Tick(2)
        raid[1].guid = "someone-else"
        FireEvent("INSPECT_CHARACTER_ADVANCEMENT_RESULT", "CA_INSPECT_OK")
    """)
    role = lua.eval("function() return RR.InspectedRole('Borkk') end")()
    assert role is None, "data for a different player was stored as Borkk's: %s" % role


def test_never_scans_while_his_own_inspect_window_is_open():
    lua = boot()
    world(lua, """
        inspectWindowShown = true
        raid = { { name = "Aluna", guid = "g2", class = "HERO", inRange = true,
                   build = { { EntryId = 1, Rank = 1 } } } }
        RR.QueueGroup(true)
        Tick(3)
    """)
    assert lua.eval("#requests") == 0, "stole the inspect target while the window was open"


def test_what_they_said_beats_their_build():
    lua = boot()
    world(lua, """
        raid = { { name = "Aluna", guid = "g2", class = "HERO", inRange = true,
                   build = { { EntryId = 1, Rank = 1 }, { EntryId = 2, Rank = 1 } } } }
        RR.QueueGroup(true)
        Tick(2)
        FireEvent("INSPECT_CHARACTER_ADVANCEMENT_RESULT", "CA_INSPECT_OK")
        RR.knownRoles = { Aluna = "Tank" }
    """)
    counts = lua.eval("RR.GroupRoles()")
    assert counts.TANK == 1, "the whisper did not win over the inspected build: tanks=%s" % counts.TANK
    assert counts.HEALER == 0, "the build overrode what they told him"


def test_build_fills_an_unknown():
    lua = boot()
    world(lua, """
        raid = { { name = "Aluna", guid = "g2", class = "HERO", inRange = true,
                   build = { { EntryId = 1, Rank = 1 }, { EntryId = 2, Rank = 1 } } } }
        RR.QueueGroup(true)
        Tick(2)
        FireEvent("INSPECT_CHARACTER_ADVANCEMENT_RESULT", "CA_INSPECT_OK")
    """)
    counts = lua.eval("RR.GroupRoles()")
    assert counts.HEALER == 1, "the inspected healer was not counted: %s" % counts.HEALER
    assert counts.UNKNOWN == 0, "the healer was still counted as unknown as well: %s" % counts.UNKNOWN


TESTS = [
    ("only asks about people in range", test_only_asks_about_people_in_range),
    ("out of range is retried", test_out_of_range_is_retried_not_dropped),
    ("healer read off a build", test_healer_from_build),
    ("a taunt means tank", test_taunt_means_tank),
    ("default class uses the client's spec", test_default_class_uses_the_clients_own_spec),
    ("failed inspect records nothing", test_failed_inspect_records_nothing),
    ("unit swapped under us", test_unit_swapped_under_us_is_discarded),
    ("never steals his inspect window", test_never_scans_while_his_own_inspect_window_is_open),
    ("what they said wins", test_what_they_said_beats_their_build),
    ("build fills an unknown", test_build_fills_an_unknown),
]

BROKEN_CHECKS = [
    ("range check skipped entirely",
     ("Inspect.lua", "if Readable(unit) then", "if true then"),
     "only asks about people in range"),
    ("failed result stored anyway",
     ("Inspect.lua", 'if result ~= "CA_INSPECT_OK" then', "if false then"),
     "failed inspect records nothing"),
    ("guid check dropped",
     ("Inspect.lua", 'if UnitGUID(pending.unit) ~= pending.guid then', "if false then"),
     "unit swapped under us"),
    ("scans over the open inspect window",
     ("Inspect.lua", "if InspectWindowOpen() then return end", ""),
     "never steals his inspect window"),
    ("build outranks the whisper",
     ("Core.lua", """        local role = RoleFromWords(said)
        if role then return role end""", ""),
     "what they said wins"),
    ("taunt no longer decisive",
     ("Inspect.lua", "if taunt then", "if false then"),
     "a taunt means tank"),
]


def check_broken():
    global boot
    lookup = dict(TESTS)
    original = boot
    caught = 0
    for label, (filename, find, replace), testname in BROKEN_CHECKS:
        def mutate(name, src, filename=filename, find=find, replace=replace):
            if name != filename:
                return src
            assert find in src, "mutation target vanished from %s: %s" % (name, find)
            return src.replace(find, replace, 1)

        boot = lambda mutate=mutate: original(mutate)
        try:
            lookup[testname]()
        except Exception as exc:
            print("ok    caught: %s (%s)" % (label, type(exc).__name__))
            caught += 1
        else:
            print("FAIL  not caught: %s (%s passed on a broken build)" % (label, testname))
        finally:
            boot = original
    return caught


if __name__ == "__main__":
    passed = 0
    for name, fn in TESTS:
        if run(name, fn):
            passed += 1
    print("")
    print("%d/%d behaviour tests" % (passed, len(TESTS)))
    print("")
    print("broken-build checks:")
    caught = check_broken()
    print("%d/%d mutations caught" % (caught, len(BROKEN_CHECKS)))
    sys.exit(0 if passed == len(TESTS) and caught == len(BROKEN_CHECKS) else 1)
