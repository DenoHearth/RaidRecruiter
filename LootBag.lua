-- The loot bag: boss drops that are already in your own bags.
--
-- The corpse is not the only place raid loot lives. The moment you loot a drop
-- to yourself -- because the corpse was about to despawn, because you are not
-- master looter, because someone said "just take it and sort it after" -- the
-- loot window closes and every roll tool on this client forgets the item ever
-- existed. This file is the memory: every blue-and-up item that leaves a corpse
-- into your bags is remembered, with the boss it came off, and stays rollable.
--
-- Handing one of those over is a trade, not GiveMasterLoot, so the two halves of
-- a handover are tracked separately: the item is only recorded as given once it
-- has actually left your bags. A cancelled trade leaves the winner pending, and
-- says so, instead of quietly logging a handover that never happened.
--
-- Every item move stays inside a real button click. PickupContainerItem and
-- SplitContainerItem are hardware-gated on this client (same family as
-- PlaceAuctionBid), so an automatic placement from an event handler would be
-- refused silently. The one placement attempted from an event -- when the trade
-- window opens by itself -- verifies afterwards and falls back to the button.

local ADDON_NAME, RR = ...

RR.corpseSnapshot = {}      -- link -> what the open corpse offered
RR.corpseSource = nil       -- who that corpse was
RR.corpseSeenAt = 0         -- GetTime() of the last snapshot
RR.pendingTrade = nil       -- { name, link, before, placed }

local SNAPSHOT_WINDOW = 60  -- seconds a corpse snapshot stays valid for matching
local MAX_TRADE_SLOTS = 6   -- MAX_TRADABLE_ITEMS; slot 7 is the enchant slot

-- Bags ------------------------------------------------------------------------

local NUM_BAGS = 4          -- 0 is the backpack, 1-4 the equipped bags

-- Every slot holding this exact link. The link, not the item id: an item link
-- carries the enchant and suffix, so two "Signet of Ranulf" of different suffix
-- are two different items and must never be treated as copies of each other.
function RR.BagSlots(link)
    local found, total = {}, 0
    if type(GetContainerNumSlots) ~= "function" then return found, total end

    for bag = 0, NUM_BAGS do
        local ok, slots = pcall(GetContainerNumSlots, bag)
        if ok and (slots or 0) > 0 then
            for slot = 1, slots do
                local okLink, current = pcall(GetContainerItemLink, bag, slot)
                if okLink and current == link then
                    local count = 1
                    local okInfo, _, stack = pcall(GetContainerItemInfo, bag, slot)
                    if okInfo and (stack or 0) > 1 then count = stack end
                    found[#found + 1] = { bag = bag, slot = slot, count = count }
                    total = total + count
                end
            end
        end
    end
    return found, total
end

function RR.BagCount(link)
    local _, total = RR.BagSlots(link)
    return total
end

-- Remembering what was looted -------------------------------------------------

local function LootMessagePatterns()
    local patterns = {}
    for _, key in ipairs({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF",
                           "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF" }) do
        local format = _G[key]
        if type(format) == "string" and format ~= "" then
            local pattern = string.gsub(format, "([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
            pattern = string.gsub(pattern, "%%s", "(.+)")
            pattern = string.gsub(pattern, "%%d", "(%%d+)")
            patterns[#patterns + 1] = "^" .. pattern .. "$"
        end
    end
    -- Only a fallback for a client with the strings missing; the real ones win.
    patterns[#patterns + 1] = "^You receive loot: (.+)x(%d+)%.$"
    patterns[#patterns + 1] = "^You receive loot: (.+)%.$"
    return patterns
end

local lootPatterns

-- Returns link, quantity for a "you receive loot" line, or nil for anything else
-- (someone else's loot, money, a skill-up message).
function RR.ParseSelfLoot(message)
    if not message then return nil end
    lootPatterns = lootPatterns or LootMessagePatterns()

    for _, pattern in ipairs(lootPatterns) do
        local link, quantity = string.match(message, pattern)
        if link and string.find(link, "|Hitem:") then
            return link, tonumber(quantity) or 1
        end
    end
    return nil
end

function RR.StashList()
    RR.db.stash = RR.db.stash or {}
    return RR.db.stash
end

-- Adds to the bag, or tops up an entry that is already there. Returns the entry.
function RR.StashAdd(link, quantity, source, info)
    if not link then return nil end
    local stash = RR.StashList()

    for _, entry in ipairs(stash) do
        if entry.link == link then
            entry.count = (entry.count or 1) + (quantity or 1)
            entry.at = time()
            entry.source = entry.source or source
            return entry
        end
    end

    local name, quality, texture = nil, nil, nil
    if info then
        name, quality, texture = info.name, info.quality, info.texture
    end
    if not name and type(GetItemInfo) == "function" then
        local ok, itemName, _, itemQuality, _, _, _, _, _, itemTexture = pcall(GetItemInfo, link)
        if ok then
            name, quality, texture = itemName, itemQuality, itemTexture
        end
    end

    local entry = {
        link = link,
        name = name or link,
        quality = quality or 0,
        texture = texture,
        count = quantity or 1,
        source = source,
        at = time(),
    }
    stash[#stash + 1] = entry
    return entry
end

function RR.StashRemove(link)
    local stash = RR.StashList()
    for i = #stash, 1, -1 do
        if stash[i].link == link then
            table.remove(stash, i)
        end
    end
end

-- One copy handed over. The entry only disappears when the last copy is gone,
-- so the second of two drops stays on the list after the first is traded away.
function RR.StashTake(link, quantity)
    local stash = RR.StashList()
    for i = #stash, 1, -1 do
        local entry = stash[i]
        if entry.link == link then
            entry.count = (entry.count or 1) - (quantity or 1)
            if entry.count <= 0 then
                table.remove(stash, i)
            end
            return
        end
    end
end

function RR.StashClear(onlyMissing)
    local stash = RR.StashList()
    for i = #stash, 1, -1 do
        if not onlyMissing or RR.BagCount(stash[i].link) <= 0 then
            table.remove(stash, i)
        end
    end
end

-- Old entries are dropped on login: a week-old raid drop sitting in the list is
-- noise, and by then it has been sold, disenchanted or equipped anyway.
function RR.StashPrune()
    local stash = RR.StashList()
    local hours = tonumber(RR.db.stashHours) or 12
    local cutoff = time() - hours * 3600
    for i = #stash, 1, -1 do
        if (stash[i].at or 0) < cutoff then
            table.remove(stash, i)
        end
    end
end

-- The list the loot page shows ------------------------------------------------
--
-- Corpse and bag in one list, deduplicated by link. An item that is both on the
-- corpse and already in your bags is one roll for the total number of copies --
-- which is the whole point: you looted one of the two and the raid should still
-- roll for both at once.

function RR.LootBag()
    local items, byLink = {}, {}

    for _, item in ipairs(RR.ScanLoot()) do
        local entry = {
            link = item.link,
            name = item.name,
            quality = item.quality,
            texture = item.texture,
            quantity = item.quantity,
            copies = item.copies or 1,
            corpseCopies = item.copies or 1,
            bagCopies = 0,
            where = "corpse",
            source = RR.lootSource,
        }
        byLink[item.link] = entry
        items[#items + 1] = entry
    end

    for _, stashed in ipairs(RR.StashList()) do
        local have = RR.BagCount(stashed.link)
        local existing = byLink[stashed.link]
        if existing then
            existing.bagCopies = have
            existing.copies = existing.corpseCopies + have
            existing.stashed = stashed
            existing.where = have > 0 and "both" or "corpse"
        else
            items[#items + 1] = {
                link = stashed.link,
                name = stashed.name,
                quality = stashed.quality,
                texture = stashed.texture,
                quantity = 1,
                copies = have,
                corpseCopies = 0,
                bagCopies = have,
                where = "bag",
                missing = have <= 0,
                source = stashed.source,
                at = stashed.at,
                stashed = stashed,
            }
        end
    end

    return items
end

-- Trading ---------------------------------------------------------------------

function RR.UnitForName(name)
    if not name then return nil end

    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    for i = 1, raid do
        if UnitName("raid" .. i) == name then return "raid" .. i end
    end

    local party = GetNumPartyMembers and GetNumPartyMembers() or 0
    for i = 1, party do
        if UnitName("party" .. i) == name then return "party" .. i end
    end

    if UnitName("target") == name then return "target" end
    return nil
end

local function TradePartner()
    if not TradeFrame or not TradeFrame:IsShown() then return nil end
    local ok, name = pcall(UnitName, "NPC")
    if ok then return name end
    return nil
end

RR.TradePartner = TradePartner

local function FreeTradeSlot()
    if type(GetTradePlayerItemInfo) ~= "function" then return 1 end
    local max = tonumber(MAX_TRADABLE_ITEMS) or MAX_TRADE_SLOTS
    for i = 1, max do
        local ok, name = pcall(GetTradePlayerItemInfo, i)
        if ok and not name then return i end
    end
    return nil
end

-- Puts one copy into the open trade window. Must run inside a real click, or
-- inside the TRADE_SHOW handler that verifies its own result.
--
-- Returns ok, message.
function RR.PlaceInTrade(link)
    if not link then return false, "nothing selected" end
    if not TradePartner() then return false, "no trade window is open" end

    local slots = RR.BagSlots(link)
    if #slots == 0 then
        return false, "that item is not in your bags any more"
    end

    local free = FreeTradeSlot()
    if not free then
        return false, "all six trade slots are full"
    end

    if CursorHasItem and CursorHasItem() then ClearCursor() end

    local place = slots[1]
    if place.count > 1 and type(SplitContainerItem) == "function" then
        -- A stack of five orbs is five copies in one slot; one winner gets one.
        pcall(SplitContainerItem, place.bag, place.slot, 1)
    else
        pcall(PickupContainerItem, place.bag, place.slot)
    end

    if CursorHasItem and not CursorHasItem() then
        -- This client gates item pickup behind a hardware event. Nothing threw,
        -- nothing happened -- that is what a blocked call looks like here.
        return false, "the client would not pick the item up -- press the button again (it has to be a real click)"
    end

    pcall(ClickTradeButton, free)

    if CursorHasItem and CursorHasItem() then
        ClearCursor()
        return false, "could not drop the item into the trade window"
    end

    local ok, placed = pcall(GetTradePlayerItemInfo, free)
    if ok and not placed then
        return false, "the trade slot stayed empty -- try again"
    end

    return true, "in the trade window -- press Trade to send it"
end

-- The whole handover: open a trade with the winner if one is not open, then put
-- the item in. Returns ok, message.
function RR.TradeTo(name, link)
    if not name or not link then return false, "nothing selected" end

    if RR.BagCount(link) <= 0 then
        return false, "that item is not in your bags any more"
    end

    RR.pendingTrade = {
        name = name,
        link = link,
        before = RR.BagCount(link),
        placed = false,
    }

    local partner = TradePartner()
    if partner then
        if partner ~= name then
            return false, string.format("you have a trade open with %s, not %s", partner, name)
        end
        local ok, message = RR.PlaceInTrade(link)
        if ok then RR.pendingTrade.placed = true end
        return ok, message
    end

    local unit = RR.UnitForName(name)
    if not unit then
        return false, string.format("%s is not in range -- target them and press this again", name)
    end
    if type(CheckInteractDistance) == "function" then
        local okDist, close = pcall(CheckInteractDistance, unit, 2)
        if okDist and not close then
            return false, string.format("%s is too far away to trade", name)
        end
    end

    if type(InitiateTrade) ~= "function" then
        return false, "this client has no InitiateTrade -- trade it by hand"
    end

    pcall(InitiateTrade, unit)

    -- If the trade never opens -- they declined, they walked away, the client ate
    -- it -- the pending handover has to expire, or the page keeps claiming a
    -- trade is in progress for the rest of the raid.
    local expecting = RR.pendingTrade
    if C_Timer and C_Timer.After then
        C_Timer.After(20, function()
            if RR.pendingTrade == expecting and not TradePartner() then
                RR.pendingTrade = nil
                RR.Print("no trade opened with %s -- %s is still yours to hand out.",
                    expecting.name, expecting.link)
                if RR.RefreshLootUI then RR.RefreshLootUI() end
            end
        end)
    end

    return true, string.format("opening a trade with %s", name)
end

-- Events ----------------------------------------------------------------------

local function OnLootMessage(message)
    local link, quantity = RR.ParseSelfLoot(message)
    if not link then return end

    -- Only what the corpse we just looted was actually offering, which is also
    -- what already passed the quality filter. A quest item, a herb, a crafted
    -- bag of ore is not raid loot and must never land in this list.
    if GetTime() - (RR.corpseSeenAt or 0) > SNAPSHOT_WINDOW then return end
    local info = RR.corpseSnapshot[link]
    if not info then return end

    RR.StashAdd(link, quantity, RR.corpseSource, info)
    if RR.RefreshLootUI then RR.RefreshLootUI() end
end

-- A trade is only a handover once the item has actually left the bags. Winning,
-- being offered the item, and receiving it are three different moments, and a
-- cancelled trade must not be logged as a handover.
local function SettlePendingTrade()
    local pending = RR.pendingTrade
    if not pending then return end
    RR.pendingTrade = nil

    local now = RR.BagCount(pending.link)
    if now < (pending.before or 0) then
        RR.StashTake(pending.link, (pending.before or 0) - now)
        if RR.RecordHandover then
            RR.RecordHandover(pending.name, pending.link)
        end
    else
        RR.Print("trade closed without the item -- %s is still in your bags, %s has not got it.",
            pending.link, pending.name)
    end

    if RR.RefreshLootUI then RR.RefreshLootUI() end
end

function RR.LootBag_Init()
    RR.db.stash = RR.db.stash or {}
    RR.StashPrune()

    local watcher = CreateFrame("Frame")
    for _, event in ipairs({ "CHAT_MSG_LOOT", "TRADE_SHOW", "TRADE_CLOSED", "BAG_UPDATE" }) do
        pcall(watcher.RegisterEvent, watcher, event)
    end

    watcher:SetScript("OnEvent", function(self, event, arg1)
        if event == "CHAT_MSG_LOOT" then
            OnLootMessage(arg1)

        elseif event == "TRADE_SHOW" then
            local pending = RR.pendingTrade
            if pending and not pending.placed and TradePartner() == pending.name then
                -- Attempted, not assumed: this is an event, not a click, so the
                -- pickup may be refused. PlaceInTrade checks its own result and
                -- the button below stays there to finish the job by hand.
                local ok, message = RR.PlaceInTrade(pending.link)
                pending.placed = ok
                RR.Print(message)
            end
            if RR.RefreshLootUI then RR.RefreshLootUI() end

        elseif event == "TRADE_CLOSED" then
            -- The bag does not update in the same frame the trade closes in.
            if C_Timer and C_Timer.After then
                C_Timer.After(0.6, SettlePendingTrade)
            else
                SettlePendingTrade()
            end

        elseif event == "BAG_UPDATE" then
            if RR.RefreshLootUI then RR.RefreshLootUI() end
        end
    end)
end
