# Builds the real Loot page against a stub widget API and refreshes it in every
# state it can be in, which is what catches a nil field or a renamed helper -- the
# failures that otherwise show up as a silent dead tab in game.

import io, os, sys
from lupa.lua51 import LuaRuntime

ADDON = r"C:\Ascension\Launcher\resources\ascension-live\Interface\AddOns\RaidRecruiter"
FILES = ["Core.lua", "Loot.lua", "LootBag.lua", "LootUI.lua"]

AXE = '"|cffa335ee|Hitem:40395::::::::80:::::|h[Torch of Holy Fire]|h|r"'

PRELUDE = r"""
GetTime_value = 1000
function GetTime() return GetTime_value end
function time() return 100000 end
RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)"
LOOT_ITEM_SELF = "You receive loot: %s."
LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
MAX_TRADABLE_ITEMS = 6
SlashCmdList = {}
RAID_CLASS_COLORS = {}

corpse, bags, tradeSlots, raidNames, printed = {}, {}, {}, {}, {}
cursor, tradePartner, targetName = nil, nil, "Patchwerk"

function GetNumLootItems() return #corpse end
function GetLootSlotLink(slot) return corpse[slot] and corpse[slot].link end
function GetLootSlotInfo(slot)
    local item = corpse[slot]
    if not item then return end
    return "tex", item.name, 1, item.quality or 4, false
end
function GetLootMethod() return "master", 0 end
function GetContainerNumSlots(bag) return bags[bag] and #bags[bag] or 0 end
function GetContainerItemLink(bag, slot)
    return bags[bag] and bags[bag][slot] and bags[bag][slot].link
end
function GetContainerItemInfo(bag, slot)
    local item = bags[bag] and bags[bag][slot]
    if not item then return end
    return "tex", item.count or 1, false, 4, false, false, item.link
end
function UnitName(unit)
    if unit == "NPC" then return tradePartner end
    if unit == "target" then return targetName end
    if unit == "player" then return "Deniz" end
    local i = string.match(unit or "", "^raid(%d+)$")
    if i then return raidNames[tonumber(i)] end
end
function GetNumRaidMembers() return #raidNames end
function GetNumPartyMembers() return 0 end
function IsRaidLeader() return true end
function IsRaidOfficer() return false end
function SendChatMessage() end
function GetItemInfo(link) return "Item", link, 4, 80, 80, "", "", 1, "", "tex" end
function GetCursorInfo() return cursorKind, cursorID, cursorLink end
function ClearCursor() cursorKind, cursorID, cursorLink = nil, nil, nil end
function CursorHasItem() return cursorKind ~= nil end
function GetRaidRosterInfo(i) return raidNames[i] end
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) printed[#printed + 1] = m end }

GameTooltip = setmetatable({}, { __index = function(t, k)
    local fn = function() return t end
    rawset(t, k, fn)
    return fn
end })

-- Every widget answers every call. Anything the page reads back (IsShown, text)
-- is real, so the refresh takes the same branches it takes in game.
widgets = {}
function StubWidget(kind)
    local w = { kind = kind, shown = true, scripts = {}, points = {} }
    setmetatable(w, { __index = function(t, key)
        local fn = function(...) return t end
        rawset(t, key, fn)
        return fn
    end })
    w.Show = function(self) self.shown = true end
    w.Hide = function(self) self.shown = false end
    w.IsShown = function(self) return self.shown end
    w.SetText = function(self, text) self.textValue = text end
    w.GetText = function(self) return self.textValue end
    w.SetScript = function(self, script, fn) self.scripts[script] = fn end
    w.HookScript = w.SetScript
    w.GetFont = function() return "font", 10, "" end
    w.CreateFontString = function(self) return StubWidget("fontstring") end
    w.CreateTexture = function(self) return StubWidget("texture") end
    w.GetParent = function(self) return self.parent end
    w.SetBackdrop = function() end
    widgets[#widgets + 1] = w
    return w
end
function CreateFrame(kind, name, parent, template)
    local frame = StubWidget(kind or "Frame")
    frame.parent = parent
    frame.events = {}
    frame.RegisterEvent = function(self, event) self.events[event] = true end
    return frame
end
C_Timer = { After = function(d, fn) end, NewTicker = function(i, fn)
    return { Cancel = function(self) end }
end }
"""

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(PRELUDE)
lua.execute("RR = {}")
RR = lua.globals().RR

for name in FILES:
    src = io.open(os.path.join(ADDON, name), encoding="utf-8").read().lstrip("\ufeff")
    loader = lua.eval("function(s, n) return loadstring(s, n) end")(src, "@" + name)
    if loader is None:
        print("FAIL  %s does not compile" % name)
        sys.exit(1)
    loader("RaidRecruiter", RR)

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

    -- the pieces UI.lua would have supplied
    pageFrame = nil
    RR.NewPage = function(name)
        pageFrame = CreateFrame("Frame")
        return pageFrame
    end
    RR.UI_Backdrop = function() end
    RR.UI_Label = function(parent, text)
        local f = StubWidget("fontstring")
        f:SetText(text)
        return f
    end
    RR.UI_Button = function(parent, text, w, h)
        local b = CreateFrame("Button")
        b.text = StubWidget("fontstring")
        b.text:SetText(text)
        b.SetColor = function() end
        return b
    end
    RR.UI_EditBox = function() return CreateFrame("EditBox") end
    RR.GetApplicant = function() return nil end
""")

failures = []


def step(label, code):
    try:
        lua.execute(code)
    except Exception as exc:
        failures.append("%s: %s" % (label, exc))
        print("FAIL  %s\n      %s" % (label, exc))
        return False
    print("ok    %s" % label)
    return True


step("page builds", "RR.LootUI_Init()")
step("refresh with nothing at all", "RR.RefreshLootUI()")

step("refresh with a corpse", """
    raidNames = { "Deniz", "Borkk" }
    corpse = { { link = %s, name = "Torch", quality = 4 } }
    FireLootOpen = nil
    RR.lootSource = "Patchwerk"
    RR.ScanLoot()
    RR.RefreshLootUI()
""" % AXE)

step("refresh with the item in your bags instead", """
    corpse = {}
    bags[0] = { { link = %s, count = 1 } }
    RR.StashAdd(%s, 1, "Patchwerk")
    RR.RefreshLootUI()
""" % (AXE, AXE))

step("refresh with a roll running", """
    RR.StartRoll({ link = %s, name = "Torch", quality = 4, copies = 1 })
    RR.RefreshLootUI()
""" % AXE)

step("refresh with the roll closed", """
    local frame
    for _, w in ipairs(widgets) do
        local events = rawget(w, "events")
        if type(events) == "table" and events["CHAT_MSG_SYSTEM"] then frame = w end
    end
    frame.scripts["OnEvent"](frame, "CHAT_MSG_SYSTEM", "Borkk rolls 91 (1-100)")
    GetTime_value = GetTime_value + 60
    RR.CloseRoll()
    RR.RefreshLootUI()
""")

step("refresh mid trade", """
    tradePartner = "Borkk"
    TradeFrame = { IsShown = function() return true end }
    RR.pendingTrade = { name = "Borkk", link = %s, before = 1, placed = true }
    RR.RefreshLootUI()
""" % AXE)

step("refresh with the item gone from the bags", """
    bags[0] = {}
    RR.RefreshLootUI()
""")

step("scroll past the end", """
    for i = 1, 20 do
        RR.StashAdd("|cffa335ee|Hitem:" .. (50000 + i) .. "::::::::80:::::|h[Thing " .. i .. "]|h|r", 1, "Boss")
    end
    RR.RefreshLootUI()
""")

# The drop target has to read an item off the cursor and add it.
step("drop an item on the add bar", """
    cursorKind, cursorID, cursorLink = "item", 40395, %s
    local bar
    for _, w in ipairs(widgets) do
        local scripts = rawget(w, "scripts")
        if type(scripts) == "table" and scripts["OnReceiveDrag"] then bar = w end
    end
    assert(bar, "the drop target was never built")
    RR.StashClear(false)
    bar.scripts["OnReceiveDrag"](bar)
    assert(#RR.StashList() == 1, "dropping an item did not add it")
""" % AXE)

if failures:
    print("\n%d failure(s)" % len(failures))
    sys.exit(1)
print("\nall UI states render")
