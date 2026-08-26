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

-- One answer. Quiet on purpose: twenty-five confirmations printed into chat
-- during a class check is the noise the check was meant to replace, so the
-- composition readout updates instead and the summary comes at the end.
local function Capture(sender, msg)
    local name = ShortName(sender)
    if not name or not msg then return end

    local grouped = RR.GroupedNames()
    if not grouped[name] then return end

    local role = RR.ParseRole(msg)
    if not role then return end

    RR.knownRoles[name] = role
    answered[name] = role

    -- Someone still sitting in the applicant list gets their row corrected too:
    -- they are in the group now and this is a better answer than whatever they
    -- whispered while applying.
    local record = RR.GetApplicant and RR.GetApplicant(name)
    if record then record.role = role end

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

    if not watcher then
        watcher = CreateFrame("Frame")
        watcher:SetScript("OnEvent", function(self, event, msg, sender)
            if not running then return end
            Capture(sender, msg)
        end)
    end
    -- Registering an event this client does not know throws, and one bad name
    -- must not cost the others their registration.
    for _, event in ipairs(CHAT_EVENTS) do
        pcall(watcher.RegisterEvent, watcher, event)
    end

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
    if watcher then
        watcher:UnregisterAllEvents()
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
    -- A reload kills the ticker and the registration with it; make sure the
    -- flag matches reality rather than claiming a check is still listening.
    running = false
    endsAt = 0
    answered = {}
end
