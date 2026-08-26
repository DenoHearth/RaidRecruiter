-- Message broadcasting.
--
-- Channels are stored by NAME, never by slot number. Slot numbers shift the
-- moment you join or leave a channel, so a saved "channel 3" quietly becomes
-- the wrong channel later; the name is resolved to a live id at send time.

local ADDON_NAME, RR = ...

local ticker
local nextPostAt = 0
local running = false

RR.lastPost = nil

-- Channel discovery -----------------------------------------------------------

-- Walk the chat window's channel slots. GetChannelName(slot) gives id, name for
-- a joined channel and 0/nil for an empty slot.
function RR.JoinedChannels()
    local channels = {}
    for slot = 1, 20 do
        local ok, id, name = pcall(GetChannelName, slot)
        if ok and type(id) == "number" and id > 0 and type(name) == "string" and name ~= "" then
            channels[#channels + 1] = { id = id, name = name, slot = slot }
        end
    end
    return channels
end

local function ChannelIdByName(wanted)
    for _, channel in ipairs(RR.JoinedChannels()) do
        if channel.name == wanted then
            return channel.id
        end
    end
    return nil
end

-- Addon channels carry machine traffic; posting an LFM line into one spams
-- other people's addons and gets nothing back.
local ADDON_CHANNELS = {
    ["FSK"] = true, ["FROSTSEEK"] = true, ["FROSTNET"] = true, ["FSK-EVT"] = true,
    ["BLFG"] = true, ["HGE"] = true, ["LOOTCOLLECTOR"] = true, ["BBLC25C"] = true,
}

function RR.IsAddonChannel(name)
    if not name then return false end
    local trimmed = string.upper((string.gsub(name, "^%s*(.-)%s*$", "%1")))
    return ADDON_CHANNELS[trimmed] and true or false
end

-- Targets ---------------------------------------------------------------------

-- Everything the message will go to this round, in send order.
function RR.SelectedTargets()
    local db = RR.db
    local targets = {}

    for _, channel in ipairs(RR.JoinedChannels()) do
        if db.channels[channel.name] then
            targets[#targets + 1] = { kind = "CHANNEL", name = channel.name, id = channel.id }
        end
    end

    if db.guild and IsInGuild and IsInGuild() then
        targets[#targets + 1] = { kind = "GUILD", name = "Guild" }
    end
    if db.say then
        targets[#targets + 1] = { kind = "SAY", name = "Say" }
    end
    if db.yell then
        targets[#targets + 1] = { kind = "YELL", name = "Yell" }
    end

    return targets
end

-- Sending ---------------------------------------------------------------------

local function SendOne(target, message)
    local ok, err
    if target.kind == "CHANNEL" then
        -- Re-resolve: the id can go stale between the round starting and this
        -- staggered send firing, if a channel was left in between.
        local id = ChannelIdByName(target.name) or target.id
        ok, err = pcall(SendChatMessage, message, "CHANNEL", nil, id)
    else
        ok, err = pcall(SendChatMessage, message, target.kind)
    end

    if not ok then
        RR.Print("could not post to %s: %s", target.name, tostring(err))
    end
    return ok
end

-- One round. Sends are spaced out: the server drops messages fired back to back
-- in the same instant, and a dropped post looks exactly like a working one from
-- the addon's side, so spacing is the only defence.
local SEND_GAP = 0.8

function RR.PostNow()
    local db = RR.db
    local message = db.message

    if not message or message == "" then
        RR.Print("nothing to post -- type a message first.")
        return false
    end

    local targets = RR.SelectedTargets()
    if #targets == 0 then
        RR.Print("no channels ticked -- pick at least one target.")
        return false
    end

    for index, target in ipairs(targets) do
        if index == 1 then
            SendOne(target, message)
        else
            local delay = (index - 1) * SEND_GAP
            C_Timer.After(delay, function()
                SendOne(target, message)
            end)
        end
    end

    RR.lastPost = time()
    nextPostAt = GetTime() + (db.interval or 60)
    return true
end

-- Timer -----------------------------------------------------------------------

function RR.IsBroadcasting()
    return running
end

function RR.SecondsToNextPost()
    if not running then return nil end
    local remaining = nextPostAt - GetTime()
    if remaining < 0 then return 0 end
    return remaining
end

function RR.StartBroadcast()
    local db = RR.db

    if not db.message or db.message == "" then
        RR.Print("nothing to post -- type a message first.")
        return
    end
    if #RR.SelectedTargets() == 0 then
        RR.Print("no channels ticked -- pick at least one target.")
        return
    end

    RR.StopBroadcast(true)

    local interval = math.max(RR.MIN_INTERVAL, math.min(RR.MAX_INTERVAL, tonumber(db.interval) or 60))
    db.interval = interval

    running = true
    RR.PostNow()

    ticker = C_Timer.NewTicker(interval, function()
        if not running then return end
        RR.PostNow()
    end)

    RR.Print("posting every %ds to %d target(s). /rr stop to end.", interval, #RR.SelectedTargets())
    if RR.RefreshBroadcastUI then RR.RefreshBroadcastUI() end
end

function RR.StopBroadcast(quiet)
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    local wasRunning = running
    running = false
    nextPostAt = 0

    if wasRunning and not quiet then
        RR.Print("stopped posting.")
    end
    if RR.RefreshBroadcastUI then RR.RefreshBroadcastUI() end
end

function RR.ToggleBroadcast()
    if running then
        RR.StopBroadcast()
    else
        RR.StartBroadcast()
    end
end

function RR.Broadcast_Init()
    -- A reload or a logout kills the ticker anyway; make sure the flag matches
    -- reality rather than resuming a broadcast the user cannot see running.
    running = false
    nextPostAt = 0
end
