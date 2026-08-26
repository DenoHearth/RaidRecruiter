-- Master loot rolls.
--
-- The job this does: you kill a boss, open the corpse, put an item up for roll,
-- watch the /roll results come in, and hand the item to whoever won -- without
-- reading the whole raid chat backwards to work out who that was.
--
-- Assignment is always a button you press. That is not only safer, it is very
-- likely required: this client gates several item-moving functions behind a real
-- hardware click (see PlaceAuctionBid and PickupContainerItem), so a click is
-- the one context where GiveMasterLoot is certain to be allowed.

local ADDON_NAME, RR = ...

RR.lootItems = {}       -- what the open corpse is offering
RR.lootSource = nil     -- who we looted
RR.activeRoll = nil     -- the roll in progress
RR.rollHistory = {}     -- finished rolls this session

local rollTicker

-- Roll message parsing --------------------------------------------------------
--
-- Built from the client's own RANDOM_ROLL_RESULT format string rather than a
-- hardcoded English sentence, so a locale change cannot silently stop every roll
-- from registering.

local function BuildRollPattern()
    local format = _G.RANDOM_ROLL_RESULT
    if type(format) ~= "string" or format == "" then
        format = "%s rolls %d (%d-%d)"
    end

    -- Escape the punctuation first, then turn the format's own placeholders into
    -- captures. The parentheses in "(1-100)" are literal text in the format.
    local pattern = format
    pattern = string.gsub(pattern, "([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
    -- "%%s" here matches one literal percent followed by s -- the format's own
    -- placeholder. Escaping it twice matches a doubled "%%s" that never occurs.
    pattern = string.gsub(pattern, "%%s", "(.+)")
    pattern = string.gsub(pattern, "%%d", "(%%d+)")
    return "^" .. pattern .. "$"
end

local rollPattern

function RR.ParseRoll(message)
    if not message then return nil end
    rollPattern = rollPattern or BuildRollPattern()

    local name, roll, low, high = string.match(message, rollPattern)
    if not name then return nil end

    roll, low, high = tonumber(roll), tonumber(low), tonumber(high)
    if not roll then return nil end
    return name, roll, low, high
end

-- Loot window -----------------------------------------------------------------

function RR.IsMasterLooter()
    if type(GetLootMethod) ~= "function" then return false end
    local method, partyIndex, raidIndex = GetLootMethod()
    if method ~= "master" then return false end
    -- 0 (party) / nil+raid index means "you". Blizzard reports the player as
    -- partyIndex 0, and as a raid index only for other people.
    return partyIndex == 0 or (partyIndex == nil and raidIndex == nil)
end

-- Only items worth rolling for. Grey/white/green trash on a boss corpse would
-- bury the two items anyone cares about.
local DEFAULT_MIN_QUALITY = 3   -- blue and up

function RR.ScanLoot()
    local items = {}

    if type(GetNumLootItems) ~= "function" then
        RR.lootItems = items
        return items
    end

    local minQuality = RR.db and RR.db.lootMinQuality or DEFAULT_MIN_QUALITY
    -- Two of the same item off one boss is one roll for two copies, never two
    -- separate rolls -- so identical links collapse into a single entry that
    -- remembers how many slots hold it.
    local byLink = {}

    for slot = 1, GetNumLootItems() do
        local ok, link = pcall(GetLootSlotLink, slot)
        if ok and link then
            -- GetLootSlotInfo returns texture, name, quantity, quality, locked.
            local okInfo, texture, name, quantity, quality = pcall(GetLootSlotInfo, slot)
            if not okInfo then
                texture, name, quantity, quality = nil, nil, 1, 0
            end
            if (quality or 0) >= minQuality then
                local existing = byLink[link]
                if existing then
                    existing.copies = existing.copies + 1
                    existing.slots[#existing.slots + 1] = slot
                else
                    local entry = {
                        slot = slot,
                        slots = { slot },
                        copies = 1,
                        link = link,
                        name = name or link,
                        quality = quality or 0,
                        texture = texture,
                        quantity = quantity or 1,
                    }
                    byLink[link] = entry
                    items[#items + 1] = entry
                end
                -- Remember what this corpse was offering even after the slot is
                -- emptied: the "you receive loot" line that tells the bag list an
                -- item is now yours arrives after the slot has already cleared.
                if RR.corpseSnapshot then
                    RR.corpseSnapshot[link] = RR.corpseSnapshot[link] or {
                        name = name, quality = quality, texture = texture,
                    }
                    RR.corpseSeenAt = GetTime()
                end
            end
        end
    end

    RR.lootItems = items
    return items
end

-- The slot number is only valid while this loot window is open, and it shifts as
-- other slots are taken. Always re-find the item by its link before assigning.
--
-- `exclude` skips slots this roll has already handed out. Two copies of an item
-- sit in two slots holding the identical link, and the slot a copy came from
-- does not necessarily read as empty the instant GiveMasterLoot returns -- that
-- is a server round trip. Without this, two quick clicks both target slot one.
function RR.FindLootSlot(link, exclude)
    if type(GetNumLootItems) ~= "function" then return nil end
    for slot = 1, GetNumLootItems() do
        if not (exclude and exclude[slot]) then
            local ok, current = pcall(GetLootSlotLink, slot)
            if ok and current == link then
                return slot
            end
        end
    end
    return nil
end

function RR.LootWindowOpen()
    if type(GetNumLootItems) ~= "function" then return false end
    local ok, count = pcall(GetNumLootItems)
    return ok and (count or 0) > 0
end

-- Rolls -----------------------------------------------------------------------

-- Loot calls go out as a raid warning: that is how this raid runs them, and a
-- roll line lost in raid chat is a roll nobody answers. Falls back to plain raid
-- chat when the player has no warning rights (RAID_WARNING silently sends
-- nothing for a member who is neither leader nor assistant).
local function AnnounceChannel()
    local inRaid = GetNumRaidMembers and GetNumRaidMembers() > 0
    if inRaid then
        local leader = IsRaidLeader and IsRaidLeader()
        local officer = IsRaidOfficer and IsRaidOfficer()
        if leader or officer then
            return "RAID_WARNING"
        end
        return "RAID"
    end
    if GetNumPartyMembers and GetNumPartyMembers() > 0 then
        return "PARTY"
    end
    return nil
end

local function Announce(message)
    local channel = AnnounceChannel()
    if not channel then
        RR.Print(message)
        return
    end
    pcall(SendChatMessage, message, channel)
end

RR.Announce = Announce

function RR.StartRoll(item)
    if not item or not item.link then return end

    if RR.activeRoll then
        RR.Print("a roll is already running -- finish or cancel it first.")
        return
    end

    local seconds = tonumber(RR.db.rollSeconds) or 30
    if seconds < 5 then seconds = 5 end

    local copies = tonumber(item.copies) or 1
    if copies < 1 then copies = 1 end

    RR.activeRoll = {
        link = item.link,
        name = item.name,
        quality = item.quality,
        copies = copies,
        given = {},     -- name -> true, so a second copy never goes to the same person
        usedSlots = {}, -- loot slots this roll has already handed out
        startedAt = time(),
        endsAt = GetTime() + seconds,
        seconds = seconds,
        rolls = {},     -- name -> { roll, low, high, at, late }
        order = {},     -- names, arrival order
        counted = {},   -- which countdown numbers have already been announced
        source = RR.lootSource,
        closed = false,
    }

    if copies > 1 then
        Announce(string.format("Roll on %s -- %d copies, top %d win. /roll now, %d seconds.",
            item.link, copies, copies, seconds))
    else
        Announce(string.format("Roll on %s -- /roll now, %d seconds.", item.link, seconds))
    end

    -- Quarter-second ticker, not one second: the countdown below has to catch
    -- each whole second as it passes, and a 1s ticker drifts enough to skip one.
    if rollTicker then rollTicker:Cancel() end
    rollTicker = C_Timer.NewTicker(0.25, function()
        local roll = RR.activeRoll
        if not roll then
            if rollTicker then rollTicker:Cancel() ; rollTicker = nil end
            return
        end

        -- The last seconds go out as separate raid warnings -- 5, 4, 3, 2, 1 --
        -- one line each, because that is how the raid reads a countdown.
        if not roll.closed then
            local remaining = roll.endsAt - GetTime()
            local from = tonumber(RR.db.rollCountdownFrom) or 5
            local mark = math.ceil(remaining)
            if mark >= 1 and mark <= from and not roll.counted[mark] then
                roll.counted[mark] = true
                Announce(tostring(mark))
            end
        end

        if not roll.closed and GetTime() >= roll.endsAt then
            RR.CloseRoll()
        end
        if RR.RefreshLootUI then RR.RefreshLootUI() end
    end)

    if RR.RefreshLootUI then RR.RefreshLootUI() end
end

function RR.SecondsLeftOnRoll()
    local roll = RR.activeRoll
    if not roll or roll.closed then return nil end
    local remaining = roll.endsAt - GetTime()
    if remaining < 0 then return 0 end
    return remaining
end

-- Sorted rollers, highest first. Ties keep arrival order so the display is
-- stable while people are still rolling.
function RR.RollResults()
    local roll = RR.activeRoll
    if not roll then return {} end

    local list = {}
    for _, name in ipairs(roll.order) do
        local entry = roll.rolls[name]
        if entry then
            list[#list + 1] = {
                name = name,
                roll = entry.roll,
                low = entry.low,
                high = entry.high,
                late = entry.late,
                odd = (entry.low ~= 1 or entry.high ~= 100),
                at = entry.at,
            }
        end
    end

    table.sort(list, function(a, b)
        if a.roll == b.roll then
            return (a.at or 0) < (b.at or 0)
        end
        return a.roll > b.roll
    end)
    return list
end

-- Work out who takes the copies.
--
-- Returns: winners (clear winners, at most `copies` of them), tied (the group
-- fighting over whatever is left), and how many copies that tie is for.
--
-- A tie is never broken automatically -- picking one silently is exactly the
-- thing that starts loot arguments -- but a tie for third place when there are
-- only two copies is not a tie at all, so only a tie that actually straddles
-- the cut-off is reported.
function RR.RollOutcome()
    local roll = RR.activeRoll
    local copies = (roll and roll.copies) or 1
    local results = RR.RollResults()

    -- Late rolls and non 1-100 rolls are shown but never win.
    local eligible = {}
    for _, entry in ipairs(results) do
        if not entry.late and not entry.odd then
            eligible[#eligible + 1] = entry
        end
    end

    local winners, tied = {}, {}
    local index = 1

    while #winners < copies and index <= #eligible do
        -- Everyone on this exact roll value moves or stalls together.
        local group = {}
        local value = eligible[index].roll
        while index <= #eligible and eligible[index].roll == value do
            group[#group + 1] = eligible[index]
            index = index + 1
        end

        if #winners + #group <= copies then
            for _, entry in ipairs(group) do
                winners[#winners + 1] = entry
            end
        else
            tied = group
            break
        end
    end

    return winners, tied, copies - #winners
end

-- Kept as the simple view the UI asks for most of the time.
function RR.RollWinners()
    local winners = RR.RollOutcome()
    return winners
end

function RR.CloseRoll()
    local roll = RR.activeRoll
    if not roll or roll.closed then return end

    roll.closed = true
    local winners, tied, contested = RR.RollOutcome()

    if #winners == 0 and #tied == 0 then
        Announce(string.format("No rolls on %s.", roll.link))
    end

    if #winners == 1 then
        Announce(string.format("%s wins %s with %d.", winners[1].name, roll.link, winners[1].roll))
    elseif #winners > 1 then
        local parts = {}
        for _, entry in ipairs(winners) do
            parts[#parts + 1] = string.format("%s (%d)", entry.name, entry.roll)
        end
        Announce(string.format("%s goes to %s.", roll.link, table.concat(parts, ", ")))
    end

    -- Only the copies still in dispute are rerolled; anyone who already won
    -- outright keeps their copy.
    if #tied > 0 then
        local names = {}
        for _, entry in ipairs(tied) do names[#names + 1] = entry.name end
        Announce(string.format("Tie at %d for the last %d: %s -- reroll.",
            tied[1].roll, contested, table.concat(names, ", ")))
    end

    if RR.RefreshLootUI then RR.RefreshLootUI() end
end

function RR.CancelRoll()
    if not RR.activeRoll then return end
    RR.activeRoll = nil
    if rollTicker then rollTicker:Cancel() ; rollTicker = nil end
    if RR.RefreshLootUI then RR.RefreshLootUI() end
end

-- A tie reroll keeps the same item but only accepts the tied players.
function RR.RerollTie()
    local roll = RR.activeRoll
    if not roll then return end

    local winners, tied, contested = RR.RollOutcome()
    if #tied < 2 then return end

    local names = {}
    for _, entry in ipairs(tied) do names[#names + 1] = entry.name end

    -- Anyone who already won a copy outright keeps it: the reroll is only for
    -- the contested copies, and only the tied players may roll again.
    local alreadyWon = {}
    for _, entry in ipairs(winners) do
        alreadyWon[#alreadyWon + 1] = entry
    end

    local item = {
        link = roll.link,
        name = roll.name,
        quality = roll.quality,
        copies = contested,
    }
    local given = roll.given
    RR.activeRoll = nil
    if rollTicker then rollTicker:Cancel() ; rollTicker = nil end

    RR.StartRoll(item)
    if RR.activeRoll then
        RR.activeRoll.given = given or {}
        RR.activeRoll.settled = alreadyWon
        RR.activeRoll.restrictedTo = {}
        for _, name in ipairs(names) do
            RR.activeRoll.restrictedTo[name] = true
        end
        Announce(string.format("Reroll -- %s only.", table.concat(names, ", ")))
    end
end

-- Winners who have not been handed their copy yet, in roll order. Includes
-- anyone who won outright before a tie reroll for the remaining copies.
function RR.PendingWinners()
    local roll = RR.activeRoll
    if not roll then return {} end

    local pending = {}
    for _, entry in ipairs(roll.settled or {}) do
        if not roll.given[entry.name] then
            pending[#pending + 1] = entry
        end
    end

    local winners = RR.RollOutcome()
    for _, entry in ipairs(winners) do
        if not roll.given[entry.name] then
            pending[#pending + 1] = entry
        end
    end
    return pending
end

-- Assignment ------------------------------------------------------------------
--
-- GetMasterLootCandidate is (index) on 3.3.5 and (slot, index) on later builds,
-- and this client is a hybrid, so try both shapes rather than assuming.

local function CandidateName(slot, index)
    if type(GetMasterLootCandidate) ~= "function" then return nil end

    local ok, name = pcall(GetMasterLootCandidate, index)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end

    ok, name = pcall(GetMasterLootCandidate, slot, index)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

function RR.MasterLootCandidates(slot)
    local candidates = {}
    for index = 1, 40 do
        local name = CandidateName(slot, index)
        if name then
            candidates[name] = index
        end
    end
    return candidates
end

-- What the winner rolled, if this handover belongs to the roll in progress.
local function WinningRoll(name, link)
    local roll = RR.activeRoll
    if not roll or roll.link ~= link then return nil end

    -- Look in the tied group as well: handing a contested copy to one of the
    -- tied players is a legitimate call, and their roll still belongs in the
    -- announcement.
    local winners, tied = RR.RollOutcome()
    for _, entry in ipairs(winners) do
        if entry.name == name then return entry.roll end
    end
    for _, entry in ipairs(tied) do
        if entry.name == name then return entry.roll end
    end
    for _, entry in ipairs(roll.settled or {}) do
        if entry.name == name then return entry.roll end
    end
    return nil
end

-- The item really changed hands. Announce it, log it, and close the roll if
-- every copy is out.
--
-- Announcing the handover is separate from announcing the winner on purpose: the
-- two are different moments -- a reroll, a trade, or the leader overruling the
-- roll all happen in between -- so the raid is told where the item really went.
function RR.RecordHandover(name, link, slot)
    local roll = RR.activeRoll
    local wonWith = WinningRoll(name, link)

    if wonWith then
        Announce(string.format("%s goes to %s (%d).", link, name, wonWith))
    else
        Announce(string.format("%s goes to %s.", link, name))
    end

    RR.rollHistory[#RR.rollHistory + 1] = {
        link = link,
        winner = name,
        roll = wonWith,
        at = time(),
        source = RR.lootSource,
    }
    while #RR.rollHistory > 25 do
        table.remove(RR.rollHistory, 1)
    end

    if roll and roll.link == link then
        roll.given[name] = true
        if slot then
            roll.usedSlots = roll.usedSlots or {}
            roll.usedSlots[slot] = true
        end

        local handed = 0
        for _ in pairs(roll.given) do handed = handed + 1 end

        -- With two copies up, the roll stays open after the first handover so
        -- the second copy can go to the runner-up from the same roll.
        if handed >= (roll.copies or 1) then
            RR.activeRoll = nil
            if rollTicker then rollTicker:Cancel() ; rollTicker = nil end
        end
    end

    if RR.RefreshLootUI then RR.RefreshLootUI() end
end

-- One entry point for the UI: hand this item to this player, from wherever it
-- actually is. The corpse comes first because master loot is instant and needs
-- no cooperation from the winner; a copy in your own bags is a trade.
function RR.HandOut(name, link)
    if not name or not link then
        return false, "nothing selected"
    end

    if RR.LootWindowOpen() and RR.FindLootSlot(link, RR.UsedSlotsFor(link)) then
        return RR.GiveTo(name, link)
    end

    if RR.BagCount and RR.BagCount(link) > 0 then
        return RR.TradeTo(name, link)
    end

    if RR.LootWindowOpen() then
        return false, "that item is neither in this corpse nor in your bags"
    end
    return false, "that item is not in your bags -- reopen the corpse, or trade it by hand"
end

-- Slots the roll in progress has already handed out, so a second copy never
-- targets the slot the first one came from.
function RR.UsedSlotsFor(link)
    local roll = RR.activeRoll
    if roll and roll.link == link then return roll.usedSlots end
    return nil
end

-- Master loot handover.
--
-- Returns ok, message. Never throws: every failure here is a normal situation
-- (window closed, item already taken, player out of range) and needs to be
-- readable, not a Lua error.
function RR.GiveTo(name, link)
    if not name or not link then
        return false, "nothing selected"
    end

    if not RR.LootWindowOpen() then
        return false, "the loot window is closed -- reopen the corpse, then press this again"
    end

    local roll = RR.activeRoll
    local usedSlots = (roll and roll.link == link) and roll.usedSlots or nil

    local slot = RR.FindLootSlot(link, usedSlots)
    if not slot then
        return false, "that item is no longer in this corpse"
    end

    if type(GiveMasterLoot) ~= "function" then
        return false, "this client has no GiveMasterLoot -- assign it from the loot window by hand"
    end

    local candidates = RR.MasterLootCandidates(slot)
    local index = candidates[name]
    if not index then
        return false, string.format("%s is not a master loot candidate (out of range, or not in the raid)", name)
    end

    local ok, err = pcall(GiveMasterLoot, slot, index)
    if not ok then
        return false, "GiveMasterLoot failed: " .. tostring(err)
    end

    RR.RecordHandover(name, link, slot)

    return true, string.format("%s given to %s", link, name)
end

-- Events ----------------------------------------------------------------------

local function OnRollMessage(message)
    local roll = RR.activeRoll
    if not roll then return end

    local name, value, low, high = RR.ParseRoll(message)
    if not name then return end

    if roll.restrictedTo and not roll.restrictedTo[name] then
        return
    end

    -- First roll counts. Someone rolling again after a bad result must not be
    -- able to overwrite it.
    if roll.rolls[name] then return end

    roll.rolls[name] = {
        roll = value,
        low = low,
        high = high,
        at = GetTime(),
        late = roll.closed or GetTime() > roll.endsAt,
    }
    roll.order[#roll.order + 1] = name

    if RR.RefreshLootUI then RR.RefreshLootUI() end
end

function RR.Loot_Init()
    local watcher = CreateFrame("Frame")
    for _, event in ipairs({ "LOOT_OPENED", "LOOT_CLOSED", "LOOT_SLOT_CLEARED", "CHAT_MSG_SYSTEM" }) do
        pcall(watcher.RegisterEvent, watcher, event)
    end

    watcher:SetScript("OnEvent", function(self, event, arg1)
        if event == "CHAT_MSG_SYSTEM" then
            OnRollMessage(arg1)
        elseif event == "LOOT_OPENED" then
            local source = UnitName("target") or RR.lootSource
            -- A new corpse starts a new snapshot; reopening the same one keeps
            -- what has already been looted out of it.
            if source ~= RR.corpseSource then
                RR.corpseSnapshot = {}
                RR.corpseSource = source
            end
            RR.lootSource = source
            RR.ScanLoot()
            if RR.RefreshLootUI then RR.RefreshLootUI() end
        elseif event == "LOOT_SLOT_CLEARED" then
            RR.ScanLoot()
            if RR.RefreshLootUI then RR.RefreshLootUI() end
        elseif event == "LOOT_CLOSED" then
            -- Keep the item list on screen: the roll usually outlives the loot
            -- window, and the assign button explains itself when the window is
            -- shut rather than the list simply emptying.
            if RR.RefreshLootUI then RR.RefreshLootUI() end
        end
    end)
end
