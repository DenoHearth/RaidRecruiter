-- The Loot rolls page.
--
-- Left: everything there is to hand out -- what the corpse is holding and what is
-- already in your own bags from a boss you looted -- one line per item, with the
-- button that puts it up for roll. Right: the roll in progress: who rolled what,
-- who is winning, and the button that hands the item over, by master loot or by
-- trade depending on where the item actually is.

local ADDON_NAME, RR = ...

local C = RR.COLOR

local ITEM_ROWS = 8
local ITEM_ROW_H = 24
local ROLL_ROWS = 9
local ROLL_ROW_H = 22

local page, itemRows, rollRows
local sourceText, mlText, rollHeader, rollTimerText, winnerText
local assignButton, rerollButton, cancelButton, secondsBox, historyText
local dropTarget
local selectedLink
local itemOffset = 0    -- the item list scrolls: the bag outlives the corpse

local QUALITY_COLOR = {
    [0] = { 0.62, 0.62, 0.62 },
    [1] = { 1.00, 1.00, 1.00 },
    [2] = { 0.12, 1.00, 0.00 },
    [3] = { 0.00, 0.44, 0.87 },
    [4] = { 0.64, 0.21, 0.93 },
    [5] = { 1.00, 0.50, 0.00 },
    [6] = { 0.90, 0.80, 0.50 },
    [7] = { 0.90, 0.80, 0.50 },
}

local function QualityColor(quality)
    local color = QUALITY_COLOR[quality or 0] or QUALITY_COLOR[1]
    return color[1], color[2], color[3]
end

-- Item rows -------------------------------------------------------------------

local function BuildItemRow(parent, index)
    local Button = RR.UI_Button
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ITEM_ROW_H - 2)
    RR.UI_Backdrop(row, C.row[1], C.row[2], C.row[3], index % 2 == 0 and 0.5 or 0.28)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.name:SetPoint("LEFT", 6, 0)
    row.name:SetWidth(150)
    row.name:SetJustifyH("LEFT")

    -- Where the item is right now: still on the corpse, already in your bags, or
    -- both. It decides whether handing it over is master loot or a trade, so it
    -- belongs on the row and not in a tooltip.
    row.where = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.where:SetPoint("LEFT", row.name, "RIGHT", 2, 0)
    row.where:SetWidth(46)
    row.where:SetJustifyH("LEFT")

    row.roll = Button(row, "Roll", 40, 18)
    row.roll:SetPoint("RIGHT", -6, 0)
    row.roll:SetScript("OnClick", function(self)
        local item = self:GetParent().item
        if not item then return end
        if (item.copies or 0) < 1 then
            RR.Print("%s is not in your bags any more -- nothing to roll for.", item.link)
            return
        end
        selectedLink = item.link
        RR.StartRoll(item)
    end)

    -- Only bag entries can be forgotten; a corpse row disappears on its own when
    -- the corpse does.
    row.forget = Button(row, "x", 16, 18)
    row.forget:SetPoint("RIGHT", row.roll, "LEFT", -3, 0)
    row.forget:SetScript("OnClick", function(self)
        local item = self:GetParent().item
        if item and item.link then
            RR.StashRemove(item.link)
            RR.RefreshLootUI()
        end
    end)

    row:SetScript("OnEnter", function(self)
        if not self.item then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.item.link)
        if self.item.source then
            GameTooltip:AddLine("From " .. self.item.source, 0.6, 0.6, 0.6)
        end
        if (self.item.bagCopies or 0) > 0 then
            GameTooltip:AddLine("In your bags -- handed over by trade", 0.35, 0.8, 0.4)
        end
        if self.item.missing then
            GameTooltip:AddLine("No longer in your bags", 0.85, 0.3, 0.3)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

local function BuildRollRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROLL_ROW_H - 2)
    RR.UI_Backdrop(row, C.row[1], C.row[2], C.row[3], index % 2 == 0 and 0.5 or 0.28)

    row.place = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.place:SetPoint("LEFT", 6, 0)
    row.place:SetWidth(20)
    row.place:SetJustifyH("LEFT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.name:SetPoint("LEFT", row.place, "RIGHT", 2, 0)
    row.name:SetWidth(120)
    row.name:SetJustifyH("LEFT")

    row.roll = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.roll:SetPoint("LEFT", row.name, "RIGHT", 2, 0)
    row.roll:SetWidth(40)
    row.roll:SetJustifyH("LEFT")

    row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.note:SetPoint("LEFT", row.roll, "RIGHT", 2, 0)
    row.note:SetWidth(100)
    row.note:SetJustifyH("LEFT")

    row.give = RR.UI_Button(row, "Give", 40, 17)
    row.give:SetPoint("RIGHT", -6, 0)
    row.give:SetScript("OnClick", function(self)
        local name = self:GetParent().rollerName
        local roll = RR.activeRoll
        if not name or not roll then return end
        local ok, message = RR.HandOut(name, roll.link)
        RR.Print(message)
        RR.RefreshLootUI()
    end)

    return row
end

-- Refresh ---------------------------------------------------------------------

function RR.RefreshLootUI()
    if not page or not page:IsShown() then return end

    -- Source / master looter state
    local sourceLine = RR.lootSource and ("Loot from: " .. RR.lootSource) or "Loot from: --"

    local partner = RR.TradePartner and RR.TradePartner()
    local pendingTrade = RR.pendingTrade

    if pendingTrade then
        mlText:SetText(string.format("Trading %s to %s", pendingTrade.link, pendingTrade.name))
        mlText:SetTextColor(C.warn[1], C.warn[2], C.warn[3])
    elseif partner then
        mlText:SetText("Trading with " .. partner)
        mlText:SetTextColor(C.warn[1], C.warn[2], C.warn[3])
    elseif RR.IsMasterLooter() then
        mlText:SetText("You are master looter")
        mlText:SetTextColor(C.good[1], C.good[2], C.good[3])
    elseif RR.LootWindowOpen() then
        mlText:SetText("Not master loot -- rolls still work, assigning does not")
        mlText:SetTextColor(C.warn[1], C.warn[2], C.warn[3])
    else
        mlText:SetText("Loot window closed -- your bag is still rollable")
        mlText:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    end

    -- Items: the corpse and your own bags in one list.
    local items = RR.LootBag and RR.LootBag() or (RR.lootItems or {})

    local maxOffset = math.max(0, #items - ITEM_ROWS)
    if itemOffset > maxOffset then itemOffset = maxOffset end
    if itemOffset < 0 then itemOffset = 0 end

    for i = 1, ITEM_ROWS do
        local row = itemRows[i]
        local item = items[i + itemOffset]
        if item then
            row.item = item
            local text = item.name or item.link
            if (item.quantity or 1) > 1 then
                text = text .. " x" .. item.quantity
            end
            -- Two separate drops of the same item, rolled once for both -- and a
            -- copy on the corpse plus one already in your bags is still one roll.
            if (item.copies or 1) > 1 then
                text = text .. "  (" .. item.copies .. " copies)"
            end
            row.name:SetText(text)
            row.name:SetTextColor(QualityColor(item.quality))

            if item.missing then
                row.where:SetText("gone")
                row.where:SetTextColor(C.bad[1], C.bad[2], C.bad[3])
            elseif item.where == "both" then
                row.where:SetText("corpse+bag")
                row.where:SetTextColor(C.good[1], C.good[2], C.good[3])
            elseif item.where == "bag" then
                row.where:SetText("in bags")
                row.where:SetTextColor(C.good[1], C.good[2], C.good[3])
            else
                row.where:SetText("corpse")
                row.where:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
            end

            if item.stashed then row.forget:Show() else row.forget:Hide() end
            row:Show()
        else
            row.item = nil
            row:Hide()
        end
    end

    if #items > ITEM_ROWS then
        sourceLine = sourceLine .. string.format("  (%d items, scroll)", #items)
    end
    sourceText:SetText(sourceLine)

    -- Active roll
    local roll = RR.activeRoll
    if roll then
        rollHeader:SetText(roll.link)
        local remaining = RR.SecondsLeftOnRoll()
        if remaining then
            rollTimerText:SetText(string.format("%ds left", math.ceil(remaining)))
            rollTimerText:SetTextColor(C.good[1], C.good[2], C.good[3])
        else
            rollTimerText:SetText("closed")
            rollTimerText:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        end
    else
        rollHeader:SetText("No roll running -- pick an item on the left")
        rollTimerText:SetText("")
    end

    local results = roll and RR.RollResults() or {}
    local winners, tied, contested = {}, {}, 0
    if roll then
        winners, tied, contested = RR.RollOutcome()
    end
    local pending = roll and RR.PendingWinners() or {}

    local winnerNames = {}
    for _, entry in ipairs(winners) do winnerNames[entry.name] = true end
    local tiedNames = {}
    for _, entry in ipairs(tied) do tiedNames[entry.name] = true end

    for i = 1, ROLL_ROWS do
        local row = rollRows[i]
        local entry = results[i]
        if entry then
            row.rollerName = entry.name
            row.place:SetText(i .. ".")
            row.name:SetText(entry.name)

            local applicant = RR.GetApplicant and RR.GetApplicant(entry.name)
            row.name:SetTextColor(RR.ClassColor(applicant and applicant.class))

            row.roll:SetText(tostring(entry.roll))
            if winnerNames[entry.name] then
                row.roll:SetTextColor(C.good[1], C.good[2], C.good[3])
            elseif tiedNames[entry.name] then
                row.roll:SetTextColor(C.warn[1], C.warn[2], C.warn[3])
            else
                row.roll:SetTextColor(C.text[1], C.text[2], C.text[3])
            end

            if entry.late then
                row.note:SetText("late, no win")
            elseif entry.odd then
                row.note:SetText(string.format("rolled %d-%d", entry.low or 0, entry.high or 0))
            elseif roll and roll.given and roll.given[entry.name] then
                row.note:SetText("got it")
            elseif tiedNames[entry.name] then
                row.note:SetText("tied")
            else
                row.note:SetText("")
            end

            -- Handing the item over is only offered once the roll is settled, so
            -- a click during the roll cannot give it to whoever happens to lead.
            if roll and roll.closed then
                row.give:Show()
            else
                row.give:Hide()
            end
            row:Show()
        else
            row.rollerName = nil
            row:Hide()
        end
    end

    -- Winner banner and buttons
    if roll and roll.closed then
        local parts = {}
        for _, entry in ipairs(winners) do
            parts[#parts + 1] = string.format("%s (%d)", entry.name, entry.roll)
        end

        if #tied > 0 then
            local names = {}
            for _, entry in ipairs(tied) do names[#names + 1] = entry.name end
            local text = string.format("Tie at %d for the last %d: %s", tied[1].roll, contested, table.concat(names, ", "))
            if #parts > 0 then
                text = table.concat(parts, ", ") .. "  |  " .. text
            end
            winnerText:SetText(text)
            winnerText:SetTextColor(C.warn[1], C.warn[2], C.warn[3])
        elseif #winners > 0 then
            winnerText:SetText(table.concat(parts, ", ") .. (#winners > 1 and " win" or " wins"))
            winnerText:SetTextColor(C.good[1], C.good[2], C.good[3])
        else
            winnerText:SetText("Nobody rolled")
            winnerText:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        end
    elseif roll then
        local copies = roll.copies or 1
        if copies > 1 then
            winnerText:SetText(string.format("%d roll(s) in, %d copies up", #results, copies))
        else
            winnerText:SetText(string.format("%d roll(s) in", #results))
        end
        winnerText:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    else
        winnerText:SetText("")
    end

    -- One handover per click, naming who is next: a second copy is a second
    -- press, which is also the safest shape for a hardware-gated API.
    if roll and roll.closed and #pending > 0 then
        local winner = pending[1].name
        assignButton.targetName = winner

        -- The verb is the truth about what the button will do: master loot from
        -- an open corpse, or a trade out of your own bags.
        local verb = "Give to"
        local onCorpse = RR.LootWindowOpen() and RR.FindLootSlot(roll.link, RR.UsedSlotsFor(roll.link))
        if not onCorpse and RR.BagCount and RR.BagCount(roll.link) > 0 then
            verb = (partner == winner) and "Put in trade for" or "Trade to"
        end

        if #pending > 1 then
            assignButton.text:SetText(string.format("%s %s (+%d)", verb, winner, #pending - 1))
        else
            assignButton.text:SetText(verb .. " " .. winner)
        end
        assignButton:Show()
    else
        assignButton.targetName = nil
        assignButton:Hide()
    end

    if roll and roll.closed and #tied > 1 then
        -- Both buttons can be up at once: someone won a copy outright while the
        -- last one is still tied. Move the reroll aside rather than under it.
        rerollButton:ClearAllPoints()
        if assignButton:IsShown() then
            rerollButton:SetPoint("BOTTOMLEFT", assignButton, "BOTTOMRIGHT", 6, 0)
        else
            rerollButton:SetPoint("BOTTOMLEFT", 10, 10)
        end
        rerollButton:Show()
    else
        rerollButton:Hide()
    end
    if roll then cancelButton:Show() else cancelButton:Hide() end

    -- History
    local history = RR.rollHistory or {}
    if #history == 0 then
        historyText:SetText("Nothing assigned yet this session.")
    else
        local lines = {}
        for i = #history, math.max(1, #history - 2), -1 do
            local entry = history[i]
            lines[#lines + 1] = string.format("%s -> %s", entry.link, entry.winner)
        end
        historyText:SetText(table.concat(lines, "\n"))
    end
end

function RR.LoadLootWidgets()
    if not secondsBox then return end
    secondsBox:SetText(tostring(RR.db.rollSeconds or 15))
end

-- Build -----------------------------------------------------------------------

function RR.LootUI_Init()
    if not RR.NewPage then return end

    local Label, Button, EditBox = RR.UI_Label, RR.UI_Button, RR.UI_EditBox

    page = RR.NewPage("loot")

    -- Left: the corpse
    local left = CreateFrame("Frame", nil, page)
    left:SetPoint("TOPLEFT", 10, -10)
    left:SetWidth(300)
    left:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 10, 12)
    RR.UI_Backdrop(left, 0.03, 0.035, 0.045, 0.9, 1)

    local itemsLabel = Label(left, "ON THE CORPSE", 10, C.accent)
    itemsLabel:SetPoint("TOPLEFT", 10, -10)

    local rescan = Button(left, "Rescan", 52, 16)
    rescan:SetPoint("TOPRIGHT", -10, -8)
    rescan:SetScript("OnClick", function()
        RR.ScanLoot()
        RR.RefreshLootUI()
    end)

    sourceText = Label(left, "Loot from: --", 10, C.text)
    sourceText:SetPoint("TOPLEFT", itemsLabel, "BOTTOMLEFT", 0, -6)

    mlText = Label(left, "", 10, C.textDim)
    mlText:SetPoint("TOPLEFT", sourceText, "BOTTOMLEFT", 0, -3)

    local itemHolder = CreateFrame("Frame", nil, left)
    itemHolder:SetPoint("TOPLEFT", mlText, "BOTTOMLEFT", 0, -8)
    itemHolder:SetPoint("RIGHT", left, "RIGHT", -10, 0)
    itemHolder:SetHeight(ITEM_ROWS * ITEM_ROW_H + 4)
    RR.UI_Backdrop(itemHolder, 0.02, 0.02, 0.03, 1, 1)

    itemRows = {}
    for i = 1, ITEM_ROWS do
        local row = BuildItemRow(itemHolder, i)
        if i == 1 then
            row:SetPoint("TOPLEFT", 3, -3)
        else
            row:SetPoint("TOPLEFT", itemRows[i - 1], "BOTTOMLEFT", 0, -2)
        end
        row:SetPoint("RIGHT", itemHolder, "RIGHT", -3, 0)
        row:Hide()
        itemRows[i] = row
    end

    -- The bag list is longer than the eight rows the panel has room for, and it
    -- outlives the corpse, so it scrolls.
    itemHolder:EnableMouseWheel(true)
    itemHolder:SetScript("OnMouseWheel", function(self, delta)
        itemOffset = itemOffset - delta
        if itemOffset < 0 then itemOffset = 0 end
        RR.RefreshLootUI()
    end)

    -- Anything the automatic capture missed -- an item traded to you, one looted
    -- before the addon was loaded, a drop below the quality filter someone still
    -- wants rolled -- goes in by dragging it here.
    dropTarget = CreateFrame("Button", nil, left)
    dropTarget:SetHeight(20)
    dropTarget:SetPoint("TOPLEFT", itemHolder, "BOTTOMLEFT", 0, -4)
    dropTarget:SetPoint("RIGHT", itemHolder, "RIGHT", 0, 0)
    RR.UI_Backdrop(dropTarget, 0.05, 0.06, 0.08, 1, 1)

    local dropLabel = Label(dropTarget, "drag an item here to add it", 10, C.textDim)
    dropLabel:SetPoint("LEFT", 8, 0)

    local function TakeFromCursor()
        if type(GetCursorInfo) ~= "function" then return end
        local kind, itemID, link = GetCursorInfo()
        if kind ~= "item" then return end

        -- 3.3.5 hands back the link as the third return, but not for every kind
        -- of pickup, so the id is the fallback route to one.
        if not link and itemID and type(GetItemInfo) == "function" then
            local ok, _, itemLink = pcall(GetItemInfo, itemID)
            if ok then link = itemLink end
        end
        if not link then
            RR.Print("could not read that item off the cursor -- shift-click it into chat and try again.")
            return
        end

        ClearCursor()
        RR.StashAdd(link, 1, RR.lootSource or "added by hand")
        RR.Print("%s added to the loot bag.", link)
        RR.RefreshLootUI()
    end

    dropTarget:SetScript("OnReceiveDrag", TakeFromCursor)
    dropTarget:SetScript("OnClick", TakeFromCursor)
    dropTarget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Add to the loot bag", 1, 1, 1)
        GameTooltip:AddLine("Pick an item up from your bags and drop it here. Blue and up off a boss is added by itself.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    dropTarget:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local clearButton = Button(left, "Tidy", 40, 16)
    clearButton:SetPoint("RIGHT", dropTarget, "RIGHT", -3, 0)
    clearButton:SetScript("OnClick", function()
        RR.StashClear(true)
        RR.RefreshLootUI()
    end)
    clearButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Drops every remembered item that is no longer in your bags.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    clearButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local timerLabel = Label(left, "ROLL LASTS", 10, C.accent)
    timerLabel:SetPoint("TOPLEFT", dropTarget, "BOTTOMLEFT", 0, -12)

    secondsBox = EditBox(left, 40, 18, true)
    secondsBox:SetPoint("LEFT", timerLabel, "RIGHT", 8, 0)
    secondsBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    secondsBox:SetScript("OnEditFocusLost", function(self)
        local value = tonumber(self:GetText()) or 10
        if value < 5 then value = 5 end
        if value > 120 then value = 120 end
        RR.db.rollSeconds = value
        self:SetText(tostring(value))
    end)

    local secondsHint = Label(left, "seconds, announced in /rw", 10, C.textDim)
    secondsHint:SetPoint("LEFT", secondsBox, "RIGHT", 6, 0)

    local historyLabel = Label(left, "GIVEN OUT", 10, C.accent)
    historyLabel:SetPoint("TOPLEFT", timerLabel, "BOTTOMLEFT", 0, -16)

    historyText = Label(left, "", 10, C.textDim)
    historyText:SetPoint("TOPLEFT", historyLabel, "BOTTOMLEFT", 0, -5)
    historyText:SetPoint("RIGHT", left, "RIGHT", -10, 0)
    historyText:SetJustifyH("LEFT")

    -- Right: the roll
    local right = CreateFrame("Frame", nil, page)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 10, 0)
    right:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -10, 12)
    RR.UI_Backdrop(right, 0.03, 0.035, 0.045, 0.9, 1)

    local rollLabel = Label(right, "CURRENT ROLL", 10, C.accent)
    rollLabel:SetPoint("TOPLEFT", 10, -10)

    rollTimerText = Label(right, "", 12, C.good)
    rollTimerText:SetPoint("TOPRIGHT", -10, -9)

    rollHeader = Label(right, "", 12, C.text)
    rollHeader:SetPoint("TOPLEFT", rollLabel, "BOTTOMLEFT", 0, -6)
    rollHeader:SetPoint("RIGHT", right, "RIGHT", -10, 0)
    rollHeader:SetJustifyH("LEFT")

    winnerText = Label(right, "", 11, C.textDim)
    winnerText:SetPoint("TOPLEFT", rollHeader, "BOTTOMLEFT", 0, -6)

    local rollHolder = CreateFrame("Frame", nil, right)
    rollHolder:SetPoint("TOPLEFT", winnerText, "BOTTOMLEFT", 0, -8)
    rollHolder:SetPoint("RIGHT", right, "RIGHT", -10, 0)
    rollHolder:SetHeight(ROLL_ROWS * ROLL_ROW_H + 4)
    RR.UI_Backdrop(rollHolder, 0.02, 0.02, 0.03, 1, 1)

    rollRows = {}
    for i = 1, ROLL_ROWS do
        local row = BuildRollRow(rollHolder, i)
        if i == 1 then
            row:SetPoint("TOPLEFT", 3, -3)
        else
            row:SetPoint("TOPLEFT", rollRows[i - 1], "BOTTOMLEFT", 0, -2)
        end
        row:SetPoint("RIGHT", rollHolder, "RIGHT", -3, 0)
        row:Hide()
        rollRows[i] = row
    end

    assignButton = Button(right, "Give to winner", 150, 24)
    assignButton:SetPoint("BOTTOMLEFT", 10, 10)
    assignButton:SetColor(C.good)
    assignButton:SetScript("OnClick", function(self)
        local roll = RR.activeRoll
        if not roll or not self.targetName then return end
        -- HandOut, not GiveTo: the item may be on the corpse or in your bags and
        -- only it knows which, so this one click covers both.
        local ok, message = RR.HandOut(self.targetName, roll.link)
        RR.Print(message)
        RR.RefreshLootUI()
    end)
    assignButton:Hide()

    rerollButton = Button(right, "Reroll the tie", 100, 24)
    rerollButton:SetPoint("BOTTOMLEFT", 10, 10)
    rerollButton:SetColor(C.warn)
    rerollButton:SetScript("OnClick", function()
        RR.RerollTie()
        RR.RefreshLootUI()
    end)
    rerollButton:Hide()

    cancelButton = Button(right, "Cancel roll", 90, 24)
    cancelButton:SetPoint("BOTTOMRIGHT", -10, 10)
    cancelButton:SetColor(C.accentDim)
    cancelButton:SetScript("OnClick", function()
        RR.CancelRoll()
        RR.RefreshLootUI()
    end)
    cancelButton:Hide()
end
