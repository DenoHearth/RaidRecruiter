-- Reload popup, shared by our Forever addons (master copy: _tools/shared/ReloadPopup.lua; each
-- addon ships its own copy, titled with the addon's ns.TITLE or folder name).
-- His rule, 2026-10-23: a change that needs a reload says so in a popup with a Reload button,
-- never in chat. Our own small window, not Blizzard's StaticPopup: those frames are shared with
-- the game's protected dialogs, and an addon dialog shown through them runs there tainted.
local ADDON, ns = ...

local popup

local function Build()
	popup = CreateFrame("Frame", nil, UIParent)
	popup:SetSize(380, 140)
	popup:SetPoint("CENTER", 0, 160)
	popup:SetFrameStrata("FULLSCREEN_DIALOG")
	popup:EnableMouse(true)
	popup:Hide()
	-- the dialog border template fills its parent, so it sits on a child of the popup
	local border = CreateFrame("Frame", nil, popup, "DialogBorderTranslucentTemplate")
	border:SetAllPoints()
	border:SetFrameLevel(popup:GetFrameLevel())

	popup.title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	popup.title:SetPoint("TOP", 0, -18)

	popup.text = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	popup.text:SetPoint("TOPLEFT", 22, -46)
	popup.text:SetPoint("TOPRIGHT", -22, -46)
	popup.text:SetJustifyH("CENTER")
	popup.text:SetSpacing(2)

	popup.reload = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
	popup.reload:SetSize(140, 30)
	popup.reload:SetText("Reload now")
	popup.reload:SetScript("OnClick", function() ReloadUI() end)

	popup.later = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
	popup.later:SetSize(140, 30)
	popup.later:SetScript("OnClick", function() popup:Hide() end)
end

local function Show(text, withReload)
	if not popup then Build() end
	popup.title:SetText(ns.TITLE or ADDON)
	popup.text:SetText(text)
	popup:SetHeight(math.max(140, popup.text:GetStringHeight() + 104))
	popup.reload:ClearAllPoints()
	popup.later:ClearAllPoints()
	if withReload then
		popup.reload:Show()
		popup.reload:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -6, 20)
		popup.later:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 6, 20)
		popup.later:SetText("Later")
	else
		popup.reload:Hide()
		popup.later:SetPoint("BOTTOM", 0, 20)
		popup.later:SetText("Okay")
	end
	popup:Show()
end

-- A change that loads with a reload: the text says what, the popup offers Reload now / Later.
function ns.AskReload(text)
	Show(text, true)
end

-- Something a reload cannot fix (a new file needs a full game restart): Okay only.
function ns.Notice(text)
	Show(text, false)
end
