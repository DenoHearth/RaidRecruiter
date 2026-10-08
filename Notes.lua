-- Notes on players.
--
-- One line per player that stays between sessions: "good healer", "left twice mid-run".
-- Written from the Note button on an applicant row; shown there, in the row's tooltip and
-- in the LFG feed. Nothing is sent to anyone.

local ADDON_NAME, RR = ...

local C = RR.COLOR
local MAX_NOTE = 80

local window, nameText, box, current

local function Store()
    RR.db.playerNotes = RR.db.playerNotes or {}
    return RR.db.playerNotes
end

function RR.GetNote(name)
    if not name or not RR.db then return nil end
    local note = Store()[name]
    if note and note ~= "" then return note end
    return nil
end

function RR.SetNote(name, text)
    if not name then return end
    text = strtrim(string.gsub(text or "", "[\r\n]+", " "))
    Store()[name] = text ~= "" and text or nil
    if RR.RefreshList then RR.RefreshList() end
    if RR.RefreshFeedUI then RR.RefreshFeedUI() end
end

local function Save()
    if current then RR.SetNote(current, box:GetText()) end
    window:Hide()
end

local function Build()
    window = CreateFrame("Frame", "RaidRecruiterNote", UIParent)
    window:SetSize(360, 126)
    window:SetPoint("CENTER", 0, 120)
    window:SetFrameStrata("FULLSCREEN_DIALOG")
    window:EnableMouse(true)
    RR.UI_Backdrop(window, C.panel[1], C.panel[2], C.panel[3], 0.98, 1)
    window:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
    tinsert(UISpecialFrames, "RaidRecruiterNote")

    local title = RR.UI_Heading(window, "NOTE ON A PLAYER")
    title:SetPoint("TOPLEFT", 12, -12)
    nameText = RR.UI_Label(window, "", 13, C.text)
    nameText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)

    box = RR.UI_EditBox(window, 336, 22)
    box:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -8)
    box:SetMaxLetters(MAX_NOTE)
    box:SetScript("OnEnterPressed", Save)
    box:SetScript("OnEscapePressed", function() window:Hide() end)

    local save = RR.UI_Button(window, "Save", 80, 22)
    save:SetPoint("BOTTOMLEFT", 12, 12)
    save:SetColor(C.good)
    save:SetScript("OnClick", Save)

    local clear = RR.UI_Button(window, "Remove note", 100, 22)
    clear:SetPoint("LEFT", save, "RIGHT", 6, 0)
    clear:SetScript("OnClick", function()
        if current then RR.SetNote(current, "") end
        window:Hide()
    end)

    local cancel = RR.UI_Button(window, "Cancel", 80, 22)
    cancel:SetPoint("BOTTOMRIGHT", -12, 12)
    cancel:SetScript("OnClick", function() window:Hide() end)
    window:Hide()
end

function RR.OpenNote(name)
    if not name or name == "" then return end
    if not window then Build() end
    current = name
    nameText:SetText(name)
    box:SetText(RR.GetNote(name) or "")
    window:Show()
    box:SetFocus()
end
