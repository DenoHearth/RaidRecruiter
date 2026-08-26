# Offline drive of RaidRecruiter's loot bag: capture, bag verification, the
# combined corpse+bag list, and the trade handover state machine.
#
# The WoW API is stubbed; every stub here is shaped after what the 3.3.5 client
# actually returns. Assertions are checked against deliberately broken builds
# below (see BROKEN_CHECKS) so a silently-always-true test cannot slip through.

import io, os, sys
from lupa.lua51 import LuaRuntime

ADDON = r"C:\Ascension\Launcher\resources\ascension-live\Interface\AddOns\RaidRecruiter"

PRELUDE = r"""
_G = _G or {}
GetTime_value = 1000
time_value = 100000

function GetTime() return GetTime_value end
function time() return time_value end
function pcall_dummy() end

RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)"
LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
LOOT_ITEM_SELF = "You receive loot: %s."
LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d."
LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
MAX_TRADABLE_ITEMS = 6

-- world state the stubs read
corpse = {}          -- slot -> { link, name, quality, quantity }
bags = {}            -- bag -> slot -> { link, count }
tradeOpen = false
tradePartner = nil
tradeSlots = {}
cursor = nil
raidNames = {}
chat = {}
printed = {}

function GetNumLootItems() return #corpse end
function GetLootSlotLink(slot) return corpse[slot] and corpse[slot].link end
function GetLootSlotInfo(slot)
    local item = corpse[slot]
    if not item then return end
    return item.texture, item.name, item.quantity or 1, item.quality or 0, false
end
function GetLootMethod() return "master", 0 end
function GiveMasterLoot(slot, index) table.remove(corpse, slot) end
function GetMasterLootCandidate(index) return raidNames[index] end

function GetContainerNumSlots(bag) return bags[bag] and #bags[bag] or 0 end
function GetContainerItemLink(bag, slot)
    return bags[bag] and bags[bag][slot] and bags[bag][slot].link
end
function GetContainerItemInfo(bag, slot)
    local item = bags[bag] and bags[bag][slot]
    if not item then return end
    return "texture", item.count or 1, false, item.quality or 4, false, false, item.link
end
function PickupContainerItem(bag, slot)
    if blockPickup then return end
    cursor = { bag = bag, slot = slot, count = bags[bag][slot].count or 1 }
end
function SplitContainerItem(bag, slot, count)
    if blockPickup then return end
    cursor = { bag = bag, slot = slot, count = count, split = true }
end
function CursorHasItem() return cursor ~= nil end
function ClearCursor() cursor = nil end

function ClickTradeButton(index)
    if not cursor then return end
    local item = bags[cursor.bag][cursor.slot]
    tradeSlots[index] = { link = item.link, count = cursor.count }
    -- The item leaves the bag the moment it is in the trade window.
    if cursor.split and (item.count or 1) > cursor.count then
        item.count = item.count - cursor.count
    else
        table.remove(bags[cursor.bag], cursor.slot)
    end
    cursor = nil
end
function GetTradePlayerItemInfo(index)
    local slot = tradeSlots[index]
    if not slot then return nil end
    return "name", "texture", slot.count
end
function InitiateTrade(unit) tradeOpen = true ; tradePartner = unit end
function CheckInteractDistance(unit, dist) return true end
function UnitName(unit)
    if unit == "NPC" then return tradePartner end
    if unit == "player" then return "Deniz" end
    if unit == "target" then return targetName end
    local index = string.match(unit or "", "^raid(%d+)$")
    if index then return raidNames[tonumber(index)] end
end
function GetNumRaidMembers() return #raidNames end
function GetNumPartyMembers() return 0 end
function IsRaidLeader() return true end
function IsRaidOfficer() return false end
function SendChatMessage(msg, channel) chat[#chat + 1] = channel .. ": " .. msg end
function GetItemInfo(link) return "Item", link, 4, 80, 80, "", "", 1, "", "texture" end
function GetRaidRosterInfo(i) return raidNames[i] end
function GetPlayerInfoByGUID() end

SlashCmdList = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) printed[#printed + 1] = m end }

-- frames
local function StubFrame()
    local frame = {}
    setmetatable(frame, { __index = function(t, key)
        local fn = function(...) return t end
        rawset(t, key, fn)
        return fn
    end })
    frame.events = {}
    frame.RegisterEvent = function(self, event) self.events[event] = true end
    frame.SetScript = function(self, script, fn) self[script .. "_fn"] = fn end
    frame.HookScript = frame.SetScript
    frame.IsShown = function() return false end
    frames[#frames + 1] = frame
    return frame
end
frames = {}
function CreateFrame(kind, name, parent, template) return StubFrame() end

-- this client's timers
timers = {}
C_Timer = {
    After = function(delay, fn) timers[#timers + 1] = fn end,
    NewTicker = function(interval, fn)
        local ticker = { fn = fn, Cancel = function(self) self.cancelled = true end }
        tickers[#tickers + 1] = ticker
        return ticker
    end,
}
tickers = {}

function FireEvent(event, ...)
    for _, frame in ipairs(frames) do
        if frame.events and frame.events[event] and frame.OnEvent_fn then
            frame.OnEvent_fn(frame, event, ...)
        end
    end
end
function RunTimers()
    local pending = timers
    timers = {}
    for _, fn in ipairs(pending) do fn() end
end
function TickAll()
    for _, ticker in ipairs(tickers) do
        if not ticker.cancelled then ticker.fn() end
    end
end
"""

FILES = ["Core.lua", "Loot.lua", "LootBag.lua"]


def build(mutate=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    for name in FILES:
        src = io.open(os.path.join(ADDON, name), encoding="utf-8").read()
        if src.startswith("\ufeff"):
            src = src[1:]
        if mutate:
            src = mutate(name, src)
        chunk = lua.eval("function(src, name) return loadstring(src, name) end")(src, "@" + name)
        if chunk is None:
            raise AssertionError("syntax error in " + name)
        chunk("RaidRecruiter", lua.globals().RR_ns)
    return lua


def boot(mutate=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    lua.execute("RR = {}")
    RR = lua.globals().RR
    for name in FILES:
        src = io.open(os.path.join(ADDON, name), encoding="utf-8").read()
        if src.startswith("\ufeff"):
            src = src[1:]
        if mutate:
            src = mutate(name, src)
        loader = lua.eval("function(src, name) return loadstring(src, name) end")(src, "@" + name)
        if loader is None:
            raise AssertionError("syntax error in " + name)
        loader("RaidRecruiter", RR)

    # ADDON_LOADED, the way Core.lua does it
    lua.execute("""
        RaidRecruiterDB = {}
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
        RR.Loot_Init()
        RR.LootBag_Init()
    """)
    return lua


AXE = "|cffa335ee|Hitem:40395::::::::80:::::|h[Torch of Holy Fire]|h|r"
RING = "|cff0070dd|Hitem:37784::::::::80:::::|h[Signet of Ranulf]|h|r"


def scenario(lua):
    """Kill a boss, loot the axe to your own bags, then hand it to the winner."""
    g = lua.globals()
    lua.execute("""
        raidNames = { "Deniz", "Borkk", "Aluna" }
        targetName = "Patchwerk"
        bags[0] = {}
        corpse = {
            { link = AXE_LINK, name = "Torch of Holy Fire", quality = 4, quantity = 1 },
            { link = RING_LINK, name = "Signet of Ranulf", quality = 3, quantity = 1 },
        }
    """.replace("AXE_LINK", repr(AXE).replace("'", '"'))
       .replace("RING_LINK", repr(RING).replace("'", '"')))
    return g


def run(name, fn):
    try:
        fn()
    except AssertionError as exc:
        print("FAIL  %s: %s" % (name, exc))
        return False
    print("ok    %s" % name)
    return True


results = []


def test_capture():
    lua = boot()
    scenario(lua)
    lua.execute("FireEvent('LOOT_OPENED')")
    # you loot the axe yourself; the slot clears first, the message follows
    lua.execute("table.remove(corpse, 1)")
    lua.execute("bags[0][1] = { link = %s, count = 1 }" % repr(AXE).replace("'", '"'))
    lua.execute("FireEvent('LOOT_SLOT_CLEARED')")
    lua.execute("FireEvent('CHAT_MSG_LOOT', 'You receive loot: ' .. %s .. '.')"
                % repr(AXE).replace("'", '"'))

    stash = lua.eval("RR.StashList()")
    assert len(stash) == 1, "expected the axe in the loot bag, got %d entries" % len(stash)
    assert stash[1].source == "Patchwerk", "boss name not recorded: %s" % stash[1].source
    assert lua.eval("RR.BagCount(%s)" % repr(AXE).replace("'", '"')) == 1, "bag scan missed it"


def test_ignores_unrelated_loot():
    lua = boot()
    scenario(lua)
    lua.execute("FireEvent('LOOT_OPENED')")
    junk = "|cffffffff|Hitem:2589::::::::80:::::|h[Linen Cloth]|h|r"
    lua.execute("FireEvent('CHAT_MSG_LOOT', 'You receive loot: %s x5.')" % junk)
    lua.execute("FireEvent('CHAT_MSG_LOOT', 'Borkk receives loot: ' .. %s .. '.')"
                % repr(AXE).replace("'", '"'))
    assert len(lua.eval("RR.StashList()")) == 0, "something that was not your boss loot got in"


def test_combined_list():
    lua = boot()
    scenario(lua)
    lua.execute("FireEvent('LOOT_OPENED')")
    # one ring already in your bags from an earlier boss, one still on this corpse
    lua.execute("bags[0][1] = { link = %s, count = 1 }" % repr(RING).replace("'", '"'))
    lua.execute("RR.StashAdd(%s, 1, 'Grobbulus')" % repr(RING).replace("'", '"'))
    items = lua.eval("RR.LootBag()")
    byname = {items[i].link: items[i] for i in range(1, len(items) + 1)}
    assert RING in byname, "the ring is missing from the list"
    entry = byname[RING]
    assert entry.copies == 2, "corpse copy plus bag copy should be 2, got %s" % entry.copies
    assert entry.where == "both", "location should be both, got %s" % entry.where
    assert len(items) == 2, "corpse and bag copies must be one row, got %d rows" % len(items)


def test_missing_from_bags():
    lua = boot()
    scenario(lua)
    lua.execute("corpse = {}")   # the corpse is gone and so is the item
    lua.execute("RR.StashAdd(%s, 1, 'Patchwerk')" % repr(AXE).replace("'", '"'))
    items = lua.eval("RR.LootBag()")
    entry = items[len(items)]
    assert entry.missing is True, "an item no longer in the bags must be flagged"
    assert entry.copies == 0, "a missing item has no copies to roll for"


def test_trade_handover():
    lua = boot()
    scenario(lua)
    lua.execute("bags[0][1] = { link = %s, count = 1 }" % repr(AXE).replace("'", '"'))
    lua.execute("RR.StashAdd(%s, 1, 'Patchwerk')" % repr(AXE).replace("'", '"'))
    lua.execute("corpse = {}")   # the corpse is long gone

    # roll it out
    lua.execute("RR.StartRoll({ link = %s, name = 'Torch', quality = 4, copies = 1 })"
                % repr(AXE).replace("'", '"'))
    lua.execute("FireEvent('CHAT_MSG_SYSTEM', 'Borkk rolls 91 (1-100)')")
    lua.execute("FireEvent('CHAT_MSG_SYSTEM', 'Aluna rolls 40 (1-100)')")
    lua.execute("GetTime_value = GetTime_value + 60")
    lua.execute("RR.CloseRoll()")

    winners = lua.eval("RR.RollWinners()")
    assert winners[1].name == "Borkk", "wrong winner: %s" % winners[1].name

    ok, message = lua.eval("function() return RR.HandOut('Borkk', %s) end"
                           % repr(AXE).replace("'", '"'))()
    assert ok, "opening the trade failed: %s" % message
    assert lua.eval("tradePartner") == "raid2", "trade opened with the wrong unit"

    # the client opens the window; the addon places the item
    lua.execute("tradePartner = 'Borkk'")
    lua.execute("TradeFrame = { IsShown = function() return true end }")
    lua.execute("FireEvent('TRADE_SHOW')")
    assert lua.eval("tradeSlots[1] ~= nil"), "the item never reached the trade window"

    # nothing is recorded as given until the item has actually left the bags
    history = lua.eval("RR.rollHistory")
    assert len(history) == 0, "handover logged before the trade even closed"

    lua.execute("FireEvent('TRADE_CLOSED') ; RunTimers()")
    history = lua.eval("RR.rollHistory")
    assert len(history) == 1, "completed trade was not recorded"
    assert history[1].winner == "Borkk", "recorded the wrong winner"
    assert history[1].roll == 91, "the winning roll was lost: %s" % history[1].roll
    assert len(lua.eval("RR.StashList()")) == 0, "the item is still in the loot bag"
    joined = "\n".join(lua.eval("table.concat(chat, '\\n')").split("\n"))
    assert "goes to Borkk (91)" in joined, "the handover was never announced:\n" + joined


def test_cancelled_trade_keeps_the_item():
    lua = boot()
    scenario(lua)
    lua.execute("bags[0][1] = { link = %s, count = 1 }" % repr(AXE).replace("'", '"'))
    lua.execute("RR.StashAdd(%s, 1, 'Patchwerk')" % repr(AXE).replace("'", '"'))
    lua.execute("corpse = {}")
    lua.execute("RR.pendingTrade = { name = 'Borkk', link = %s, before = 1, placed = true }"
                % repr(AXE).replace("'", '"'))
    lua.execute("FireEvent('TRADE_CLOSED') ; RunTimers()")

    assert len(lua.eval("RR.rollHistory")) == 0, "a cancelled trade was logged as a handover"
    assert len(lua.eval("RR.StashList()")) == 1, "the item was dropped from the loot bag anyway"


def test_stack_split():
    lua = boot()
    orb = "|cff0070dd|Hitem:43102::::::::80:::::|h[Frozen Orb]|h|r"
    lua.execute("raidNames = { 'Deniz', 'Borkk' }")
    lua.execute("bags[0] = { { link = %s, count = 5 } }" % repr(orb).replace("'", '"'))
    lua.execute("tradePartner = 'Borkk'")
    lua.execute("TradeFrame = { IsShown = function() return true end }")
    ok, message = lua.eval("function() return RR.PlaceInTrade(%s) end" % repr(orb).replace("'", '"'))()
    assert ok, "placing one off a stack failed: %s" % message
    assert lua.eval("bags[0][1].count") == 4, "the whole stack went into the trade window"
    assert lua.eval("tradeSlots[1].count") == 1, "more than one copy was traded"


def test_blocked_pickup_is_reported():
    lua = boot()
    lua.execute("bags[0] = { { link = %s, count = 1 } }" % repr(AXE).replace("'", '"'))
    lua.execute("tradePartner = 'Borkk'")
    lua.execute("TradeFrame = { IsShown = function() return true end }")
    lua.execute("blockPickup = true")
    ok, message = lua.eval("function() return RR.PlaceInTrade(%s) end" % repr(AXE).replace("'", '"'))()
    assert not ok, "a refused pickup was reported as success"
    assert "real click" in message, "the message does not explain the hardware gate: " + message


def test_master_loot_still_wins():
    """An item on the corpse is still handed over by master loot, not by trade."""
    lua = boot()
    scenario(lua)
    lua.execute("FireEvent('LOOT_OPENED')")
    lua.execute("bags[0][1] = { link = %s, count = 1 }" % repr(AXE).replace("'", '"'))
    lua.execute("RR.StashAdd(%s, 1, 'Patchwerk')" % repr(AXE).replace("'", '"'))
    ok, message = lua.eval("function() return RR.HandOut('Borkk', %s) end"
                           % repr(AXE).replace("'", '"'))()
    assert ok, "master loot handover failed: %s" % message
    assert lua.eval("tradeOpen") is False, "opened a trade while the corpse still had the item"
    # Nothing is recorded on the strength of the call alone -- the corpse has to
    # show the slot is empty first.
    assert len(lua.eval("RR.rollHistory")) == 0, "recorded the handover before the corpse confirmed it"
    lua.execute("RunTimers()")
    assert len(lua.eval("RR.rollHistory")) == 1, "master loot handover was not recorded"


def test_refused_handover_is_not_recorded():
    """GiveMasterLoot says nothing when the server refuses. The item still being
    in the slot is the only evidence, and it must not be logged as handed out."""
    lua = boot()
    scenario(lua)
    lua.execute("FireEvent('LOOT_OPENED')")
    lua.execute("GiveMasterLoot = function() end")   # server refuses: nothing moves
    ok, _ = lua.eval("function() return RR.HandOut('Borkk', %s) end"
                     % repr(AXE).replace("'", '"'))()
    lua.execute("RunTimers()")
    assert len(lua.eval("RR.rollHistory")) == 0, "a refused handover was recorded as done"
    said = " ".join(str(v) for v in lua.eval("printed").values())
    assert "did NOT go" in said, "a refused handover said nothing: %s" % said


def test_bind_confirmation_is_waited_for():
    """An item that binds does not move until the popup is answered. That is not
    a failure, and the handover has to complete once it is confirmed."""
    lua = boot()
    scenario(lua)
    lua.execute("FireEvent('LOOT_OPENED')")
    lua.execute("GiveMasterLoot = function() end")   # nothing moves until confirmed
    lua.eval("function() return RR.HandOut('Borkk', %s) end" % repr(AXE).replace("'", '"'))()
    lua.execute("FireEvent('LOOT_BIND_CONFIRM', 1)")
    lua.execute("RunTimers()")

    assert len(lua.eval("RR.rollHistory")) == 0, "recorded before the popup was answered"
    said = " ".join(str(v) for v in lua.eval("printed").values())
    assert "did NOT go" not in said, "called a bind confirmation a failure: %s" % said
    assert lua.eval("RR.pendingGive") is not None, "stopped waiting for the confirmation"

    # He answers it: the slot empties, and the handover completes.
    lua.execute("table.remove(corpse, 1) ; FireEvent('LOOT_SLOT_CLEARED', 1)")
    assert len(lua.eval("RR.rollHistory")) == 1, "the confirmed handover was never recorded"


TESTS = [
    ("loot capture", test_capture),
    ("ignores unrelated loot", test_ignores_unrelated_loot),
    ("corpse and bag in one row", test_combined_list),
    ("item gone from bags", test_missing_from_bags),
    ("trade handover", test_trade_handover),
    ("cancelled trade", test_cancelled_trade_keeps_the_item),
    ("one off a stack", test_stack_split),
    ("blocked pickup", test_blocked_pickup_is_reported),
    ("corpse beats bag", test_master_loot_still_wins),
    ("refused handover", test_refused_handover_is_not_recorded),
    ("bind confirmation", test_bind_confirmation_is_waited_for),
]

BROKEN_CHECKS = [
    ("capture accepts anything",
     ("LootBag.lua", "if not info then return end", "info = info or {}"),
     "ignores unrelated loot"),
    ("corpse and bag counted separately",
     ("LootBag.lua", "existing.copies = existing.corpseCopies + have",
      "existing.copies = existing.corpseCopies"),
     "corpse and bag in one row"),
    ("handover logged before the trade completes",
     ("LootBag.lua", "if now < (pending.before or 0) then", "if true then"),
     "cancelled trade"),
    ("whole stack traded",
     ("LootBag.lua", "pcall(SplitContainerItem, place.bag, place.slot, 1)",
      "pcall(PickupContainerItem, place.bag, place.slot)"),
     "one off a stack"),
    ("blocked pickup reported as success",
     ("LootBag.lua", "if CursorHasItem and not CursorHasItem() then", "if false then"),
     "blocked pickup"),
    ("trade preferred over the open corpse",
     ("Loot.lua", "if RR.LootWindowOpen() and RR.FindLootSlot(link, RR.UsedSlotsFor(link)) then",
      "if false then"),
     "corpse beats bag"),
    ("handover recorded without checking the corpse",
     ("Loot.lua", "if stillThere then", "if false then"),
     "refused handover"),
    ("a bind confirmation treated as a failure",
     ("Loot.lua", "if waiting.bindPrompt then", "if false then"),
     "bind confirmation"),
]


def check_broken():
    """A test that cannot fail is not a test: break each behaviour, expect a fail."""
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
            # An assertion or an outright Lua error both count: the broken build
            # did not quietly pass.
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

    ok = passed == len(TESTS) and caught == len(BROKEN_CHECKS)
    sys.exit(0 if ok else 1)
