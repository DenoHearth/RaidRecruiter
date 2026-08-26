-- Item level of everyone in the group, read off their actual gear.
--
-- This is the one thing inspection on this client is genuinely good for. A role
-- cannot be read off a build here (see the header of Inspect.lua, which is why
-- that file is retired), but equipment is equipment: what someone is wearing is
-- a fact, not an interpretation.
--
-- How it is read is not a free choice on this server. Items are rescaled
-- server-side, so GetItemInfo(link) hands back the item's *base* item level --
-- the wrong number -- and the item shown on a character can be a skin over a
-- different item. The only truthful source is the tooltip the client builds for
-- that unit's slot:
--
--   GameTooltip:SetInventoryItem(unit, slot)   -- then read the "Item Level" line
--
-- That is what DragonUI does for its inspect display on this client
-- (DragonUI/modules/itemlevel.lua, ScanInspectSlot), which is the proof it
-- works here, and it is why this does not use UnitAverageItemLevel or add up
-- GetItemInfo levels: those are quicker and they are wrong here.
--
-- The gear has to have arrived first, which means NotifyInspect and waiting for
-- UNIT_INVENTORY_CHANGED -- and that only works on somebody close enough. Most
-- of a raid is out of range most of the time; those are retried as people walk
-- past, never dropped.
--
-- The client gutted LibTalentQuery with a note that spam-inspecting everyone is
-- pointless here, so: one request at a time, a gap between them, and never while
-- the player has their own Inspect window open -- the inspect target is shared,
-- and stealing it would empty the window they are reading.

local ADDON_NAME, RR = ...

RR.ilvl = {}            -- name -> { value, at }

local queue = {}        -- names waiting to be asked about
local queued = {}       -- name -> true, so one name is never queued twice
local pending = nil     -- { name, unit, guid, at }
local ticker

local REQUEST_GAP = 1.5     -- seconds between two requests
local REQUEST_TIMEOUT = 5   -- no gear by then: treat as failed and move on
local RESCAN_AFTER = 900    -- re-read someone after 15 minutes
local RETRY_AFTER = 30      -- someone out of range: try again this often

local lastRequest = 0
local retryAt = {}          -- name -> GetTime() before which not to try again

-- Reading -----------------------------------------------------------------------

local function InspectWindowOpen()
    local frame = _G.AscensionInspectFrame or _G.InspectFrame
    return frame and frame.IsShown and frame:IsShown()
end

local function Readable(unit)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then
        return false
    end
    if not UnitIsVisible(unit) then return false end
    if type(CanInspect) == "function" then
        local ok, allowed = pcall(CanInspect, unit)
        if ok and not allowed then return false end
    end
    if type(CheckInteractDistance) == "function" then
        -- 1 is the inspect range, the same one the right-click menu greys out.
        local ok, close = pcall(CheckInteractDistance, unit, 1)
        if ok and not close then return false end
    end
    return true
end

-- The slots that carry an item level. 4 is the shirt and 19 the tabard: neither
-- has one, and counting them drags the average down for anybody wearing one.
-- Same list DragonUI averages over.
local SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }

-- The plain-text start of the localised "Item Level %d" line, matched literally
-- because a localised string can contain Lua pattern characters.
local ITEM_LEVEL_PREFIX = string.gsub(ITEM_LEVEL or "Item Level %d", "%%d.*", "")

local scanTip, scanTipName

-- One slot, out of the tooltip the client builds for that unit -- the only place
-- the rescaled item level appears.
local function SlotItemLevel(unit, slot)
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "RaidRecruiterIlvlScanTip", nil, "GameTooltipTemplate")
        scanTipName = scanTip:GetName()
    end

    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetInventoryItem(unit, slot)

    local level
    for i = 2, (scanTip:NumLines() or 0) do
        local line = _G[scanTipName .. "TextLeft" .. i]
        local text = line and line:GetText()
        if text and string.find(text, ITEM_LEVEL_PREFIX, 1, true) then
            level = tonumber(string.match(text, "(%d+)"))
            if level then break end
        end
    end

    scanTip:Hide()
    return level
end

-- The number for one unit. Nothing at all comes back while the answer would be a
-- guess: a filled slot the tooltip cannot price yet means the data is still
-- arriving, and half a set of gear averages to a number that is simply false.
function RR.ReadItemLevel(unit)
    local sum, count, missing = 0, 0, 0

    for _, slot in ipairs(SLOTS) do
        local ok, texture = pcall(GetInventoryItemTexture, unit, slot)
        if ok and texture then
            local level = SlotItemLevel(unit, slot)
            if level and level > 0 then
                sum = sum + level
                count = count + 1
            else
                missing = missing + 1
            end
        end
    end

    if count == 0 or missing > 0 then return nil end

    -- Somebody genuinely wearing seven items is not what this is looking at; it
    -- is gear that has not finished arriving.
    if count < 8 then return nil end

    return sum / count
end

-- What the rest of the addon asks -----------------------------------------------

-- Their item level and where it came from: read off their gear, or the number
-- they quoted when they whispered. The read one wins -- an applicant's own
-- figure is a claim, and half of them round it up.
function RR.ItemLevelOf(name)
    if not name then return nil end

    local record = RR.ilvl[name]
    if record and record.value then
        return record.value, "read", record.at
    end

    local applicant = RR.GetApplicant and RR.GetApplicant(name)
    if applicant and applicant.ilvl then
        return applicant.ilvl, "said", applicant.lastSeen
    end

    return nil
end

function RR.IlvlStatus()
    local known, waiting = 0, #queue
    for _ in pairs(RR.ilvl) do known = known + 1 end
    return known, waiting, pending and pending.name or nil
end

-- Two decimals, the way FrostSeek quotes it in whispers -- on this server item
-- level really is fractional, and the digits are what separate two people who
-- both say "62".
function RR.FormatItemLevel(value)
    if not value then return nil end
    return string.format("%.2f", value)
end

-- The queue ---------------------------------------------------------------------

function RR.QueueIlvl(name, front)
    if not name or queued[name] then return end
    queued[name] = true
    if front then
        table.insert(queue, 1, name)
    else
        queue[#queue + 1] = name
    end
end

function RR.QueueIlvlGroup(force)
    local now = time()
    for name in pairs(RR.GroupUnits and RR.GroupUnits() or {}) do
        local known = RR.ilvl[name]
        if force or not known or (now - (known.at or 0)) > RESCAN_AFTER then
            if force then retryAt[name] = nil end
            RR.QueueIlvl(name)
        end
    end

    -- Your own gear needs no inspecting at all.
    local me = UnitName("player")
    if me then
        local value = RR.ReadItemLevel("player")
        if value then RR.ilvl[me] = { value = value, at = time() } end
    end
end

local function Finish(value)
    local waiting = pending
    pending = nil
    if not waiting then return end

    queued[waiting.name] = nil

    if value then
        RR.ilvl[waiting.name] = { value = value, at = time() }
        if RR.RefreshRolesUI then RR.RefreshRolesUI() end
        if RR.RefreshList then RR.RefreshList() end
    else
        -- Out of range or gear that never arrived is the normal state of most of
        -- a raid, and it fixes itself when they walk past. Never reported.
        retryAt[waiting.name] = GetTime() + RETRY_AFTER
        RR.QueueIlvl(waiting.name)
    end
end

local function SendNext()
    if pending or #queue == 0 then return end
    if InspectWindowOpen() then return end
    if type(NotifyInspect) ~= "function" then return end
    if GetTime() - lastRequest < REQUEST_GAP then return end

    local units = RR.GroupUnits and RR.GroupUnits() or {}

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
                pcall(NotifyInspect, unit)
                return
            end
            retryAt[name] = GetTime() + RETRY_AFTER
        end
    end
end

-- Their gear arrived. It can also arrive without being asked for -- somebody
-- swapping a weapon next to you -- which is free data and worth keeping.
local function OnInventory(unit)
    if not unit then return end

    local name = UnitName(unit)
    if not name then return end

    if pending and pending.name == name then
        -- The unit token can have been reused by somebody else between asking
        -- and answering; the GUID says the gear belongs to who we asked about.
        if UnitGUID(pending.unit) ~= pending.guid then
            Finish(nil)
            return
        end
        Finish(RR.ReadItemLevel(unit))
        return
    end

    local units = RR.GroupUnits and RR.GroupUnits() or {}
    if units[name] then
        local value = RR.ReadItemLevel(unit)
        if value then
            RR.ilvl[name] = { value = value, at = time() }
            if RR.RefreshRolesUI then RR.RefreshRolesUI() end
        end
    end
end

-- Loading -------------------------------------------------------------------------

function RR.Ilvl_Init()
    local watcher = CreateFrame("Frame")
    for _, event in ipairs({ "UNIT_INVENTORY_CHANGED", "INSPECT_READY",
                             "RAID_ROSTER_UPDATE", "PARTY_MEMBERS_CHANGED" }) do
        pcall(watcher.RegisterEvent, watcher, event)
    end

    watcher:SetScript("OnEvent", function(self, event, arg1)
        if event == "UNIT_INVENTORY_CHANGED" or event == "INSPECT_READY" then
            OnInventory(arg1)
        else
            -- Somebody joined: read them when they are close enough.
            RR.QueueIlvlGroup()
        end
    end)

    ticker = C_Timer.NewTicker(1, function()
        if pending and (GetTime() - pending.at) > REQUEST_TIMEOUT then
            Finish(nil)
        end
        SendNext()
    end)
end
