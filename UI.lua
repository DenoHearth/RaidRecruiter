-- The window.
--
-- Left column is the broadcast: message, channels, interval, start/stop.
-- Right column is the applicant list fed by whispers.
--
-- Rows are pooled and virtualised (FauxScrollFrame), the same pattern Blizzard's
-- own addon list uses -- a raid advertised in trade can pull sixty whispers and
-- one frame per applicant would be sixty frames built during a pull.

local ADDON_NAME, RR = ...

local C = RR.COLOR

local WINDOW_W, WINDOW_H = 790, 580
local HEADER_H = 40
local LEFT_W = 300
local ROW_H = 34
local VISIBLE_ROWS = 10
local CHANNEL_ROW_H = 22
local VISIBLE_CHANNELS = 6

local window, listScroll, rows, channelScroll, channelRows
local pages, tabButtons, recruitPage
local messageBox, charCount, intervalSlider, intervalBox, startButton, statusText
local searchBox, minIlvlBox, hideGroupedCheck, roleButtons, headerButtons
local capBox, replyBox
local footerText, compText, compFrame

-- Focus handling --------------------------------------------------------------
--
-- An edit box keeps keyboard focus until something takes it away, so clicking
-- back out to the world would leave WASD typing into the box instead of moving
-- the character. Every box the addon builds is registered here and dropped as
-- soon as the click lands anywhere that is not an edit box.

local editBoxes = {}

local function ClearFocus()
    for _, box in ipairs(editBoxes) do
        if box:HasFocus() then box:ClearFocus() end
    end
end
RR.ClearEditFocus = ClearFocus

local function RegisterEditBox(box)
    tinsert(editBoxes, box)
    -- A click inside another box should not be cancelled by the window handler.
    box:SetScript("OnMouseDown", function(self) self:SetFocus() end)
end

-- Clicking the 3D world (moving, targeting) drops focus as well.
WorldFrame:HookScript("OnMouseDown", ClearFocus)

-- Building blocks -------------------------------------------------------------

local function Backdrop(frame, r, g, b, a, edge)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = edge and "Interface\\Buttons\\WHITE8X8" or nil,
        edgeSize = edge or nil,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    frame:SetBackdropColor(r, g, b, a)
    if edge then
        frame:SetBackdropBorderColor(0, 0, 0, 0.9)
    end
end

local function Label(parent, text, size, color)
    local font = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    font:SetText(text)
    local file, _, flags = font:GetFont()
    font:SetFont(file, size or 11, flags)
    color = color or C.textDim
    font:SetTextColor(color[1], color[2], color[3])
    return font
end

local function Button(parent, text, width, height)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(width)
    button:SetHeight(height)
    Backdrop(button, C.accentDim[1], C.accentDim[2], C.accentDim[3], 1, 1)

    local font = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    font:SetPoint("CENTER")
    font:SetText(text)
    font:SetTextColor(C.text[1], C.text[2], C.text[3])
    button.text = font

    button:SetScript("OnMouseDown", ClearFocus)
    button:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.accent[1], C.accent[2], C.accent[3], 1)
    end)
    button:SetScript("OnLeave", function(self)
        local color = self.baseColor or C.accentDim
        self:SetBackdropColor(color[1], color[2], color[3], 1)
    end)

    function button:SetColor(color)
        self.baseColor = color
        self:SetBackdropColor(color[1], color[2], color[3], 1)
    end

    return button
end

local function EditBox(parent, width, height, numeric)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetWidth(width)
    box:SetHeight(height)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(6, 6, 2, 2)
    Backdrop(box, 0.02, 0.02, 0.03, 1, 1)
    if numeric then box:SetNumeric(true) end
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    RegisterEditBox(box)
    return box
end

local function CheckBox(parent, text)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetWidth(20)
    check:SetHeight(20)
    local font = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    font:SetPoint("LEFT", check, "RIGHT", 2, 0)
    font:SetText(text or "")
    check.label = font
    check:HookScript("OnMouseDown", ClearFocus)
    return check
end

-- Shared with LootUI.lua so both pages are built from the same widgets.
RR.UI_Backdrop = Backdrop
RR.UI_Label = Label
RR.UI_Button = Button
RR.UI_EditBox = EditBox
RR.UI_CheckBox = CheckBox

-- Applicant rows --------------------------------------------------------------

local function BuildRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H - 2)
    Backdrop(row, C.row[1], C.row[2], C.row[3], index % 2 == 0 and 0.55 or 0.3)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.name:SetPoint("TOPLEFT", 6, -4)
    row.name:SetWidth(120)
    row.name:SetJustifyH("LEFT")

    row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.level:SetPoint("TOPLEFT", row.name, "TOPRIGHT", 2, 0)
    row.level:SetWidth(30)
    row.level:SetJustifyH("LEFT")

    row.ilvl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.ilvl:SetPoint("TOPLEFT", row.level, "TOPRIGHT", 2, 0)
    row.ilvl:SetWidth(52)
    row.ilvl:SetJustifyH("LEFT")

    row.role = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.role:SetPoint("TOPLEFT", row.ilvl, "TOPRIGHT", 2, 0)
    row.role:SetWidth(74)
    row.role:SetJustifyH("LEFT")

    row.when = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.when:SetPoint("TOPLEFT", row.role, "TOPRIGHT", 2, 0)
    row.when:SetWidth(34)
    row.when:SetJustifyH("LEFT")

    row.flag = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- Bottom right, under the buttons: the top line is already full and the
    -- message never runs that wide.
    row.flag:SetPoint("BOTTOMRIGHT", -6, 4)
    row.flag:SetWidth(120)
    row.flag:SetJustifyH("RIGHT")

    row.message = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.message:SetPoint("BOTTOMLEFT", 6, 4)
    row.message:SetWidth(300)
    row.message:SetJustifyH("LEFT")
    row.message:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])

    row.invite = Button(row, "Invite", 46, 18)
    row.invite:SetPoint("RIGHT", -60, 0)
    row.invite:SetScript("OnClick", function(self)
        if self:GetParent().applicantName then
            RR.Invite(self:GetParent().applicantName)
        end
    end)

    row.whisper = Button(row, "W", 20, 18)
    row.whisper:SetPoint("LEFT", row.invite, "RIGHT", 3, 0)
    row.whisper:SetScript("OnClick", function(self)
        if self:GetParent().applicantName then
            RR.WhisperTo(self:GetParent().applicantName)
        end
    end)

    row.remove = Button(row, "X", 20, 18)
    row.remove:SetPoint("LEFT", row.whisper, "RIGHT", 3, 0)
    row.remove:SetScript("OnClick", function(self)
        if self:GetParent().applicantName then
            RR.RemoveApplicant(self:GetParent().applicantName)
        end
    end)

    row:SetScript("OnEnter", function(self)
        if not self.applicantName then return end
        local record = RR.GetApplicant(self.applicantName)
        if not record then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(record.name, 1, 1, 1)
        if record.class then
            GameTooltip:AddLine(record.class, RR.ClassColor(record.class))
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(record.message or "", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(string.format("%d whisper(s), first %s ago", record.count or 1, RR.AgoText(record.firstSeen)), 0.6, 0.6, 0.6)
        if record.invited then
            GameTooltip:AddLine("Invited " .. RR.AgoText(record.invitedAt) .. " ago", 0.4, 0.8, 0.4)
        end
        if record.leftAt then
            GameTooltip:AddLine("Left the group " .. RR.AgoText(record.leftAt) .. " ago", 0.9, 0.3, 0.3)
        end
        if (record.leftCount or 0) > 0 then
            GameTooltip:AddLine("Left " .. record.leftCount .. " time(s) total", 0.7, 0.5, 0.5)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

local function FillRow(row, record)
    row.applicantName = record.name

    local r, g, b = RR.ClassColor(record.class)
    row.name:SetText(record.name)
    row.name:SetTextColor(r, g, b)

    row.level:SetText(record.level and tostring(record.level) or "--")

    if record.ilvl then
        -- Two decimals: this server's item levels really are fractional, and the
        -- fraction is often the only thing separating two applicants. A number
        -- in the thousands is a gearscore, which has no fractional part worth
        -- showing.
        if record.ilvl >= 1000 then
            row.ilvl:SetText(string.format("%d", record.ilvl))
        else
            row.ilvl:SetText(string.format("%.2f", record.ilvl))
        end
        local db = RR.db
        if db.minIlvl > 0 and record.ilvl < db.minIlvl then
            row.ilvl:SetTextColor(C.bad[1], C.bad[2], C.bad[3])
        else
            row.ilvl:SetTextColor(C.good[1], C.good[2], C.good[3])
        end
    else
        row.ilvl:SetText("--")
        row.ilvl:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    end

    row.role:SetText(record.role or "?")
    row.when:SetText(RR.AgoText(record.lastSeen))

    local message = record.message or ""
    if string.len(message) > 62 then
        message = string.sub(message, 1, 60) .. "..."
    end
    row.message:SetText(message)

    -- Left the group: say so and say how long ago, because a name that dropped
    -- out thirty seconds ago and one that dropped two hours ago are not the same
    -- decision. Repeat leavers carry the count.
    if record.leftAt then
        local text = "left " .. RR.AgoText(record.leftAt) .. " ago"
        if (record.leftCount or 0) > 1 then
            text = text .. " (" .. record.leftCount .. "x)"
        end
        row.flag:SetText(text)
        -- Fresh departures burn red, older ones fade to the dim text colour.
        if time() - record.leftAt < 300 then
            row.flag:SetTextColor(C.bad[1], C.bad[2], C.bad[3])
        else
            row.flag:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        end
    else
        row.flag:SetText("")
    end

    if record.grouped then
        row.invite.text:SetText("In group")
        row.invite:SetColor(C.accentDim)
        row:SetAlpha(0.55)
    elseif record.leftAt then
        row.invite.text:SetText("Re-inv")
        row.invite:SetColor(C.accentDim)
        row:SetAlpha(1)
    elseif record.invited then
        row.invite.text:SetText("Invited")
        row.invite:SetColor(C.good)
        row:SetAlpha(0.85)
    else
        row.invite.text:SetText("Invite")
        row.invite:SetColor(C.accentDim)
        row:SetAlpha(1)
    end

    row:Show()
end

-- Header composition readout: "18/25   2T  4H  11D  1?"
function RR.RefreshComposition()
    if not compText or not RR.db then return end

    local counts = RR.GroupRoles()
    local size, cap = RR.GroupSize(), tonumber(RR.db.maxPlayers) or 25
    local sizeColor = size >= cap and C.good or C.text

    local text = RR.Hex(sizeColor) .. size .. "/" .. cap .. "|r   "
        .. RR.Hex(C.warn) .. counts.TANK .. "T|r  "
        .. RR.Hex(C.good) .. counts.HEALER .. "H|r  "
        .. RR.Hex(C.bad) .. counts.DPS .. "D|r"

    -- The question mark only appears when there is something to question.
    if counts.UNKNOWN > 0 then
        text = text .. "  " .. RR.Hex(C.textDim) .. counts.UNKNOWN .. "?|r"
    end

    compText:SetText(text)
end

function RR.RefreshList()
    RR.RefreshComposition()
    if not window or not window:IsShown() then return end

    local list, total = RR.BuildList()
    local offset = FauxScrollFrame_GetOffset(listScroll) or 0

    FauxScrollFrame_Update(listScroll, #list, VISIBLE_ROWS, ROW_H)

    for i = 1, VISIBLE_ROWS do
        local record = list[i + offset]
        if record then
            FillRow(rows[i], record)
        else
            rows[i].applicantName = nil
            rows[i]:Hide()
        end
    end

    local full, size, cap = RR.GroupIsFull()
    local groupText = string.format("group %d/%d", size, cap)
    if full then
        groupText = groupText .. "  FULL"
        if RR.db.fullReplyEnabled then
            groupText = groupText .. ' -- replying "' .. (RR.db.fullReply or "") .. '"'
        end
    end
    footerText:SetText(string.format("%d applicant(s), %d shown  |  %s", total, #list, groupText))
end

-- Channel rows ----------------------------------------------------------------

local function RefreshChannels()
    if not window or not window:IsShown() then return end

    local db = RR.db
    local entries = {}

    for _, channel in ipairs(RR.JoinedChannels()) do
        entries[#entries + 1] = {
            key = channel.name,
            label = channel.slot .. ". " .. channel.name,
            addon = RR.IsAddonChannel(channel.name),
        }
    end

    RR.channelEntries = entries
    local offset = FauxScrollFrame_GetOffset(channelScroll) or 0
    FauxScrollFrame_Update(channelScroll, #entries, VISIBLE_CHANNELS, CHANNEL_ROW_H)

    for i = 1, VISIBLE_CHANNELS do
        local entry = entries[i + offset]
        local row = channelRows[i]
        if entry then
            row.channelName = entry.key
            row.check.label:SetText(entry.label)
            row.check:SetChecked(db.channels[entry.key] and true or false)
            if entry.addon then
                row.check.label:SetTextColor(C.warn[1], C.warn[2], C.warn[3])
            else
                row.check.label:SetTextColor(C.text[1], C.text[2], C.text[3])
            end
            row:Show()
        else
            row.channelName = nil
            row:Hide()
        end
    end
end

RR.RefreshChannels = RefreshChannels

-- Broadcast controls ----------------------------------------------------------

function RR.RefreshBroadcastUI()
    if not window or not window:IsShown() then return end

    if RR.IsBroadcasting() then
        startButton.text:SetText("Stop posting")
        startButton:SetColor(C.bad)
    else
        startButton.text:SetText("Start posting")
        startButton:SetColor(C.good)
    end
end

local function ApplyMessage()
    -- A pasted message can carry newlines; chat takes one line.
    local text = messageBox:GetText() or ""
    text = string.gsub(text, "[\r\n]+", " ")
    RR.db.message = text
    charCount:SetText(string.format("%d/%d", string.len(text), RR.MAX_MESSAGE))
    if string.len(text) >= RR.MAX_MESSAGE then
        charCount:SetTextColor(C.warn[1], C.warn[2], C.warn[3])
    else
        charCount:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
    end
end

local loadingWidgets = false

local function ApplyInterval(value)
    value = math.max(RR.MIN_INTERVAL, math.min(RR.MAX_INTERVAL, math.floor(tonumber(value) or 60)))
    local changed = (RR.db.interval ~= value)
    RR.db.interval = value
    if intervalSlider:GetValue() ~= value then
        intervalSlider:SetValue(value)
    end
    if intervalBox:GetText() ~= tostring(value) then
        intervalBox:SetText(tostring(value))
    end
    -- Changing the interval mid-run restarts the timer so it takes effect now
    -- rather than after the current wait. Only on a real change, and never while
    -- the window is loading saved values into its widgets -- a restart posts
    -- immediately, and merely opening the window must not fire off a message.
    if changed and not loadingWidgets and RR.IsBroadcasting() then
        RR.StartBroadcast()
    end
end

-- Window ----------------------------------------------------------------------

local function SavePosition()
    local left, top = window:GetLeft(), window:GetTop()
    if not left or not top then return end
    -- Store real screen coordinates against UIParent, never the offsets of
    -- whatever frame the window happened to be anchored to.
    window:ClearAllPoints()
    window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    RR.db.window = { left, top }
end

function RR.ResetWindow()
    if not window then return end
    window:ClearAllPoints()
    window:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

local function RestorePosition()
    local saved = RR.db.window
    window:ClearAllPoints()
    if type(saved) == "table" and tonumber(saved[1]) and tonumber(saved[2]) then
        local x, y = saved[1], saved[2]
        local onScreen = x >= 0 and x <= UIParent:GetWidth() - 60
            and y >= 60 and y <= UIParent:GetHeight()
        if onScreen then
            window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
            return
        end
        RR.db.window = nil
    end
    window:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

local function BuildWindow()
    window = CreateFrame("Frame", "RaidRecruiterWindow", UIParent)
    window:SetWidth(WINDOW_W)
    window:SetHeight(WINDOW_H)
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnMouseDown", ClearFocus)
    window:SetScript("OnHide", ClearFocus)
    window:SetScript("OnDragStart", function(self) self:StartMoving() end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    Backdrop(window, C.panel[1], C.panel[2], C.panel[3], 0.96, 1)
    window:Hide()

    tinsert(UISpecialFrames, "RaidRecruiterWindow")  -- Escape closes it

    -- Header
    local header = CreateFrame("Frame", nil, window)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H)
    Backdrop(header, C.accentDim[1] * 0.6, C.accentDim[2] * 0.6, C.accentDim[3] * 0.7, 1)

    local title = Label(header, "Raid Recruiter", 15, C.text)
    title:SetPoint("LEFT", 12, 0)

    local subtitle = Label(header, "post, collect, invite", 10, C.textDim)
    subtitle:SetPoint("LEFT", title, "RIGHT", 8, -1)

    local close = Button(header, "X", 22, 20)
    close:SetPoint("RIGHT", -8, 0)
    close:SetScript("OnClick", function() window:Hide() end)

    -- Composition lives in the title bar, not the footer: it is the one number
    -- you check before every invite, and up here it stays visible on both tabs.
    compText = Label(header, "", 13, C.text)
    compText:SetPoint("RIGHT", close, "LEFT", -14, 0)
    compText:SetJustifyH("RIGHT")

    compFrame = CreateFrame("Frame", nil, header)
    compFrame:SetPoint("TOPLEFT", compText, "TOPLEFT", 0, 0)
    compFrame:SetPoint("BOTTOMRIGHT", compText, "BOTTOMRIGHT", 0, 0)
    compFrame:EnableMouse(true)
    compFrame:SetScript("OnEnter", function(self)
        local counts = RR.GroupRoles()
        local size, cap = RR.GroupSize(), tonumber(RR.db.maxPlayers) or 25
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Group composition", 1, 1, 1)
        GameTooltip:AddDoubleLine("Tanks", counts.TANK, 0.8, 0.8, 0.8, 0.85, 0.6, 0.3)
        GameTooltip:AddDoubleLine("Healers", counts.HEALER, 0.8, 0.8, 0.8, 0.35, 0.8, 0.4)
        GameTooltip:AddDoubleLine("DPS", counts.DPS, 0.8, 0.8, 0.8, 0.85, 0.3, 0.3)
        GameTooltip:AddDoubleLine("Unknown", counts.UNKNOWN, 0.8, 0.8, 0.8, 0.62, 0.63, 0.68)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(string.format("%d in group, cap %d", size, cap), 0.6, 0.6, 0.6)
        GameTooltip:AddLine("Roles come from what each player whispered when applying,", 0.5, 0.5, 0.5, true)
        GameTooltip:AddLine("then main tank flags. Unknown means nobody ever said.", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    compFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Tabs. Pages fill the same area below the header; only one is ever shown.
    pages = {}
    tabButtons = {}

    local function SelectPage(name)
        for pageName, frame in pairs(pages) do
            if pageName == name then frame:Show() else frame:Hide() end
        end
        for _, tab in ipairs(tabButtons) do
            tab:SetColor(tab.page == name and C.accent or C.accentDim)
        end
        RR.db.page = name
        if name == "loot" and RR.RefreshLootUI then RR.RefreshLootUI() end
        if name == "recruit" then RR.RefreshList() end
    end
    RR.SelectPage = SelectPage

    local tabDefs = { { "recruit", "Recruiting" }, { "loot", "Loot rolls" } }
    for i, def in ipairs(tabDefs) do
        local tab = Button(window, def[2], 90, 20)
        if i == 1 then
            tab:SetPoint("TOPLEFT", 10, -(HEADER_H + 6))
        else
            tab:SetPoint("LEFT", tabButtons[i - 1], "RIGHT", 4, 0)
        end
        tab.page = def[1]
        tab:SetScript("OnClick", function(self) SelectPage(self.page) end)
        tabButtons[i] = tab
    end

    local PAGE_TOP = HEADER_H + 32

    recruitPage = CreateFrame("Frame", nil, window)
    recruitPage:SetPoint("TOPLEFT", 0, -PAGE_TOP)
    recruitPage:SetPoint("BOTTOMRIGHT", 0, 0)
    pages.recruit = recruitPage

    RR.NewPage = function(name)
        local page = CreateFrame("Frame", nil, window)
        page:SetPoint("TOPLEFT", 0, -PAGE_TOP)
        page:SetPoint("BOTTOMRIGHT", 0, 0)
        page:Hide()
        pages[name] = page
        return page
    end

    -- ---------------------------------------------------------------- left
    local left = CreateFrame("Frame", nil, recruitPage)
    left:SetPoint("TOPLEFT", 10, -10)
    left:SetWidth(LEFT_W)
    left:SetPoint("BOTTOMLEFT", recruitPage, "BOTTOMLEFT", 10, 12)
    Backdrop(left, 0.03, 0.035, 0.045, 0.9, 1)

    local messageLabel = Label(left, "YOUR MESSAGE", 10, C.accent)
    messageLabel:SetPoint("TOPLEFT", 10, -10)

    local messageHolder = CreateFrame("Frame", nil, left)
    messageHolder:SetPoint("TOPLEFT", 10, -26)
    messageHolder:SetWidth(LEFT_W - 20)
    messageHolder:SetHeight(56)
    Backdrop(messageHolder, 0.02, 0.02, 0.03, 1, 1)

    messageBox = CreateFrame("EditBox", nil, messageHolder)
    messageBox:SetPoint("TOPLEFT", 6, -5)
    messageBox:SetPoint("BOTTOMRIGHT", -6, 5)
    messageBox:SetMultiLine(true)
    messageBox:SetAutoFocus(false)
    messageBox:SetMaxLetters(RR.MAX_MESSAGE)
    messageBox:SetFontObject("GameFontHighlightSmall")
    messageBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    messageBox:SetScript("OnTextChanged", ApplyMessage)
    RegisterEditBox(messageBox)

    -- The holder is wider than the text itself, so clicking the padding around a
    -- short message still puts the cursor in the box.
    messageHolder:EnableMouse(true)
    messageHolder:SetScript("OnMouseDown", function() messageBox:SetFocus() end)

    charCount = Label(left, "0/255", 9, C.textDim)
    charCount:SetPoint("TOPRIGHT", messageHolder, "BOTTOMRIGHT", 0, -3)

    local channelLabel = Label(left, "POST TO", 10, C.accent)
    channelLabel:SetPoint("TOPLEFT", messageHolder, "BOTTOMLEFT", 0, -16)

    local rescan = Button(left, "Rescan", 52, 16)
    rescan:SetPoint("TOPRIGHT", messageHolder, "BOTTOMRIGHT", 0, -14)
    rescan:SetScript("OnClick", RefreshChannels)

    local channelHolder = CreateFrame("Frame", nil, left)
    channelHolder:SetPoint("TOPLEFT", channelLabel, "BOTTOMLEFT", 0, -6)
    channelHolder:SetWidth(LEFT_W - 20)
    channelHolder:SetHeight(VISIBLE_CHANNELS * CHANNEL_ROW_H + 6)
    Backdrop(channelHolder, 0.02, 0.02, 0.03, 1, 1)

    channelScroll = CreateFrame("ScrollFrame", "RaidRecruiterChannelScroll", channelHolder, "FauxScrollFrameTemplate")
    channelScroll:SetPoint("TOPLEFT", 2, -3)
    channelScroll:SetPoint("BOTTOMRIGHT", -24, 3)
    channelScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, CHANNEL_ROW_H, RefreshChannels)
    end)

    channelRows = {}
    for i = 1, VISIBLE_CHANNELS do
        local row = CreateFrame("Frame", nil, channelHolder)
        row:SetWidth(LEFT_W - 46)
        row:SetHeight(CHANNEL_ROW_H)
        if i == 1 then
            row:SetPoint("TOPLEFT", 4, -3)
        else
            row:SetPoint("TOPLEFT", channelRows[i - 1], "BOTTOMLEFT", 0, 0)
        end

        local check = CheckBox(row, "")
        check:SetPoint("LEFT", 0, 0)
        check:SetScript("OnClick", function(self)
            local name = self:GetParent().channelName
            if not name then return end
            RR.db.channels[name] = self:GetChecked() and true or nil
        end)
        row.check = check
        channelRows[i] = row
    end

    local staticLabel = Label(left, "ALSO", 10, C.accent)
    staticLabel:SetPoint("TOPLEFT", channelHolder, "BOTTOMLEFT", 0, -10)

    local guildCheck = CheckBox(left, "Guild")
    guildCheck:SetPoint("TOPLEFT", staticLabel, "BOTTOMLEFT", 0, -4)
    guildCheck:SetScript("OnClick", function(self) RR.db.guild = self:GetChecked() and true or false end)

    local sayCheck = CheckBox(left, "Say")
    sayCheck:SetPoint("LEFT", guildCheck, "RIGHT", 56, 0)
    sayCheck:SetScript("OnClick", function(self) RR.db.say = self:GetChecked() and true or false end)

    local yellCheck = CheckBox(left, "Yell")
    yellCheck:SetPoint("LEFT", sayCheck, "RIGHT", 46, 0)
    yellCheck:SetScript("OnClick", function(self) RR.db.yell = self:GetChecked() and true or false end)

    local intervalLabel = Label(left, "EVERY", 10, C.accent)
    intervalLabel:SetPoint("TOPLEFT", guildCheck, "BOTTOMLEFT", 0, -14)

    intervalBox = EditBox(left, 44, 18, true)
    intervalBox:SetPoint("LEFT", intervalLabel, "RIGHT", 8, 0)
    intervalBox:SetScript("OnEnterPressed", function(self)
        ApplyInterval(self:GetText())
        self:ClearFocus()
    end)
    intervalBox:SetScript("OnEditFocusLost", function(self) ApplyInterval(self:GetText()) end)

    local secondsLabel = Label(left, "seconds between rounds", 10, C.textDim)
    secondsLabel:SetPoint("LEFT", intervalBox, "RIGHT", 6, 0)

    intervalSlider = CreateFrame("Slider", "RaidRecruiterIntervalSlider", left, "OptionsSliderTemplate")
    intervalSlider:SetPoint("TOPLEFT", intervalLabel, "BOTTOMLEFT", 4, -14)
    intervalSlider:SetWidth(LEFT_W - 40)
    intervalSlider:SetMinMaxValues(RR.MIN_INTERVAL, RR.MAX_INTERVAL)
    intervalSlider:SetValueStep(5)
    _G["RaidRecruiterIntervalSliderLow"]:SetText(RR.MIN_INTERVAL .. "s")
    _G["RaidRecruiterIntervalSliderHigh"]:SetText(RR.MAX_INTERVAL .. "s")
    _G["RaidRecruiterIntervalSliderText"]:SetText("")
    intervalSlider:SetScript("OnValueChanged", function(self, value)
        ApplyInterval(value)
    end)

    local soundCheck = CheckBox(left, "Sound on a new whisper")
    soundCheck:SetPoint("TOPLEFT", intervalSlider, "BOTTOMLEFT", -4, -10)
    soundCheck:SetScript("OnClick", function(self)
        RR.db.soundOnWhisper = self:GetChecked() and true or false
    end)

    local capCheck = CheckBox(left, "Reply when full, cap")
    capCheck:SetPoint("TOPLEFT", soundCheck, "BOTTOMLEFT", 0, -4)
    capCheck:SetScript("OnClick", function(self)
        RR.db.fullReplyEnabled = self:GetChecked() and true or false
        RR.RefreshList()
    end)

    capBox = EditBox(left, 36, 18, true)
    capBox:SetPoint("LEFT", capCheck.label, "RIGHT", 6, 0)
    capBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    capBox:SetScript("OnEditFocusLost", function(self)
        local value = tonumber(self:GetText()) or 25
        if value < 2 then value = 2 end
        if value > 40 then value = 40 end
        RR.db.maxPlayers = value
        self:SetText(tostring(value))
        RR.RefreshList()
    end)

    local replyLabel = Label(left, "Reply", 10, C.textDim)
    replyLabel:SetPoint("TOPLEFT", capCheck, "BOTTOMLEFT", 4, -8)

    replyBox = EditBox(left, LEFT_W - 70, 18)
    replyBox:SetPoint("LEFT", replyLabel, "RIGHT", 6, 0)
    replyBox:SetMaxLetters(200)
    replyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    replyBox:SetScript("OnTextChanged", function(self)
        RR.db.fullReply = self:GetText() or ""
    end)

    startButton = Button(left, "Start posting", LEFT_W - 20, 30)
    startButton:SetPoint("BOTTOMLEFT", 10, 30)
    startButton:SetColor(C.good)
    startButton:SetScript("OnClick", function() RR.ToggleBroadcast() end)

    statusText = Label(left, "idle", 10, C.textDim)
    statusText:SetPoint("BOTTOM", 0, 12)

    -- --------------------------------------------------------------- right
    local right = CreateFrame("Frame", nil, recruitPage)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 10, 0)
    right:SetPoint("BOTTOMRIGHT", recruitPage, "BOTTOMRIGHT", -10, 12)
    Backdrop(right, 0.03, 0.035, 0.045, 0.9, 1)

    local filterLabel = Label(right, "APPLICANTS", 10, C.accent)
    filterLabel:SetPoint("TOPLEFT", 10, -10)

    searchBox = EditBox(right, 110, 18)
    searchBox:SetPoint("TOPLEFT", filterLabel, "BOTTOMLEFT", 0, -6)
    searchBox:SetScript("OnTextChanged", function(self)
        RR.searchText = self:GetText()
        RR.RefreshList()
    end)
    local searchHint = Label(right, "search", 9, C.textDim)
    searchHint:SetPoint("BOTTOMLEFT", searchBox, "TOPLEFT", 2, 1)

    local ilvlHint = Label(right, "min ilvl", 9, C.textDim)
    ilvlHint:SetPoint("BOTTOMLEFT", searchBox, "TOPRIGHT", 10, 1)

    minIlvlBox = EditBox(right, 44, 18)
    minIlvlBox:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
    minIlvlBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    minIlvlBox:SetScript("OnTextChanged", function(self)
        RR.db.minIlvl = tonumber(self:GetText()) or 0
        RR.RefreshList()
    end)

    roleButtons = {}
    local roleDefs = { { "ANY", "All" }, { "TANK", "Tank" }, { "HEALER", "Heal" }, { "DPS", "DPS" } }
    for i, def in ipairs(roleDefs) do
        local button = Button(right, def[2], 40, 18)
        if i == 1 then
            button:SetPoint("LEFT", minIlvlBox, "RIGHT", 10, 0)
        else
            button:SetPoint("LEFT", roleButtons[i - 1], "RIGHT", 3, 0)
        end
        button.role = def[1]
        button:SetScript("OnClick", function(self)
            RR.db.roleFilter = self.role
            RR.RefreshFilters()
            RR.RefreshList()
        end)
        roleButtons[i] = button
    end

    hideGroupedCheck = CheckBox(right, "Hide grouped")
    hideGroupedCheck:SetPoint("LEFT", roleButtons[4], "RIGHT", 10, 0)
    hideGroupedCheck:SetScript("OnClick", function(self)
        RR.db.hideGrouped = self:GetChecked() and true or false
        RR.RefreshList()
    end)

    -- Sortable column headers
    local headerBar = CreateFrame("Frame", nil, right)
    headerBar:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -8)
    headerBar:SetPoint("RIGHT", right, "RIGHT", -10, 0)
    headerBar:SetHeight(18)
    Backdrop(headerBar, 0.02, 0.02, 0.03, 1)

    headerButtons = {}
    local headerDefs = {
        { "name", "Name", 0, 120 },
        { "level", "Lvl", 124, 30 },
        { "ilvl", "iLvl", 156, 52 },
        { "role", "Role", 210, 74 },
        { "time", "When", 286, 40 },
    }
    for _, def in ipairs(headerDefs) do
        local button = CreateFrame("Button", nil, headerBar)
        button:SetPoint("LEFT", def[3] + 6, 0)
        button:SetWidth(def[4])
        button:SetHeight(18)
        local font = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        font:SetPoint("LEFT")
        font:SetText(def[2])
        font:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        button.font = font
        button.key = def[1]
        -- "Role" is a label, not a sort: sorting text roles alphabetically tells
        -- you nothing a filter does not already do better.
        if def[1] ~= "role" then
            button:SetScript("OnClick", function(self)
                local db = RR.db
                if db.sortKey == self.key then
                    db.sortDesc = not db.sortDesc
                else
                    db.sortKey = self.key
                    db.sortDesc = (self.key ~= "name")
                end
                RR.RefreshFilters()
                RR.RefreshList()
            end)
        end
        headerButtons[#headerButtons + 1] = button
    end

    -- Applicant list
    local listHolder = CreateFrame("Frame", nil, right)
    listHolder:SetPoint("TOPLEFT", headerBar, "BOTTOMLEFT", 0, -2)
    listHolder:SetPoint("RIGHT", right, "RIGHT", -10, 0)
    listHolder:SetHeight(VISIBLE_ROWS * ROW_H + 4)
    Backdrop(listHolder, 0.02, 0.02, 0.03, 1, 1)

    listScroll = CreateFrame("ScrollFrame", "RaidRecruiterListScroll", listHolder, "FauxScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 2, -2)
    listScroll:SetPoint("BOTTOMRIGHT", -26, 2)
    listScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, RR.RefreshList)
    end)

    rows = {}
    for i = 1, VISIBLE_ROWS do
        local row = BuildRow(listHolder, i)
        -- Anchored on both sides so the row stops short of the scrollbar instead
        -- of running underneath it at a hardcoded width.
        if i == 1 then
            row:SetPoint("TOPLEFT", 3, -3)
        else
            row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, -2)
        end
        row:SetPoint("RIGHT", listHolder, "RIGHT", -26, 0)
        row:Hide()
        rows[i] = row
    end

    footerText = Label(right, "", 10, C.textDim)
    footerText:SetPoint("BOTTOMLEFT", 10, 12)

    local clearButton = Button(right, "Clear list", 70, 20)
    clearButton:SetPoint("BOTTOMRIGHT", -10, 8)
    clearButton:SetScript("OnClick", function() RR.ClearApplicants() end)

    -- Countdown. One throttled OnUpdate for the whole window rather than a timer
    -- per widget.
    window.elapsed = 0
    window:SetScript("OnUpdate", function(self, delta)
        self.elapsed = self.elapsed + delta
        if self.elapsed < 0.25 then return end
        self.elapsed = 0

        -- Row ages ("left 4m ago") are only as honest as the last refresh, so
        -- the list is rebuilt on a slow tick alongside the countdown.
        self.listElapsed = (self.listElapsed or 0) + 0.25
        if self.listElapsed >= 15 then
            self.listElapsed = 0
            RR.RefreshList()
        end

        local remaining = RR.SecondsToNextPost()
        if remaining then
            statusText:SetText(string.format("next post in %ds", math.ceil(remaining)))
            statusText:SetTextColor(C.good[1], C.good[2], C.good[3])
        else
            statusText:SetText("idle -- nothing is being posted")
            statusText:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        end
    end)

    window.guildCheck = guildCheck
    window.sayCheck = sayCheck
    window.yellCheck = yellCheck
    window.soundCheck = soundCheck
    window.capCheck = capCheck
end

-- Push saved settings into the widgets.
function RR.RefreshFilters()
    if not window then return end
    local db = RR.db

    for _, button in ipairs(roleButtons) do
        if button.role == (db.roleFilter or "ANY") then
            button:SetColor(C.accent)
        else
            button:SetColor(C.accentDim)
        end
    end

    for _, button in ipairs(headerButtons) do
        if button.key == db.sortKey then
            button.font:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
            button.font:SetText(button.font:GetText():gsub(" [v^]$", "") .. (db.sortDesc and " v" or " ^"))
        else
            button.font:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
            button.font:SetText((button.font:GetText():gsub(" [v^]$", "")))
        end
    end
end

local function LoadWidgets()
    local db = RR.db
    loadingWidgets = true

    messageBox:SetText(db.message or "")
    ApplyMessage()

    intervalSlider:SetValue(db.interval or 60)
    intervalBox:SetText(tostring(db.interval or 60))
    minIlvlBox:SetText(db.minIlvl and db.minIlvl > 0 and tostring(db.minIlvl) or "")

    window.guildCheck:SetChecked(db.guild and true or false)
    window.sayCheck:SetChecked(db.say and true or false)
    window.yellCheck:SetChecked(db.yell and true or false)
    hideGroupedCheck:SetChecked(db.hideGrouped and true or false)
    window.soundCheck:SetChecked(db.soundOnWhisper and true or false)
    window.capCheck:SetChecked(db.fullReplyEnabled and true or false)
    capBox:SetText(tostring(db.maxPlayers or 25))
    replyBox:SetText(db.fullReply or "")

    if RR.LoadLootWidgets then RR.LoadLootWidgets() end

    RR.RefreshFilters()
    RefreshChannels()
    RR.RefreshBroadcastUI()
    RR.RefreshList()
    if RR.RefreshLootUI then RR.RefreshLootUI() end

    loadingWidgets = false
end

function RR.ToggleWindow()
    if not window then return end
    if window:IsShown() then
        window:Hide()
        return
    end
    RestorePosition()
    window:Show()
    LoadWidgets()
end

-- New applicants while the window is closed should be noticeable but not loud:
-- the minimap icon tints instead of anything popping up mid-pull.
local minimapIcon
function RR.FlashNew(isNew)
    if not isNew or not minimapIcon then return end
    -- Older LibDBIcon builds have no GetMinimapButton; the button is then just
    -- an entry in the library's own table.
    local button
    if type(minimapIcon.GetMinimapButton) == "function" then
        local ok, found = pcall(minimapIcon.GetMinimapButton, minimapIcon, ADDON_NAME)
        if ok then button = found end
    end
    if not button and type(minimapIcon.objects) == "table" then
        button = minimapIcon.objects[ADDON_NAME]
    end
    if button and button.icon then
        button.icon:SetVertexColor(C.good[1], C.good[2], C.good[3])
        C_Timer.After(3, function()
            if button and button.icon then
                button.icon:SetVertexColor(1, 1, 1)
            end
        end)
    end
end

local function SetupMinimapButton()
    local ldb = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
    local icon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
    if not ldb or not icon then return end

    local broker = ldb:NewDataObject(ADDON_NAME, {
        type = "launcher",
        icon = "Interface\\Icons\\INV_Misc_GroupLooking",
        -- Any click just opens the window. Posting is deliberately not on this
        -- button: it is easy to hit by accident, and a mis-click would start
        -- broadcasting to the channels.
        OnClick = function()
            RR.ToggleWindow()
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Raid Recruiter")
            tooltip:AddLine("Click: open", 1, 1, 1)
            local count = RR.CountApplicants()
            if count > 0 then
                tooltip:AddLine(count .. " applicant(s)", 0.4, 0.8, 0.4)
            end
        end,
    })

    RR.db.minimap = RR.db.minimap or { hide = false }
    icon:Register(ADDON_NAME, broker, RR.db.minimap)
    minimapIcon = icon
end

function RR.UI_Init()
    BuildWindow()
    if RR.LootUI_Init then RR.LootUI_Init() end
    SetupMinimapButton()
    RR.SelectPage(RR.db.page or "recruit")
end
