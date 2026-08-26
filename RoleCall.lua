-- Class check.
--
-- The fallback for when nothing else knows what the raid is made of. Inspecting
-- builds needs people in range, whispered applications only cover people who
-- applied, and main tank flags cover two players -- so this asks the raid
-- directly, in a raid warning, and reads the answers straight out of raid chat.
--
-- Everything it learns lands in RR.knownRoles, which is the first source
-- Core.lua's DeclaredRole consults, so an answer here beats an inspected build
-- and shows up in the composition readout the moment it is typed.
--
-- Nothing is sent to anyone but the one warning: replies are read, never
-- answered.

local ADDON_NAME, RR = ...

local watcher
local running = false
local endsAt = 0
local ticker
local answered = {}     -- name -> role, this call only

-- Raid and party chat are group-only by the game itself, so a message arriving
-- on one is already from someone in the group. Say is not, and is filtered
-- below -- it is registered because people standing on top of each other at the
-- summoning stone do answer in say.
local CHAT_EVENTS = {
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_SAY",
}

local function ShortName(sender)
    if not sender or sender == "" then return nil end
    if Ambiguate then
        local ok, short = pcall(Ambiguate, sender, "none")
        if ok and short and short ~= "" then return short end
    end
    return sender
end

-- Is this message nothing but somebody saying what they are?
--
-- Outside a class check, raid chat is full of the word "tank" -- "who is
-- tanking adds", "tank the second one" -- so a loose match would relabel half
-- the raid off other people's sentences. A plain declaration is different: every
-- word in it is either a role word or filler. "resto", "im healer", "tank/dps",
-- "dps here" pass; "can you tank the adds" does not, because "adds" is neither.
local FILLER = {
    ["i"] = true, ["im"] = true, ["i'm"] = true, ["am"] = true, ["me"] = true,
    ["my"] = true, ["is"] = true, ["are"] = true, ["a"] = true, ["an"] = true,
    ["the"] = true, ["and"] = true, ["or"] = true, ["here"] = true, ["hi"] = true,
    ["hey"] = true, ["yo"] = true, ["ok"] = true, ["k"] = true, ["please"] = true,
    ["pls"] = true, ["plz"] = true, ["ill"] = true, ["i'll"] = true, ["be"] = true,
    ["can"] = true, ["go"] = true, ["as"] = true, ["for"] = true, ["main"] = true,
    ["off"] = true, ["100"] = true,
}

local function IsPlainDeclaration(msg)
    if not msg or msg == "" then return false end

    local words = 0
    for word in string.gmatch(string.lower(msg), "[%a'%d]+") do
        words = words + 1
        if words > 6 then return false end
        if not FILLER[word] and not RR.ParseRole(word) then
            return false
        end
    end

    return words > 0
end

RR.IsPlainRoleDeclaration = IsPlainDeclaration

-- One answer. Quiet during a check on purpose: twenty-five confirmations
-- printed into chat is the noise the check was meant to replace, so the
-- composition readout updates instead and the summary comes at the end.
--
-- Outside a check it says so in one line, because a role picked up when nobody
-- asked for one is invisible otherwise -- and "it did not update" is exactly
-- what this feature is judged on.
local function Capture(sender, msg)
    local name = ShortName(sender)
    if not name or not msg then return end

    local grouped = RR.GroupedNames()
    if not grouped[name] then return end

    -- A check is running: they were asked, so anything with a role word in it is
    -- an answer. Nobody asked: only a message that is nothing but a declaration.
    local asked = running
    if not asked and not IsPlainDeclaration(msg) then return end

    local role = RR.ParseRole(msg)
    if not role then return end

    local changed = RR.knownRoles[name] ~= role
    RR.knownRoles[name] = role
    if asked then answered[name] = role end

    -- Someone still sitting in the applicant list gets their row corrected too:
    -- they are in the group now and this is a better answer than whatever they
    -- whispered while applying.
    local record = RR.GetApplicant and RR.GetApplicant(name)
    if record then record.role = role end

    if not asked and changed then
        RR.Print("%s: %s", name, role)
    end

    if RR.RefreshComposition then RR.RefreshComposition() end
    if RR.RefreshList then RR.RefreshList() end
end

-- Who is still silent. This is the whole point of the feature -- the gaps, not
-- the answers -- so it comes straight from the readout's own walk (Core.lua)
-- rather than a second opinion: anyone already covered by a main tank flag or a
-- read build is not silent, they are known, and nagging them is wasted chat.
local function StillUnknown()
    return RR.UnknownRoleNames()
end

function RR.RoleCallActive()
    return running
end

function RR.RoleCallSecondsLeft()
    if not running then return nil end
    local left = endsAt - GetTime()
    if left < 0 then return 0 end
    return left
end

function RR.RoleCallAnswerCount()
    local count = 0
    for _ in pairs(answered) do count = count + 1 end
    return count
end

function RR.StartRoleCall()
    if running then return end

    local size = RR.GroupSize()
    if size <= 1 then
        RR.Print("you are not in a group -- nobody to ask.")
        return
    end

    local message = RR.db.roleCallMessage
    if not message or message == "" then
        message = RR.defaults.roleCallMessage
    end

    local seconds = tonumber(RR.db.roleCallSeconds) or 60
    if seconds < 15 then seconds = 15 end
    if seconds > 300 then seconds = 300 end

    answered = {}
    running = true
    endsAt = GetTime() + seconds

    RR.Announce(message)

    ticker = C_Timer.NewTicker(1, function()
        if not running then return end
        if RR.RefreshRoleCallUI then RR.RefreshRoleCallUI() end
        if GetTime() >= endsAt then
            RR.StopRoleCall()
        end
    end)

    RR.Print("class check running for %ds -- reading raid chat.", seconds)
    if RR.RefreshRoleCallUI then RR.RefreshRoleCallUI() end
end

function RR.StopRoleCall(quiet)
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    local wasRunning = running
    running = false
    endsAt = 0

    if wasRunning and not quiet then
        local count = RR.RoleCallAnswerCount()
        local missing = StillUnknown()
        RR.Print("class check done -- %d answered.", count)
        if #missing > 0 then
            RR.Print("still unknown: %s", table.concat(missing, ", "))
        end
    end

    if RR.RefreshComposition then RR.RefreshComposition() end
    if RR.RefreshRoleCallUI then RR.RefreshRoleCallUI() end
end

function RR.ToggleRoleCall()
    if running then
        RR.StopRoleCall()
    else
        RR.StartRoleCall()
    end
end

function RR.RoleCall_Init()
    -- A reload kills the ticker; make sure the flag matches reality rather than
    -- claiming a check is still listening.
    running = false
    endsAt = 0
    answered = {}

    -- Chat is read for the whole session, not only during a check. The button
    -- is the loud version of this; somebody typing "resto" in raid chat two
    -- minutes later still has to land, or the readout is wrong and nobody can
    -- see why.
    if not watcher then
        watcher = CreateFrame("Frame")
        watcher:SetScript("OnEvent", function(self, event, msg, sender)
            Capture(sender, msg)
        end)
    end
    -- Registering an event this client does not know throws, and one bad name
    -- must not cost the others their registration.
    for _, event in ipairs(CHAT_EVENTS) do
        pcall(watcher.RegisterEvent, watcher, event)
    end
end
