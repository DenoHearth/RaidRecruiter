-- The raid bar: the few things pressed at every pull, on screen while you lead or assist.
--
--   Ready      ready check
--   Pull 10    countdown (Pull.lua); the button is STOP while it runs
--   eight marks for the target, X clears the mark
--   second row: the eight marks on the ground (click, then click the floor; again to remove)
--
-- The ground marks are the reason for the care below: the game lets only a protected button
-- place them. With protected buttons inside it the bar is protected too, so it is shown, hidden
-- and moved only outside a fight; a change that comes during one waits for its end.
--
-- After a ready check that not everyone answered, a small list comes up: who, and a Whisper
-- button each.

local ADDON_NAME, RR = ...

local C = RR.COLOR
local ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"
-- the game's order of the ground marks: square, triangle, diamond, cross, star, circle, moon, skull
local GROUND = { { 0.25, 0.55, 1 }, { 0.25, 0.85, 0.35 }, { 0.75, 0.35, 0.95 }, { 0.95, 0.25, 0.25 },
                 { 1, 0.9, 0.2 }, { 1, 0.55, 0.15 }, { 0.8, 0.85, 0.9 }, { 0.95, 0.95, 0.95 } }

local bar, pullButton, countdown, result
local pending = false

local function Want()
    return RR.db.barShown ~= false and IsInGroup() and RR.CanLead()
end

function RR.RaidBar_Update()
    if not bar then return end
    if InCombatLockdown() then pending = true return end
    pending = false
    bar:SetShown(Want() and true or false)
end

local function RefreshPull()
    if not bar then return end
    local left = RR.PullSecondsLeft()
    if left then
        pullButton.text:SetText("STOP")
        pullButton:SetColor(C.bad)
        countdown.text:SetText("Pull in " .. math.ceil(left))
        countdown:Show()
    else
        pullButton.text:SetText("Pull " .. (tonumber(RR.db.pullSeconds) or 10))
        pullButton:SetColor(nil)
        countdown:Hide()
    end
end

-- ------------------------------------------------------------------ the ready check result

local function BuildResult()
    result = CreateFrame("Frame", "RaidRecruiterReady", UIParent)
    result:SetSize(330, 60)
    result:SetFrameStrata("HIGH")
    RR.UI_Section(result)
    result.title = RR.UI_Label(result, "Ready check", 12, C.text)
    result.title:SetPoint("TOPLEFT", 10, -8)
    result.count = RR.UI_Label(result, "", 12, C.warn)
    result.count:SetPoint("TOPRIGHT", -70, -8)
    local close = RR.UI_Button(result, "Close", 54, 20)
    close:SetPoint("TOPRIGHT", -6, -5)
    close:SetScript("OnClick", function() result:Hide() end)
    result.rows = {}
    for i = 1, 6 do
        local row = CreateFrame("Frame", nil, result)
        row:SetSize(318, 24)
        row:SetPoint("TOPLEFT", 6, -(30 + (i - 1) * 26))
        RR.UI_Row(row, i)
        row.name = RR.UI_Label(row, "", 11, C.text)
        row.name:SetPoint("LEFT", 8, 0)
        row.state = RR.UI_Label(row, "", 11, C.bad)
        row.state:SetPoint("LEFT", 130, 0)
        row.whisper = RR.UI_Button(row, "Whisper", 76, 20)
        row.whisper:SetPoint("RIGHT", -2, 0)
        result.rows[i] = row
    end
    result:Hide()
end

function RR.RaidBar_ShowReadyResult()
    if not RR.CanLead() then return end
    local total, yes, no = RR.ReadyCheckResult()
    if not result then BuildResult() end
    if #no == 0 then result:Hide() return end
    result.count:SetText(yes .. " of " .. total)
    for i, row in ipairs(result.rows) do
        local who = no[i]
        if who then
            row.name:SetText(who.name)
            local away = who.state == "away"
            row.state:SetText(away and "no answer" or "not ready")
            local colour = away and C.warn or C.bad
            row.state:SetTextColor(colour[1], colour[2], colour[3])
            row.whisper:SetScript("OnClick", function() RR.WhisperNotReady(who.name) end)
            row:Show()
        else
            row:Hide()
        end
    end
    result:SetHeight(34 + math.min(#no, 6) * 26)
    result:ClearAllPoints()
    if bar and bar:IsShown() then
        result:SetPoint("TOP", bar, "BOTTOM", 0, -6)
    else
        result:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    end
    result:Show()
    C_Timer.After(30, function() if result:IsShown() then result:Hide() end end)
end

-- ------------------------------------------------------------------ the bar

function RR.RaidBar_Init()
    if bar or not RR.UI_Button then return end
    local B = RR.UI_Button

    bar = CreateFrame("Frame", "RaidRecruiterBar", UIParent)
    bar:SetSize(452, 76)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    RR.UI_Section(bar)
    local at = RR.db.barPoint
    if type(at) == "table" then
        bar:SetPoint(at[1], UIParent, at[1], at[2], at[3])
    else
        bar:SetPoint("TOP", UIParent, "TOP", 0, -150)
    end
    bar:SetMovable(true)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
    bar:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        RR.db.barPoint = { point, x, y }
    end)

    local readyButton = B(bar, "Ready", 64, 30)
    readyButton:SetPoint("TOPLEFT", 6, -6)
    readyButton:SetColor(C.accent)
    readyButton:SetScript("OnClick", function() RR.StartReadyCheck() end)

    pullButton = B(bar, "Pull 10", 64, 30)
    pullButton:SetPoint("LEFT", readyButton, "RIGHT", 4, 0)
    pullButton:SetScript("OnClick", function()
        if RR.PullActive() then RR.CancelPull() else RR.StartPull(tonumber(RR.db.pullSeconds) or 10) end
    end)

    local first
    for i = 1, 8 do
        local mark = B(bar, "", 30, 30)
        mark:SetPoint("TOPLEFT", 144 + (i - 1) * 32, -6)
        mark:SetScript("OnClick", function() SetRaidTarget("target", i) end)
        local icon = mark:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 3, -3)
        icon:SetPoint("BOTTOMRIGHT", -3, 3)
        icon:SetTexture(ICON .. i)
        first = first or mark
    end
    local clear = B(bar, "X", 38, 30)
    clear:SetPoint("TOPLEFT", 404, -6)
    clear:SetColor(C.bad)
    clear:SetScript("OnClick", function() SetRaidTarget("target", 0) end)

    -- the countdown lies over the marks while it runs
    countdown = CreateFrame("Frame", nil, bar)
    countdown:SetPoint("TOPLEFT", first, "TOPLEFT", 0, 0)
    countdown:SetSize(298, 30)
    countdown:SetFrameLevel(bar:GetFrameLevel() + 10)
    countdown:EnableMouse(true)
    RR.UI_Inset(countdown)
    countdown.text = RR.UI_Label(countdown, "", 13, C.text)
    countdown.text:SetPoint("CENTER")
    countdown:Hide()

    local groundLabel = RR.UI_Label(bar, "On the ground", 10, C.textDim)
    groundLabel:SetPoint("TOPLEFT", 8, -50)
    for i = 1, 8 do
        local button = CreateFrame("Button", "RaidRecruiterGround" .. i, bar, "SecureActionButtonTemplate")
        button:SetSize(30, 22)
        button:SetPoint("TOPLEFT", 144 + (i - 1) * 32, -44)
        button:RegisterForClicks("AnyDown", "AnyUp")
        button:SetAttribute("type", "worldmarker")
        button:SetAttribute("marker", i)
        button:SetAttribute("action", "toggle")
        local colour = GROUND[i]
        local fill = button:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        fill:SetColorTexture(colour[1] * 0.4, colour[2] * 0.4, colour[3] * 0.4, 1)
        local edge = button:CreateTexture(nil, "BORDER")
        edge:SetPoint("BOTTOMLEFT")
        edge:SetPoint("BOTTOMRIGHT")
        edge:SetHeight(2)
        edge:SetColorTexture(colour[1], colour[2], colour[3], 1)
    end

    -- Pull.lua calls this on every tick; the window has its own readout, the bar adds its own
    local windowRefresh = RR.RefreshPullUI
    RR.RefreshPullUI = function()
        if windowRefresh then windowRefresh() end
        RefreshPull()
    end

    local watcher = CreateFrame("Frame")
    for _, event in ipairs({ "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD" }) do
        watcher:RegisterEvent(event)
    end
    watcher:SetScript("OnEvent", function(_, event)
        if event ~= "PLAYER_REGEN_ENABLED" or pending then RR.RaidBar_Update() end
    end)

    bar:Hide()
    RefreshPull()
    RR.RaidBar_Update()
end
