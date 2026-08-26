-- Applicant capture.
--
-- Every incoming whisper becomes (or updates) one row. Repeat whispers from the
-- same person do not stack up as new rows -- they update the existing one and
-- bump its message, so someone who whispers "hi" then "82.4 ilvl resto" ends up
-- as a single applicant with the item level filled in.

local ADDON_NAME, RR = ...

local applicants = {}   -- name -> record
local order = {}        -- names, insertion order (stable tiebreak for sorting)

-- name -> "Tank" / "Healer" / "DPS" / "Tank/DPS", straight from what the player
-- whispered. Kept apart from the records on purpose: clearing the list or
-- removing a row must not make the raid forget what the person said they are,
-- because by then they are already in the group being counted.
RR.knownRoles = {}

-- Every role that is known goes through here, and out to the saved variables on
-- the way. A /reload rebuilds the whole addon from nothing: without this the
-- readout emptied itself every time, halfway through a raid, and there is no way
-- to get the answers back except asking twenty-five people again.
--
-- Nil clears, which is what the "?" button on the Roles page does.
function RR.RememberRole(name, role)
    if not name then return end

    RR.knownRoles[name] = role

    local db = RR.db
    if not db then return end
    db.roles = db.roles or {}
    db.roles[name] = role
    db.rolesSavedAt = time()
end

-- Put back what was saved, unless it is old enough to be a different raid. A
-- reload takes seconds and a relog a minute; anything from yesterday is a
-- stranger with the same name as far as tonight's group is concerned, and a
-- stale role nobody declared is exactly the guessing this addon does not do.
local function RestoreRoles()
    local db = RR.db
    if not db or type(db.roles) ~= "table" then return end

    local hours = tonumber(db.rolesKeepHours) or 12
    local age = time() - (tonumber(db.rolesSavedAt) or 0)
    if age > hours * 3600 then
        db.roles = {}
        db.rolesSavedAt = 0
        return
    end

    for name, role in pairs(db.roles) do
        RR.knownRoles[name] = role
    end
end

-- Item level ------------------------------------------------------------------
--
-- Decimals are kept. On this server item level really is fractional (FrostSeek
-- whispers "62.88 ilvl"), and flooring it throws away the only digits that
-- separate two applicants who both say "62".

local ILVL_PATTERNS = {
    "([%d]+%.?%d*)%s*[Ii][Ll][Vv][Ll]",
    "[Ii][Ll][Vv][Ll]%s*:?%s*([%d]+%.?%d*)",
    "([%d]+%.?%d*)%s*[Ii][Ll][Ee][Vv][Ee][Ll]",
    "[Ii][Ll][Ee][Vv][Ee][Ll]%s*:?%s*([%d]+%.?%d*)",
    "([%d]+%.?%d*)%s*[Gg][Ss]",
    "[Gg][Ss]%s*:?%s*([%d]+%.?%d*)",
    "([%d]+%.?%d*)%s*[Ii][Tt][Ee][Mm]%s*[Ll][Ee][Vv][Ee][Ll]",
    "[Ii][Tt][Ee][Mm]%s*[Ll][Ee][Vv][Ee][Ll]%s*:?%s*([%d]+%.?%d*)",
}

-- Tagged numbers get a wide ceiling because "gs 5400" is a gearscore, which
-- lives in the thousands. An untagged number does not: without a tag, anything
-- that big is a gold amount, a boss ability or a guild recruitment number.
local function Sane(value, ceiling)
    local num = tonumber(value)
    if num and num >= 10 and num <= (ceiling or 1000) then
        return math.floor(num * 100 + 0.5) / 100
    end
    return nil
end

function RR.ParseItemLevel(msg)
    if not msg then return nil end

    for _, pattern in ipairs(ILVL_PATTERNS) do
        local match = string.match(msg, pattern)
        local value = Sane(match, 10000)
        if value then return value end
    end

    -- Nothing tagged. Fall back to a bare number, but only one that is not
    -- obviously something else: "10man", "25m", "lvl 80", "2 dps" and spec
    -- numbers all look like item levels to a naive %d+ match.
    local cleaned = string.gsub(msg, "[Ll][Vv][Ll]%s*%d+", " ")
    cleaned = string.gsub(cleaned, "%d+%s*[Mm][Aa][Nn]", " ")
    cleaned = string.gsub(cleaned, "%d+%s*[Mm]%f[%A]", " ")

    for candidate in string.gmatch(cleaned, "%d+%.?%d*") do
        local value = Sane(candidate)
        -- 20-1000 only: below that it is a group size, a spec count or a level.
        if value and value >= 20 then
            return value
        end
    end
    return nil
end

-- Role ------------------------------------------------------------------------

local ROLE_WORDS = {
    TANK   = { "tank", "tanking", "prot", "protection", "bear", "blood dk", "off tank", "offtank", "ot%f[%A]", "mt%f[%A]" },
    HEALER = { "heal", "healer", "healing", "resto", "restor", "holy", "disc", "hpal", "hpriest", "hdruid", "rdruid", "rsham" },
    DPS    = { "dps", "damage", "melee", "ranged", "caster", "rdps", "mdps" },
}

function RR.ParseRole(msg)
    if not msg then return nil end
    local lower = string.lower(msg)
    local found = {}

    for role, words in pairs(ROLE_WORDS) do
        for _, word in ipairs(words) do
            if string.find(lower, word) then
                found[role] = true
                break
            end
        end
    end

    -- "tank or dps" is real and worth showing as-is rather than picking one.
    local parts = {}
    if found.TANK then parts[#parts + 1] = "Tank" end
    if found.HEALER then parts[#parts + 1] = "Healer" end
    if found.DPS then parts[#parts + 1] = "DPS" end

    if #parts == 0 then return nil end
    return table.concat(parts, "/")
end

-- Class -----------------------------------------------------------------------
--
-- The whisper carries the sender's GUID on this client (Leatrix_Plus reads it
-- the same way), and GetPlayerInfoByGUID turns that into a class token without
-- the player having to be in range. Both are wrapped: neither is guaranteed on
-- a custom client, and a nil class only costs the row its colour.

local function ClassFromArgs(...)
    local guid
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "string" and string.sub(value, 1, 2) == "0x" then
            guid = value
            break
        end
    end
    if not guid or type(GetPlayerInfoByGUID) ~= "function" then
        return nil
    end
    local ok, _, class = pcall(GetPlayerInfoByGUID, guid)
    if ok and type(class) == "string" and class ~= "" then
        return class
    end
    return nil
end

-- Records ---------------------------------------------------------------------

function RR.GetApplicant(name)
    return applicants[name]
end

function RR.ClearApplicants()
    applicants = {}
    order = {}
    if RR.RefreshList then RR.RefreshList() end
end

function RR.RemoveApplicant(name)
    applicants[name] = nil
    for i = #order, 1, -1 do
        if order[i] == name then
            table.remove(order, i)
        end
    end
    if RR.RefreshList then RR.RefreshList() end
end

function RR.MarkInvited(name)
    local record = applicants[name]
    if record then
        record.invited = true
        record.invitedAt = time()
    end
    if RR.RefreshList then RR.RefreshList() end
end

-- "We're full" reply ----------------------------------------------------------

-- Is this whisper someone asking for a spot, or just someone talking to you?
--
-- Answering "Full" to a guildmate saying hello is worse than not answering at
-- all, so the reply needs a positive signal before it fires. Two count: asking
-- for an invite in words, or whispering the thing applicants whisper -- an item
-- level or a role, which is an application even without the word "invite".
-- %f needs a bracketed class: "%f[%a]inv" means "a word starting with inv",
-- which matches inv / invt / invite without matching the middle of a word.
local INVITE_WORDS = {
    "%f[%a]inv",
    "%f[%a]join",
    "%f[%a]spot",
    "%f[%a]room",
    "%f[%a]sign",
    "%f[%a]place%f[%A]",
    "can i come",
    "can i get",
    "may i",
    "got space",
    "any space",
    "%f[%a]lfg%f[%A]",
    "%f[%a]lfm%f[%A]",
}

function RR.LooksLikeApplication(msg)
    if not msg or msg == "" then return false end
    local lower = string.lower(msg)

    -- A bare "+" is the whole message for a lot of people.
    local trimmed = string.gsub(lower, "%s", "")
    if trimmed == "+" or trimmed == "++" or trimmed == "1" then
        return true
    end

    for _, word in ipairs(INVITE_WORDS) do
        if string.find(lower, word) then
            return true
        end
    end

    -- "82.4 ilvl resto" is an application in every way except the wording.
    if RR.ParseItemLevel(msg) or RR.ParseRole(msg) then
        return true
    end

    return false
end

-- The only thing this addon ever sends on its own. It is a canned line, never an
-- invite: a wrong answer here costs someone a polite brush-off, not a raid spot.
--
-- Once per player. Somebody who whispers three times while the raid is full gets
-- told once, because the alternative is the addon arguing with them.
function RR.MaybeReplyFull(record, message)
    local db = RR.db
    if not db or not db.fullReplyEnabled then return end
    if not record or record.fullReplied then return end
    if not RR.LooksLikeApplication(message) then return end

    local reply = db.fullReply
    if not reply or reply == "" then return end

    -- Someone already in the group is not applying, they are chatting.
    if record.grouped then return end
    local grouped = RR.GroupedNames()
    if grouped[record.name] then return end

    local full = RR.GroupIsFull()
    if not full then return end

    record.fullReplied = true
    record.repliedFullAt = time()
    pcall(SendChatMessage, reply, "WHISPER", nil, record.name)
end

local function AddWhisper(msg, sender, ...)
    if not sender or sender == "" then return end

    local name = sender
    if Ambiguate then
        local ok, short = pcall(Ambiguate, sender, "none")
        if ok and short and short ~= "" then name = short end
    end
    if name == UnitName("player") then return end

    local record = applicants[name]
    local isNew = false

    if not record then
        record = {
            name = name,
            firstSeen = time(),
            count = 0,
        }
        applicants[name] = record
        order[#order + 1] = name
        isNew = true
    end

    record.count = record.count + 1
    record.lastSeen = time()
    record.message = msg

    -- Keep the best information seen across all of this player's whispers: a
    -- follow-up "sorry, dps" must not wipe the item level from the first line.
    local ilvl = RR.ParseItemLevel(msg)
    if ilvl then record.ilvl = ilvl end

    -- A whisper only ever sets a role for somebody who is not in the group yet:
    -- that is an application, and the role is the point of it. Once they are in,
    -- their whispers are conversation -- "can you tank this one", "our healer
    -- died" -- and reading a role out of those quietly reassigns people who
    -- never asked to be reassigned. Nothing a group member whispers touches a
    -- role -- not even filling in a blank one, since "our tank died" is not a
    -- man saying he is the tank. Switches and gaps are set by hand on the Roles
    -- page, or asked for in chat where a class check is reading.
    local role = RR.ParseRole(msg)
    if role then
        local grouped = RR.GroupedNames()
        if not grouped[name] then
            record.role = role
            RR.RememberRole(name, role)
        end
    end

    local class = ClassFromArgs(...)
    if class then record.class = class end

    local level = UnitLevel(name)
    if level and level > 0 then record.level = level end

    if isNew and RR.db and RR.db.soundOnWhisper then
        PlaySound("igCharacterInfoTab")
    end

    RR.MaybeReplyFull(record, msg)

    if RR.RefreshList then RR.RefreshList() end
    if RR.FlashNew then RR.FlashNew(isNew) end
end

-- Leavers ---------------------------------------------------------------------
--
-- Someone who was in the group and is not any more went back on the list looking
-- exactly like a fresh applicant, so the row now carries when they dropped out.
-- The check only runs while you still have a group: disbanding or zoning out
-- empties the roster in one go and that is not twenty-four people leaving.

function RR.SyncGroupState()
    local grouped = RR.GroupedNames()
    local haveGroup = (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0
        or (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0

    for _, name in ipairs(order) do
        local record = applicants[name]
        if record then
            local now = grouped[name] and true or false
            if now then
                -- Back in. The count stays: a second departure still reads
                -- "left 2x", which is the part worth knowing before re-inviting.
                record.leftAt = nil
            elseif record.grouped and haveGroup then
                record.leftAt = time()
                record.leftCount = (record.leftCount or 0) + 1
            end
            record.grouped = now
        end
    end

    return grouped
end

-- Sorting and filtering -------------------------------------------------------

local function PassesFilter(record, grouped)
    local db = RR.db

    if db.hideGrouped and grouped[record.name] then
        return false
    end

    if db.minIlvl and db.minIlvl > 0 then
        -- An applicant who never quoted a number is not "below" the threshold,
        -- they are unknown -- hiding them silently loses real people, so they
        -- stay visible and the list marks the item level as unknown.
        if record.ilvl and record.ilvl < db.minIlvl then
            return false
        end
    end

    if db.roleFilter and db.roleFilter ~= "ANY" then
        local role = record.role
        if not role then return false end
        local want = db.roleFilter
        if want == "TANK" and not string.find(role, "Tank") then return false end
        if want == "HEALER" and not string.find(role, "Healer") then return false end
        if want == "DPS" and not string.find(role, "DPS") then return false end
    end

    if RR.searchText and RR.searchText ~= "" then
        local needle = string.lower(RR.searchText)
        local hay = string.lower(record.name .. " " .. (record.message or "") .. " " .. (record.role or ""))
        if not string.find(hay, needle, 1, true) then
            return false
        end
    end

    return true
end

function RR.BuildList()
    local db = RR.db
    local grouped = RR.SyncGroupState()
    local list = {}

    for _, name in ipairs(order) do
        local record = applicants[name]
        if record then
            if PassesFilter(record, grouped) then
                list[#list + 1] = record
            end
        end
    end

    local key = db.sortKey or "time"
    local desc = db.sortDesc

    table.sort(list, function(a, b)
        local av, bv

        if key == "ilvl" then
            -- Unknown item level sorts last in both directions: it is missing
            -- data, not a low score, and burying it under 0 hides applicants.
            if a.ilvl and not b.ilvl then return true end
            if b.ilvl and not a.ilvl then return false end
            av, bv = a.ilvl or 0, b.ilvl or 0
        elseif key == "level" then
            av, bv = a.level or 0, b.level or 0
        elseif key == "name" then
            av, bv = string.lower(a.name), string.lower(b.name)
        else
            av, bv = a.lastSeen or 0, b.lastSeen or 0
        end

        if av == bv then
            return (a.firstSeen or 0) < (b.firstSeen or 0)
        end
        if desc then
            return av > bv
        end
        return av < bv
    end)

    return list, #order
end

function RR.CountApplicants()
    return #order
end

-- Invite ----------------------------------------------------------------------

function RR.Invite(name)
    if not name or name == "" then return end
    InviteUnit(name)
    RR.MarkInvited(name)
end

function RR.WhisperTo(name)
    if not name or name == "" then return end
    local edit = ChatEdit_ChooseBoxForSend and ChatEdit_ChooseBoxForSend() or ChatFrame1EditBox
    if not edit then return end
    edit:SetAttribute("chatType", "WHISPER")
    edit:SetAttribute("tellTarget", name)
    ChatEdit_UpdateHeader(edit)
    edit:Show()
    edit:SetFocus()
end

-- Events ----------------------------------------------------------------------

function RR.Applicants_Init()
    RestoreRoles()

    local watcher = CreateFrame("Frame")

    -- Registering an event this client does not know throws, and one bad name
    -- must not cost the others their registration.
    for _, event in ipairs({ "CHAT_MSG_WHISPER", "PARTY_MEMBERS_CHANGED", "RAID_ROSTER_UPDATE" }) do
        pcall(watcher.RegisterEvent, watcher, event)
    end

    watcher:SetScript("OnEvent", function(self, event, ...)
        if event == "CHAT_MSG_WHISPER" then
            local msg, sender = ...
            AddWhisper(msg, sender, ...)
        else
            -- Roster change. Track it even with the window closed, otherwise a
            -- leaver who drops while you are not looking is never recorded.
            RR.SyncGroupState()
            if RR.RefreshList then RR.RefreshList() end
        end
    end)
end
