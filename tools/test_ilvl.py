# Drives Ilvl.lua against stubbed gear: the native item level, the gear-sum
# fallback, refusing a half-arrived inventory, range retries, the guid check,
# never stealing the player's own inspect window, and the rule that a number read
# off gear beats one an applicant quoted.
#
# Every assertion is checked against a deliberately broken build at the bottom.

import io, os, sys
from lupa.lua51 import LuaRuntime

ADDON = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ["Core.lua", "Applicants.lua", "Ilvl.lua"]

PRELUDE = r"""
GetTime_value = 1000
time_value = 100000
function GetTime() return GetTime_value end
function time() return time_value end
SlashCmdList = {}
RAID_CLASS_COLORS = {}
printed = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) printed[#printed + 1] = m end }

-- world: index 1 is the player
raid = {}          -- { name, guid, inRange, visible, native, gear }
inspectWindowShown = false
requests = {}      -- units NotifyInspect was called on, in order

function GetNumRaidMembers() return #raid end
function GetNumPartyMembers() return 0 end
function GetRaidRosterInfo(i) return raid[i] and raid[i].name end
local function member(unit)
    if unit == "player" then return raid[1] end
    local i = tonumber(string.match(unit or "", "^raid(%d+)$"))
    return i and raid[i]
end
_member = member
function UnitName(unit) local m = member(unit) ; return m and m.name end
function UnitExists(unit) return member(unit) ~= nil end
function UnitIsPlayer(unit) return member(unit) ~= nil end
function UnitIsVisible(unit) local m = member(unit) ; return m and m.visible ~= false end
function UnitGUID(unit) local m = member(unit) ; return m and m.guid end
function UnitLevel() return 80 end
function CanInspect(unit) return true end
function CheckInteractDistance(unit) local m = member(unit) ; return m and m.inRange ~= false end
function PlaySound() end
function Ambiguate(name) return name end
function GetPartyAssignment() return false end

ITEM_LEVEL = "Item Level %d"
UIParent = {}

-- Gear is read out of the tooltip the client builds per slot, because this
-- server rescales items and GetItemInfo reports the base level. gear[slot] is
-- the level that tooltip will show; a slot listed in "blank" has an item in it
-- whose tooltip has not filled in yet.
function GetInventoryItemTexture(unit, slot)
    local m = member(unit)
    if not m or not m.gear then return nil end
    if m.blank and m.blank[slot] then return "texture" end
    return m.gear[slot] and "texture" or nil
end

tooltipLines = {}
local function TooltipFontString(index)
    return {
        GetText = function() return tooltipLines[index] end,
    }
end

function CreateTooltip(name)
    local tip = {
        SetOwner = function() end,
        ClearLines = function() tooltipLines = {} end,
        Hide = function() end,
        GetName = function() return name end,
        NumLines = function() return #tooltipLines end,
        SetInventoryItem = function(self, unit, slot)
            tooltipLines = { "Some Item" }
            local m = member(unit)
            local level = m and m.gear and m.gear[slot]
            if level and not (m.blank and m.blank[slot]) then
                tooltipLines[2] = "Item Level " .. level
            end
        end,
    }
    for i = 1, 10 do
        _G[name .. "TextLeft" .. i] = TooltipFontString(i)
    end
    return tip
end

-- Shaped like the client's own wrapper in GlobalOverwrites.lua: it silently
-- refuses while the player's Inspect window is open. "attempts" records the call
-- anyway, so a test can tell "we never asked" from "we asked and were refused".
attempts = {}
function NotifyInspect(unit)
    attempts[#attempts + 1] = unit
    if inspectWindowShown then return end
    requests[#requests + 1] = unit
end
AscensionInspectFrame = { IsShown = function() return inspectWindowShown end }

frames = {}
function CreateFrame(kind, name, parent)
    if kind == "GameTooltip" then return CreateTooltip(name) end
    local f = { events = {} }
    setmetatable(f, { __index = function(t, k)
        local fn = function(...) return t end
        rawset(t, k, fn)
        return fn
    end })
    f.RegisterEvent = function(self, e) self.events[e] = true end
    f.UnregisterAllEvents = function(self) self.events = {} end
    f.SetScript = function(self, script, fn) self[script .. "_fn"] = fn end
    f.IsShown = function() return false end
    frames[#frames + 1] = f
    return f
end

tickers = {}
C_Timer = {
    After = function(delay, fn) fn() end,
    NewTicker = function(interval, fn)
        local t = { fn = fn, Cancel = function(self) self.cancelled = true end }
        tickers[#tickers + 1] = t
        return t
    end,
}
function Tick(seconds)
    for _ = 1, (seconds or 1) do
        GetTime_value = GetTime_value + 2   -- past the request gap
        for _, t in ipairs(tickers) do
            if not t.cancelled then t.fn() end
        end
    end
end
function FireEvent(event, ...)
    for _, f in ipairs(frames) do
        local events = rawget(f, "events")
        if type(events) == "table" and events[event] then
            local fn = rawget(f, "OnEvent_fn")
            if fn then fn(f, event, ...) end
        end
    end
end

-- a full set of gear, every slot the same item level
function FullGear(level)
    local gear = {}
    for _, slot in ipairs({ 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }) do
        gear[slot] = level
    end
    return gear
end
"""

WORLD = '''
raid = {
    { name = "Deniz",  guid = "g0", gear = FullGear(70) },
    { name = "Bjorn",  guid = "g1", inRange = true,  gear = FullGear(82) },
    { name = "Sigrid", guid = "g2", inRange = true,  gear = FullGear(64) },
    { name = "Halvar", guid = "g3", inRange = false, gear = FullGear(90) },
}
'''


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
        RR.Applicants_Init()
        RR.Ilvl_Init()
    """ + WORLD)
    return lua


def read(lua, name):
    # ItemLevelOf returns value, source, when -- lupa hands all three back, so
    # take the one being asked about.
    return lua.eval("(function() local v = RR.ItemLevelOf('%s') return v end)()" % name)


def source(lua, name):
    return lua.eval("(function() local _, s = RR.ItemLevelOf('%s') return s end)()" % name)


def run(mutate=None):
    failures = []

    def check(name, condition):
        if not condition:
            failures.append(name)

    lua = boot(mutate)
    g = lua.globals()

    lua.eval("RR.QueueIlvlGroup(true)")

    # Your own gear needs no inspecting.
    check("own gear read without asking", read(lua, "Deniz") == 70)

    # Only people in range are asked about.
    lua.execute("Tick(4)")
    asked = lua.eval("table.concat(requests, ',')")
    check("only asked about people in range", "raid4" not in asked)
    check("asked about someone in range", "raid2" in asked)

    # Their gear arrives: the native answers.
    lua.eval('FireEvent("UNIT_INVENTORY_CHANGED", "raid2")')
    check("item level read off the tooltip", read(lua, "Bjorn") == 82)
    check("marked as read", source(lua, "Bjorn") == "read")
    check("two decimals", lua.eval("RR.FormatItemLevel(82.5)") == "82.50")

    # Everybody is read the same way -- one tooltip per slot, averaged.
    lua.execute("Tick(4)")
    lua.eval('FireEvent("UNIT_INVENTORY_CHANGED", "raid3")')
    check("gear averaged", read(lua, "Sigrid") == 64)

    # Halvar is out of range, so nothing was read -- but the number he whispered
    # is still worth showing, marked as his claim rather than a reading.
    lua.execute('''
        local record = { name = "Halvar", ilvl = 99.5, lastSeen = time_value }
        RR.GetApplicant = function(n) if n == "Halvar" then return record end end
    ''')
    check("whispered number shown", read(lua, "Halvar") == 99.5)
    check("whispered number marked", source(lua, "Halvar") == "said")

    # He walks over: what is read off his gear replaces what he claimed.
    lua.execute("raid[4].inRange = true")
    lua.execute("Tick(30)")
    lua.eval('FireEvent("UNIT_INVENTORY_CHANGED", "raid4")')
    check("out of range is retried, not dropped", read(lua, "Halvar") == 90)
    check("reading beats the claim", source(lua, "Halvar") == "read")

    # Half-arrived gear is not an item level.
    lua2 = boot(mutate)
    lua2.execute('''
        raid = { { name = "Deniz", guid = "g0", gear = FullGear(70) },
                 { name = "Torvi", guid = "g9", inRange = true, gear = { [1] = 60, [2] = 60 } } }
        RR.QueueIlvlGroup(true)
        Tick(4)
        FireEvent("UNIT_INVENTORY_CHANGED", "raid2")
    ''')
    check("a half-arrived inventory is refused", read(lua2, "Torvi") is None)

    # A full set of gear where two tooltips have not filled in yet is not an item
    # level either -- averaging the fifteen that did answer reports a number that
    # is simply wrong, and the data is seconds away.
    lua2b = boot(mutate)
    lua2b.execute('''
        raid = { { name = "Deniz", guid = "g0", gear = FullGear(70) },
                 { name = "Slow", guid = "g7", inRange = true, gear = FullGear(80),
                   blank = { [1] = true, [5] = true } } }
        RR.QueueIlvlGroup(true)
        Tick(1)
        FireEvent("UNIT_INVENTORY_CHANGED", "raid2")
    ''')
    check("tooltips still filling in are not an answer", read(lua2b, "Slow") is None)

    # Once they do fill in, the number is read.
    lua2b.execute('''
        raid[2].blank = nil
        Tick(30)
        FireEvent("UNIT_INVENTORY_CHANGED", "raid2")
    ''')
    check("read once the tooltips arrive", read(lua2b, "Slow") == 80)

    # The player's own inspect window is never stolen.
    lua3 = boot(mutate)
    lua3.execute('''
        inspectWindowShown = true
        raid = { { name = "Deniz", guid = "g0", gear = FullGear(70) },
                 { name = "Bjorn", guid = "g1", inRange = true, gear = FullGear(82) } }
        RR.QueueIlvlGroup(true)
        Tick(4)
    ''')
    check("never steals the open inspect window", lua3.eval("#attempts") == 0)
    # ...and nobody is left marked as being read, which would burn a five second
    # timeout per player for a request the client refused to send anyway.
    check("nothing left pending behind the open window",
          lua3.eval("(function() local _, _, busy = RR.IlvlStatus() return busy end)()") is None)

    # A reply that never comes is not a dead end: they go back in the queue.
    lua5 = boot(mutate)
    lua5.execute('''
        raid = { { name = "Deniz", guid = "g0", gear = FullGear(70) },
                 { name = "Mute", guid = "g8", inRange = true } }
        RR.QueueIlvlGroup(true)
        Tick(1)
    ''')
    check("asked", lua5.eval("#requests") == 1)
    lua5.execute("Tick(4)")   # past the timeout
    check("gave up on the silent one",
          lua5.eval("(function() local _, _, busy = RR.IlvlStatus() return busy end)()") is None)
    check("silent player queued again",
          lua5.eval("(function() local _, waiting = RR.IlvlStatus() return waiting end)()") == 1)

    # Gear that arrives for a unit token somebody else now holds is not credited
    # to the person we asked about. The reply is still in flight here -- fired
    # before the request times out -- which is the only moment the guid matters.
    lua4 = boot(mutate)
    lua4.execute('''
        raid = { { name = "Deniz", guid = "g0", gear = FullGear(70) },
                 { name = "Bjorn", guid = "g1", inRange = true, gear = FullGear(82) } }
        RR.QueueIlvlGroup(true)
        Tick(1)
        raid[2].guid = "someone-else"
        raid[2].gear = FullGear(55)
        FireEvent("UNIT_INVENTORY_CHANGED", "raid2")
    ''')
    check("gear from a swapped unit discarded", read(lua4, "Bjorn") is None)

    return failures


BREAKAGES = {
    "range check skipped": ("Ilvl.lua", "if Readable(unit) then", "if true then"),
    "partial gear accepted": ("Ilvl.lua", "if count < 8 then return nil end", ""),
    "half-filled tooltips accepted": ("Ilvl.lua", "if count == 0 or missing > 0 then return nil end",
                                      "if count == 0 then return nil end"),
    "guid check dropped": ("Ilvl.lua", "if UnitGUID(pending.unit) ~= pending.guid then",
                           "if false then"),
    "steals the inspect window": ("Ilvl.lua", "if InspectWindowOpen() then return end", ""),
    "failed reads dropped instead of retried": ("Ilvl.lua",
                                                "RR.QueueIlvl(waiting.name)\n    end", "end"),
    "claim outranks a reading": ("Ilvl.lua",
                                 "local record = RR.ilvl[name]\n    if record and record.value then",
                                 "local record = RR.ilvl[name]\n    if false then"),
}

if __name__ == "__main__":
    failures = run()
    for name in failures:
        print("FAIL " + name)

    caught = 0
    for label, (target, old, new) in BREAKAGES.items():
        def mutate(name, src, target=target, old=old, new=new):
            if name == target:
                assert old in src, "mutation text missing: " + label
                return src.replace(old, new, 1)
            return src
        try:
            broke = run(mutate)
        except Exception as err:
            broke = ["raised: " + str(err)]
        if broke:
            print("caught %-42s by %s" % (label, broke[0]))
            caught += 1
        else:
            failures.append("mutation not caught: " + label)
            print("FAIL mutation not caught: " + label)

    print("FAILURES: %d" % len(failures) if failures else "all checks pass")
    sys.exit(1 if failures else 0)
