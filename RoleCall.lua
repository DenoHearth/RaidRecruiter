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
local mode              -- "check" (timed) or "chase" (waits for named people)
local chasing = {}      -- name -> true, the people a chase is still waiting on

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
--
-- Chat only counts while a check is running. Raid chat is full of the word
-- "tank" -- "who is tanking adds", "tank the second one" -- and reading it all
-- the time relabels people off other players' sentences. Asked, then answered:
-- that is the whole contract. Whispers are the other half and are handled in
-- Applicants.lua, which never needed a window.
local function Capture(sender, msg)
    if not running then return end

    local name = ShortName(sender)
    if not name or not msg then return end

    local grouped = RR.GroupedNames()
    if not grouped[name] then return end

    local role = RR.ParseRole(msg)
    if not role then return end

    RR.RememberRole(name, role)
    answered[name] = role

    -- Someone still sitting in the applicant list gets their row corrected too:
    -- they are in the group now and this is a better answer than whatever they
    -- whispered while applying.
    local record = RR.GetApplicant and RR.GetApplicant(name)
    if record then record.role = role end

    if RR.RefreshComposition then RR.RefreshComposition() end
    if RR.RefreshList then RR.RefreshList() end

    -- A chase is waiting on named people, not on a clock. The moment the last
    -- one answers it is over -- there is nothing left to wait for, and leaving
    -- chat open after that is how ordinary raid talk gets read as an answer.
    if mode == "chase" and chasing[name] then
        chasing[name] = nil
        if RR.ChaseRemaining() == 0 then
            RR.StopRoleCall()
        elseif RR.RefreshRoleCallUI then
            RR.RefreshRoleCallUI()
        end
    end
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

function RR.RoleCallMode()
    return mode
end

-- How many of the people a chase named have still not answered.
function RR.ChaseRemaining()
    local count = 0
    for _ in pairs(chasing) do count = count + 1 end
    return count
end

function RR.ChaseNames()
    local names = {}
    for name in pairs(chasing) do names[#names + 1] = name end
    table.sort(names)
    return names
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
    chasing = {}
    mode = "check"
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

-- Ask the people who still have not said, by name, and then wait for them.
--
-- The class check is a timed shout at everybody; this is the follow-up, and it
-- has no clock: raiders answer when they alt-tab back, which is a minute after
-- any window would have closed. It ends when the last named person answers, or
-- when the button is clicked again.
--
-- Chat truncates at 255 characters, so a raid full of silent people goes out in
-- several lines rather than one that stops mid-name.
function RR.ChaseUnknown()
    local size = RR.GroupSize()
    if size <= 1 then
        RR.Print("you are not in a group -- nobody to ask.")
        return
    end

    local missing = RR.UnknownRoleNames()
    if #missing == 0 then
        RR.Print("everyone has said what they are -- nobody left to ask.")
        return
    end

    -- A check already running is replaced, not stacked. Quietly: its summary
    -- would name the same people this is about to ask.
    if running then RR.StopRoleCall(true) end

    local PREFIX = "Still need a role from: "
    local SUFFIX = " -- write it in chat."
    local room = RR.MAX_MESSAGE - string.len(PREFIX) - string.len(SUFFIX)

    local lines, current = {}, ""
    for _, name in ipairs(missing) do
        local piece = (current == "") and name or (current .. ", " .. name)
        if string.len(piece) > room and current ~= "" then
            lines[#lines + 1] = current
            current = name
        else
            current = piece
        end
    end
    if current ~= "" then lines[#lines + 1] = current end

    answered = {}
    chasing = {}
    for _, name in ipairs(missing) do chasing[name] = true end
    mode = "chase"
    running = true
    endsAt = 0

    for index, line in ipairs(lines) do
        local message = PREFIX .. line .. SUFFIX
        if index == 1 then
            RR.Announce(message)
        else
            -- Spaced out: the server drops messages fired in the same instant,
            -- and a dropped line looks like a sent one from in here.
            C_Timer.After((index - 1) * 0.8, function() RR.Announce(message) end)
        end
    end

    -- The ticker is only here to keep the button's count fresh; nothing in a
    -- chase expires.
    ticker = C_Timer.NewTicker(1, function()
        if not running then return end
        if RR.RefreshRoleCallUI then RR.RefreshRoleCallUI() end
    end)

    RR.Print("waiting on %d player(s): %s", #missing, table.concat(missing, ", "))
    if RR.RefreshRoleCallUI then RR.RefreshRoleCallUI() end
end

function RR.ToggleChase()
    if running and mode == "chase" then
        RR.StopRoleCall()
    else
        RR.ChaseUnknown()
    end
end

function RR.StopRoleCall(quiet)
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    local wasRunning = running
    local wasMode = mode
    running = false
    endsAt = 0
    mode = nil

    if wasRunning and not quiet then
        local missing = StillUnknown()
        if wasMode == "chase" then
            if #missing == 0 then
                RR.Print("everyone has answered.")
            else
                RR.Print("stopped waiting -- still nothing from: %s", table.concat(missing, ", "))
            end
        else
            RR.Print("class check done -- %d answered.", RR.RoleCallAnswerCount())
            if #missing > 0 then
                RR.Print("still unknown: %s", table.concat(missing, ", "))
            end
        end
    end

    chasing = {}

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
    mode = nil
    answered = {}
    chasing = {}

    -- The watcher stays registered for the session; Capture ignores everything
    -- while no check is running, so there is nothing to unregister and no window
    -- to miss the edge of.
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
