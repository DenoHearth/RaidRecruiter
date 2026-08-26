# Drives Pull.lua: what the raid is told and when, that nothing is said twice
# however often the ticker runs, that "Pull!" lands at zero, that cancelling says
# so, and that a second timer replaces the first instead of counting alongside it.
#
# Every assertion is checked against a deliberately broken build at the bottom.

import io, os, sys
from lupa.lua51 import LuaRuntime

ADDON = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ["Core.lua", "Pull.lua"]

PRELUDE = r"""
GetTime_value = 1000
time_value = 100000
function GetTime() return GetTime_value end
function time() return time_value end
SlashCmdList = {}
RAID_CLASS_COLORS = {}
printed = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) printed[#printed + 1] = m end }

raid = { "Deniz", "Bjorn" }
function GetNumRaidMembers() return #raid end
function GetNumPartyMembers() return 0 end
function GetRaidRosterInfo(i) return raid[i] end
function UnitName(unit) return unit == "player" and raid[1] or nil end
function UnitLevel() return 80 end
function GetPartyAssignment() return false end

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
    frames[#frames + 1] = f
    return f
end

tickers = {}
C_Timer = {
    After = function(delay, fn) fn() end,
    NewTicker = function(interval, fn)
        local t = { fn = fn, interval = interval, Cancel = function(self) self.cancelled = true end }
        tickers[#tickers + 1] = t
        return t
    end,
}

-- Run the clock forward in fifth-of-a-second steps, the rate the pull ticker
-- actually runs at, so a double announcement inside one second would show up.
function Advance(seconds)
    for _ = 1, math.floor(seconds * 5) do
        GetTime_value = GetTime_value + 0.2
        for _, t in ipairs(tickers) do
            if not t.cancelled then t.fn() end
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
        RR.Pull_Init()

        announced = {}
        RR.Announce = function(msg) announced[#announced + 1] = msg end
    """)
    return lua


def said(lua):
    return [str(v) for v in lua.eval("announced").values()]


def run(mutate=None):
    failures = []

    def check(name, condition):
        if not condition:
            failures.append(name)

    lua = boot(mutate)

    lua.eval("RR.StartPull()")
    check("running", lua.eval("RR.PullActive()") is True)
    check("start announced", said(lua) == ["Pull in 15 seconds."])
    check("fifteen seconds by default", round(lua.eval("RR.PullSecondsLeft()")) == 15)

    # Nothing between fifteen and ten: a line a second is noise.
    lua.eval("Advance(4)")
    check("quiet between the callouts", said(lua) == ["Pull in 15 seconds."])

    lua.eval("Advance(1.2)")
    check("ten called", said(lua)[-1] == "10")

    lua.eval("Advance(4)")
    check("nothing between ten and five", said(lua)[-1] == "10")

    lua.eval("Advance(1.2)")
    check("five called", said(lua)[-1] == "5")

    lua.eval("Advance(4)")
    check("counted down to one", said(lua)[-4:] == ["4", "3", "2", "1"])

    # Every number exactly once, however many times the ticker ran inside a second.
    numbers = [line for line in said(lua) if line.isdigit()]
    check("nothing said twice", len(numbers) == len(set(numbers)))

    lua.eval("Advance(1.2)")
    check("pull called at zero", said(lua)[-1] == "Pull!")
    check("stopped at zero", lua.eval("RR.PullActive()") is False)

    # Cancelling tells the raid, because half of them are already running in.
    lua2 = boot(mutate)
    lua2.eval("RR.StartPull(10)")
    lua2.eval("Advance(2)")
    lua2.eval("RR.CancelPull()")
    check("cancel announced", said(lua2)[-1] == "Pull cancelled.")
    check("cancelled", lua2.eval("RR.PullActive()") is False)
    lua2.eval("Advance(20)")
    check("a cancelled timer says nothing else", said(lua2)[-1] == "Pull cancelled.")

    # A second timer replaces the first: two countdowns into the same channel is
    # the worst possible outcome.
    lua3 = boot(mutate)
    lua3.eval("RR.StartPull(15)")
    lua3.eval("Advance(2)")
    lua3.eval("RR.StartPull(5)")
    lua3.eval("Advance(6)")
    check("only one pull call", len([line for line in said(lua3) if line == "Pull!"]) == 1)
    check("no leftovers from the first", said(lua3).count("10") == 0)

    # A restart starts the callouts over: the ten it already said belonged to the
    # timer that was thrown away.
    lua3b = boot(mutate)
    lua3b.eval("RR.StartPull(15)")
    lua3b.eval("Advance(5.2)")
    check("ten called once", said(lua3b).count("10") == 1)
    lua3b.eval("RR.StartPull(15)")
    lua3b.eval("Advance(5.2)")
    check("ten called again after a restart", said(lua3b).count("10") == 2)

    # The button click is a toggle: a running timer is cancelled, not restarted.
    lua4 = boot(mutate)
    lua4.eval("RR.TogglePull()")
    lua4.eval("RR.TogglePull()")
    check("toggle cancels", lua4.eval("RR.PullActive()") is False)
    check("toggle said cancelled", said(lua4)[-1] == "Pull cancelled.")

    # Out-of-range counts are clamped rather than refused.
    lua5 = boot(mutate)
    lua5.eval("RR.StartPull(600)")
    check("clamped to the maximum", round(lua5.eval("RR.PullSecondsLeft()")) == 60)

    return failures


BREAKAGES = {
    "says every second": ("Pull.lua",
                          "if CALLOUTS[mark] and not said[mark] then",
                          "if not said[mark] then"),
    "repeats inside one second": ("Pull.lua", "and not said[mark] then", "then"),
    "never reaches zero": ("Pull.lua", "if left <= 0 then", "if false then"),
    "cancel stays silent": ("Pull.lua", 'RR.Announce("Pull cancelled.")', ""),
    # Leaving the first ticker running is harmless on its own -- both tickers
    # read the same endsAt and the same "said" table. What matters is that a
    # thrown-away timer's callouts cannot silence the new one's, and the reset
    # that guarantees it happens in two places, so both have to go. A leading *
    # means replace every occurrence.
    "callouts not reset on a restart": ("Pull.lua", "*    said = {}\n", ""),
    "no clamp": ("Pull.lua", "if seconds > RR.MAX_PULL then seconds = RR.MAX_PULL end", ""),
}

if __name__ == "__main__":
    failures = run()
    for name in failures:
        print("FAIL " + name)

    for label, (target, old, new) in BREAKAGES.items():
        def mutate(name, src, target=target, old=old, new=new):
            if name != target:
                return src
            every = old.startswith("*")
            if every:
                old = old[1:]
            assert old in src, "mutation text missing: " + label
            return src.replace(old, new) if every else src.replace(old, new, 1)
        try:
            broke = run(mutate)
        except Exception as err:
            broke = ["raised: " + str(err)]
        if broke:
            print("caught %-30s by %s" % (label, broke[0]))
        else:
            failures.append("mutation not caught: " + label)
            print("FAIL mutation not caught: " + label)

    print("FAILURES: %d" % len(failures) if failures else "all checks pass")
    sys.exit(1 if failures else 0)
