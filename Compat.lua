-- The game calls this addon was written against on the 3.3.5 client, answered with what
-- World of Warcraft: Forever has. They live in the addon's own table, not as globals:
-- other addons test for the old global names to tell a Classic client from a modern one.
local ADDON_NAME, RR = ...

-- Raid members, 0 when not in a raid (as the old call answered).
function RR.GetNumRaidMembers()
    return IsInRaid() and GetNumGroupMembers() or 0
end

-- Party members besides yourself, 0 when alone.
function RR.GetNumPartyMembers()
    if not IsInGroup() then return 0 end
    if IsInRaid() then return GetNumSubgroupMembers and GetNumSubgroupMembers() or 0 end
    return math.max(GetNumGroupMembers() - 1, 0)
end

function RR.IsRaidLeader()
    return IsInGroup() and UnitIsGroupLeader("player") and true or false
end

function RR.IsRaidOfficer()
    return IsInRaid() and UnitIsGroupAssistant("player") and true or false
end

-- "freeforall" | "roundrobin" | "master" | "group" | "needbeforegreed" | "personalloot",
-- then the master looter's party index (0 = you) and raid index, as the old call did.
local LOOT_METHOD_NAMES = {}
if Enum and Enum.LootMethod then
    for name, value in pairs({ Freeforall = "freeforall", Roundrobin = "roundrobin", Masterlooter = "master",
        Group = "group", Needbeforegreed = "needbeforegreed", Personal = "personalloot" }) do
        if Enum.LootMethod[name] ~= nil then LOOT_METHOD_NAMES[Enum.LootMethod[name]] = value end
    end
end

function RR.GetLootMethod()
    local method, partyIndex, raidIndex = C_PartyInfo.GetLootMethod()
    return LOOT_METHOD_NAMES[method] or "group", partyIndex, raidIndex
end

function RR.InviteUnit(name)
    return C_PartyInfo.InviteUnit(name)
end

function RR.GetItemInfo(item)
    return C_Item.GetItemInfo(item)
end

function RR.PickupContainerItem(bag, slot)
    return C_Container.PickupContainerItem(bag, slot)
end

function RR.GetContainerNumSlots(bag)
    return C_Container.GetContainerNumSlots(bag)
end

function RR.GetContainerItemLink(bag, slot)
    return C_Container.GetContainerItemLink(bag, slot)
end

-- texture, count, locked, quality, readable, lootable, link - the old return order.
function RR.GetContainerItemInfo(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info then return nil end
    return info.iconFileID, info.stackCount, info.isLocked, info.quality, info.isReadable, info.hasLoot,
        info.hyperlink
end

-- SetBackdrop is not on plain frames any more. The addon only ever uses a flat fill with an
-- optional one-colour edge, so that is drawn here with plain textures.
function RR.EnsureBackdrop(frame)
    if frame.SetBackdrop then return end
    local fill, edges
    function frame:SetBackdrop(info)
        if not fill then
            fill = self:CreateTexture(nil, "BACKGROUND", nil, -8)
            fill:SetAllPoints()
            fill:SetColorTexture(0, 0, 0, 0)
        end
        local size = info and info.edgeSize
        if size and not edges then
            edges = {}
            for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
                { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
                local edge = self:CreateTexture(nil, "BORDER")
                edge:SetColorTexture(0, 0, 0, 1)
                edge:SetPoint(side[1])
                edge:SetPoint(side[2])
                if side[3] then edge:SetHeight(size) else edge:SetWidth(size) end
                edges[#edges + 1] = edge
            end
        end
    end
    function frame:SetBackdropColor(r, g, b, a)
        if fill then fill:SetColorTexture(r, g, b, a or 1) end
    end
    function frame:SetBackdropBorderColor(r, g, b, a)
        for _, edge in ipairs(edges or {}) do edge:SetColorTexture(r, g, b, a or 1) end
    end
end

-- A unit's name, or nil while the client keeps it secret (it can inside an encounter):
-- a secret may not be compared or used as a table key.
function RR.UnitName(unit)
    local name, realm = UnitName(unit)
    if issecretvalue and issecretvalue(name) then return nil end
    return name, realm
end
