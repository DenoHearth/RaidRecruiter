# Drives RoleCall.lua against a stubbed chat and roster: the warning going out,
# answers read off raid chat, a stranger in say being ignored, chatter with no
# role word being ignored, the window closing on its own, and stopping early.
#
# RR.Announce lives in Loot.lua and is stubbed here as a recorder -- this file
# tests what the class check does with the answers, not how a raid warning is
# routed (that is Loot.lua's AnnounceChannel).
#
# Every assertion is checked against a deliberately broken build at the bottom.

import io, os, sys
from lupa.lua51 import LuaRuntime

ADDON = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ["Core.lua", "Applicants.lua", "RoleCall.lua"]

PRELUDE = r"""
GetTime_value = 1000
time_value = 100000
function GetTime() return GetTime_value end
function time() return time_value end
SlashCmdList = {}
RAID_CLASS_COLORS = {}
printed = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) printed[#printed + 1] = m end }

raid = {}     -- index -> name; index 1 is the player
function GetNumRaidMembers() return #raid end
function GetNumPartyMembers() return 0 end
function GetRaidRosterInfo(i) return raid[i] end
function UnitName(unit)
    if unit == "player" then return raid[1] end
    local i = tonumber(string.match(unit or "", "^raid(%d+)$"))
    return i and raid[i]
end
function UnitLevel() return 80 end
function GetPartyAssignment() return false end
function PlaySound() end
function Ambiguate(name) return (string.gsub(name, "%-.*$", "")) end

frames = {}
function CreateFrame(kind, name, parent)
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
        GetTime_value = GetTime_value + 1
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
        RR.Applicants_Init()
        RR.RoleCall_Init()

        announced = {}
        RR.Announce = function(msg) announced[#announced + 1] = msg end

        -- Astrid never says a word, and sorts before the player: two silent
        -- names is what proves the list comes out in name order, not roster order.
        raid = { "Deniz", "Bjorn", "Sigrid", "Halvar", "Astrid" }
    """)
    return lua


def counts(lua):
    # GroupRoles returns the counts and the unknown names; lupa hands both back.
    return dict(lua.eval("(RR.GroupRoles())"))


def run(mutate=None):
    failures = []

    def check(name, condition):
        if not condition:
            failures.append(name)

    lua = boot(mutate)
    g = lua.globals()

    # The warning goes out, once, and the check is listening.
    lua.eval("RR.StartRoleCall()")
    check("warning sent", len(g.announced) == 1)
    check("warning text", "role" in str(g.announced[1]).lower())
    check("listening", lua.eval("RR.RoleCallActive()") is True)

    # An answer in raid chat.
    lua.eval('FireEvent("CHAT_MSG_RAID", "resto here", "Bjorn")')
    check("healer recorded", lua.eval('RR.knownRoles["Bjorn"]') == "Healer")
    check("healer counted", counts(lua)["HEALER"] == 1)

    # Party-leader chat counts too, and so does a two-role answer.
    lua.eval('FireEvent("CHAT_MSG_PARTY_LEADER", "tank or dps", "Sigrid")')
    check("both roles kept", lua.eval('RR.knownRoles["Sigrid"]') == "Tank/DPS")
    check("scarce role wins", counts(lua)["TANK"] == 1)

    # A stranger shouting in say is not in the raid and must not be counted.
    lua.eval('FireEvent("CHAT_MSG_SAY", "im a healer", "Passerby")')
    check("stranger ignored", lua.eval('RR.knownRoles["Passerby"]') is None)

    # Raid chatter with no role word changes nothing.
    lua.eval('FireEvent("CHAT_MSG_RAID", "one sec, bio", "Halvar")')
    check("chatter ignored", lua.eval('RR.knownRoles["Halvar"]') is None)
    check("two answers", lua.eval("RR.RoleCallAnswerCount()") == 2)

    # A realm-qualified sender is the same player.
    lua.eval('FireEvent("CHAT_MSG_RAID", "dps", "Halvar-Area52")')
    check("realm stripped", lua.eval('RR.knownRoles["Halvar"]') == "DPS")

    # The names behind the question mark -- what the header tooltip shows -- and
    # they have to agree with the number beside them.
    unknown = list(lua.eval("RR.UnknownRoleNames()").values())
    check("unknown named", unknown == ["Astrid", "Deniz"])
    check("names match count", len(unknown) == counts(lua)["UNKNOWN"])

    # It closes itself when the window runs out, and says who never answered.
    before = len(g.printed)
    Tick = g.Tick
    Tick(61)
    check("closed on its own", lua.eval("RR.RoleCallActive()") is False)
    tail = " ".join(str(g.printed[i]) for i in range(before + 1, len(g.printed) + 1))
    check("summary printed", "3 answered" in tail)
    check("silent named", "Deniz" in tail)
    check("answerer not named", "Bjorn" not in tail)

    # Answers survive the check ending: they are what the composition runs on.
    check("roles kept", counts(lua)["HEALER"] == 1)

    # Stopping early.
    lua.eval("RR.StartRoleCall()")
    check("restarted", lua.eval("RR.RoleCallActive()") is True)
    check("count reset", lua.eval("RR.RoleCallAnswerCount()") == 0)
    lua.eval("RR.ToggleRoleCall()")
    check("stopped early", lua.eval("RR.RoleCallActive()") is False)
    # Chat only counts while a check is running: whispers are the other source,
    # and nothing else is. A role word in ordinary raid chat changes nothing.
    lua.eval('FireEvent("CHAT_MSG_RAID", "im tank", "Astrid")')
    check("chat ignored when no check is running", lua.eval('RR.knownRoles["Astrid"]') is None)

    lua.eval("RR.StartRoleCall()")
    lua.eval('FireEvent("CHAT_MSG_RAID", "im tank", "Astrid")')
    check("chat taken while asked", lua.eval('RR.knownRoles["Astrid"]') == "Tank")

    return failures


# Broken builds: each mutation must make at least one assertion fail, otherwise
# the assertion is not testing what it claims to.
BREAKAGES = {
    "no group filter": ("RoleCall.lua",
                        "if not grouped[name] then return end", ""),
    "reads chat with no check running": ("RoleCall.lua",
                                         "if not running then return end\n\n    local name = ShortName(sender)",
                                         "local name = ShortName(sender)"),
    "never expires": ("RoleCall.lua",
                      "if GetTime() >= endsAt then", "if false then"),
    "unknown names not collected": ("Core.lua",
                                    "if name then unknown[#unknown + 1] = name end", ""),
    "unknown list unsorted": ("Core.lua",
                              "table.sort(unknown)", ""),
    "answers dropped on stop": ("RoleCall.lua",
                                "local wasRunning = running", "RR.knownRoles = {}\n    local wasRunning = running"),
}

if __name__ == "__main__":
    failures = run()
    for name in failures:
        print("FAIL " + name)

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
        if not broke:
            failures.append("mutation not caught: " + label)
            print("FAIL mutation not caught: " + label)
        else:
            print("caught %-26s by %s" % (label, broke[0]))

    print("FAILURES: %d" % len(failures) if failures else "all checks pass")
    sys.exit(1 if failures else 0)
