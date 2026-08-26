-- The Roles page.
--
-- Everyone in the group, what they are down as, and four buttons to change it.
-- This is the override: a role set here is your decision, not a parse, and it is
-- how a switch mid-raid gets recorded ("I'll heal this one instead") without
-- anybody having to type anything anywhere.
--
-- It is also the only place a role can be taken back off somebody -- the "?"
-- button -- which matters because an unknown is what the class check and the
-- "Ask the missing" button work from.

local ADDON_NAME, RR = ...

local C = RR.COLOR

local ROLE_ROWS = 12
local ROLE_ROW_H = 24

local page, rows, scroll, summaryText, hint
local offset = 0

-- The four things a row can be set to. "?" is not a role, it is the absence of
-- one, and it has to be reachable: a wrong guess that cannot be cleared is worse
-- than no answer.
local CHOICES = {
    { key = "Tank",   short = "T", color = C.warn },
    { key = "Healer", short = "H", color = C.good },
    { key = "DPS",    short = "D", color = C.bad },
    { key = nil,      short = "?", color = C.textDim },
}

local function RoleColor(role)
    if not role then return C.textDim end
    if string.find(role, "Tank") then return C.warn end
    if string.find(role, "Healer") then return C.good end
    if string.find(role, "DPS") then return C.bad end
    return C.text
end

-- Everyone in the group, player first, then the rest in name order. The player
-- is first rather than sorted in because it is the row you set on yourself and
-- hunting for your own name in a raid of 25 is silly.
local function GroupList()
    local me = UnitName("player")
    local names = {}
    for name in pairs(RR.GroupUnits and RR.GroupUnits() or {}) do
        names[#names + 1] = name
    end
    table.sort(names)

    local list = {}
    if me then list[1] = me end
    for _, name in ipairs(names) do list[#list + 1] = name end
    return list
end

-- What someone is down as, and where it came from -- the same two sources the
-- readout counts, in the same order.
local function RoleOf(name)
    local said = RR.knownRoles and RR.knownRoles[name]
    if said then return said, "said so" end

    local record = RR.GetApplicant and RR.GetApplicant(name)
    if record and record.role then return record.role, "whispered it" end

    return nil, nil
end

-- Setting a role by hand. It goes into the same table an answer goes into, so
-- nothing downstream has to know the difference -- the readout, the unknown
-- list and the "Ask the missing" button all just see a role.
local function SetRole(name, role)
    if not name then return end

    RR.RememberRole(name, role)

    local record = RR.GetApplicant and RR.GetApplicant(name)
    if record then record.role = role end

    if role then
        RR.Print("%s set to %s.", name, role)
    else
        RR.Print("%s cleared -- back to unknown.", name)
    end

    RR.RefreshRolesUI()
    if RR.RefreshComposition then RR.RefreshComposition() end
    if RR.RefreshList then RR.RefreshList() end
end

RR.SetRoleByHand = SetRole

-- Rows ------------------------------------------------------------------------

local function BuildRow(parent, index)
    local Button = RR.UI_Button
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROLE_ROW_H - 2)
    RR.UI_Backdrop(row, C.row[1], C.row[2], C.row[3], index % 2 == 0 and 0.5 or 0.28)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(130)
    row.name:SetJustifyH("LEFT")

    row.role = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.role:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
    row.role:SetWidth(80)
    row.role:SetJustifyH("LEFT")

    row.source = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.source:SetPoint("LEFT", row.role, "RIGHT", 4, 0)
    row.source:SetWidth(90)
    row.source:SetJustifyH("LEFT")

    row.buttons = {}
    for i = #CHOICES, 1, -1 do
        local choice = CHOICES[i]
        local button = Button(row, choice.short, 22, 18)
        if i == #CHOICES then
            button:SetPoint("RIGHT", -8, 0)
        else
            button:SetPoint("RIGHT", row.buttons[i + 1], "LEFT", -3, 0)
        end
        button.roleKey = choice.key
        button:SetScript("OnClick", function(self)
            SetRole(self:GetParent().playerName, self.roleKey)
        end)
        row.buttons[i] = button
    end

    return row
end

function RR.RefreshRolesUI()
    if not page or not page:IsShown() then return end

    local list = GroupList()
    local total = #list

    FauxScrollFrame_Update(scroll, total, ROLE_ROWS, ROLE_ROW_H)
    offset = FauxScrollFrame_GetOffset(scroll) or 0

    for i = 1, ROLE_ROWS do
        local row = rows[i]
        local name = list[i + offset]
        if name then
            row.playerName = name
            row.name:SetText(name)

            local applicant = RR.GetApplicant and RR.GetApplicant(name)
            row.name:SetTextColor(RR.ClassColor(applicant and applicant.class))

            local role, from = RoleOf(name)
            row.role:SetText(role or "not said")
            local color = RoleColor(role)
            row.role:SetTextColor(color[1], color[2], color[3])
            row.source:SetText(from or "")

            -- The button matching what they are is lit, so the row reads as a
            -- setting rather than four identical buttons.
            for _, button in ipairs(row.buttons) do
                local mine = button.roleKey
                local on
                if mine then
                    on = role and string.find(role, mine) and true or false
                else
                    on = role == nil
                end
                button:SetColor(on and C.accent or C.accentDim)
            end

            row:Show()
        else
            row.playerName = nil
            row:Hide()
        end
    end

    local counts = RR.GroupRoles()
    summaryText:SetText(string.format("%d in group   %s%dT|r  %s%dH|r  %s%dD|r  %s%d?|r",
        RR.GroupSize(),
        RR.Hex(C.warn), counts.TANK,
        RR.Hex(C.good), counts.HEALER,
        RR.Hex(C.bad), counts.DPS,
        RR.Hex(C.textDim), counts.UNKNOWN))
end

-- Build -----------------------------------------------------------------------

function RR.RolesUI_Init()
    if not RR.NewPage then return end

    local Label = RR.UI_Label

    page = RR.NewPage("roles")

    local panel = CreateFrame("Frame", nil, page)
    panel:SetPoint("TOPLEFT", 10, -10)
    panel:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -10, 12)
    RR.UI_Backdrop(panel, 0.03, 0.035, 0.045, 0.9, 1)

    local title = Label(panel, "WHO IS WHAT", 10, C.accent)
    title:SetPoint("TOPLEFT", 10, -10)

    summaryText = Label(panel, "", 11, C.text)
    summaryText:SetPoint("TOPRIGHT", -12, -9)

    hint = Label(panel, "Set a role here when somebody switches. What you set stays put -- "
        .. "a whisper from someone already in the group never changes it.", 10, C.textDim)
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetWidth(700)
    hint:SetJustifyH("LEFT")

    local holder = CreateFrame("Frame", nil, panel)
    holder:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
    holder:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
    holder:SetHeight(ROLE_ROWS * ROLE_ROW_H + 6)
    RR.UI_Backdrop(holder, 0.02, 0.02, 0.03, 1, 1)

    scroll = CreateFrame("ScrollFrame", "RaidRecruiterRolesScroll", holder, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 2, -3)
    scroll:SetPoint("BOTTOMRIGHT", -26, 3)
    scroll:SetScript("OnVerticalScroll", function(self, value)
        FauxScrollFrame_OnVerticalScroll(self, value, ROLE_ROW_H, RR.RefreshRolesUI)
    end)

    rows = {}
    for i = 1, ROLE_ROWS do
        local row = BuildRow(holder, i)
        row:SetPoint("LEFT", 4, 0)
        row:SetPoint("RIGHT", -26, 0)
        if i == 1 then
            row:SetPoint("TOP", holder, "TOP", 0, -4)
        else
            row:SetPoint("TOP", rows[i - 1], "BOTTOM", 0, -1)
        end
        rows[i] = row
    end
end
