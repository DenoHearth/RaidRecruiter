-- The Options page.
--
-- Everything here is a choice that changes how the addon behaves and that is off until
-- you tick it. The other pages only show what such a choice needs while it is on.

local ADDON_NAME, RR = ...

local C = RR.COLOR

local page, rulesCheck, wordCheck, wordBox

function RR.LoadOptionsWidgets()
    if not page then return end
    local db = RR.db
    rulesCheck:SetChecked(RR.LootRulesOn())
    wordCheck:SetChecked(db.inviteWordEnabled and true or false)
    wordBox:SetText(db.inviteWord or "inv")
end

-- A few dim lines of explanation under a tick box.
local function Explain(parent, anchor, lines)
    local text = RR.UI_Label(parent, table.concat(lines, "\n"), 10, C.textDim)
    text:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 22, -2)
    text:SetWidth(700)
    text:SetJustifyH("LEFT")
    text:SetSpacing(3)
    return text
end

function RR.OptionsUI_Init()
    if not RR.NewPage then return end

    page = RR.NewPage("options")

    local box = CreateFrame("Frame", nil, page)
    box:SetPoint("TOPLEFT", 10, -10)
    box:SetPoint("BOTTOMRIGHT", -10, 12)
    RR.UI_Section(box)

    -- Loot rolls
    local lootLabel = RR.UI_Heading(box, "LOOT ROLLS")
    lootLabel:SetPoint("TOPLEFT", 10, -10)

    rulesCheck = RR.UI_CheckBox(box, "Main spec before off spec, then fewest wins tonight (MS +1)")
    rulesCheck:SetPoint("TOPLEFT", lootLabel, "BOTTOMLEFT", -2, -10)
    rulesCheck:SetScript("OnClick", function(self)
        RR.db.msRules = self:GetChecked() and true or false
        if RR.RefreshLootUI then RR.RefreshLootUI() end
    end)

    local rulesText = Explain(box, rulesCheck, {
        "/roll is main spec (MS), /roll 99 is off spec (OS). A main spec roll beats every off spec roll.",
        "A main spec win counts as +1 for the night: among main spec rolls, whoever has won least goes first.",
        "Off: the highest roll wins and nothing is counted.",
    })

    -- Recruiting
    local recruitLabel = RR.UI_Heading(box, "RECRUITING")
    recruitLabel:SetPoint("TOP", rulesText, "BOTTOM", 0, -22)
    recruitLabel:SetPoint("LEFT", lootLabel, "LEFT", 0, 0)

    wordCheck = RR.UI_CheckBox(box, "Invite on the whisper word")
    wordCheck:SetPoint("TOPLEFT", recruitLabel, "BOTTOMLEFT", -2, -10)
    wordCheck:SetScript("OnClick", function(self)
        RR.db.inviteWordEnabled = self:GetChecked() and true or false
    end)

    wordBox = RR.UI_EditBox(box, 60, 18)
    wordBox:SetPoint("LEFT", wordCheck.label, "RIGHT", 6, 0)
    wordBox:SetMaxLetters(20)
    wordBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    wordBox:SetScript("OnTextChanged", function(self)
        RR.db.inviteWord = string.lower(strtrim(self:GetText() or ""))
    end)

    Explain(box, wordCheck, {
        "Whoever whispers you exactly this word gets an invite, while there is room in the group.",
        "Nobody who is already grouped, on your ignore list or hidden in the LFG feed.",
    })
end
