-- Pull timer.
--
-- The countdown before a boss: fifteen seconds down to zero, announced where the
-- raid will actually see it -- a raid warning, the same channel the loot rolls
-- use, falling back to raid or party chat when the player has no warning rights.
--
-- Only the numbers that matter are announced. A line every second from fifteen
-- is four lines of noise and then the ones nobody reads; the raid needs the
-- start, a reminder, and the last few seconds.
--
-- Nothing here pulls anything. It counts, it says so, and it stops -- the person
-- who has to walk in is still the person who walks in.

local ADDON_NAME, RR = ...

local running = false
local endsAt = 0
local ticker
local said = {}         -- seconds already announced, so a slow frame cannot double up

-- Fifteen, then ten, then the last five. Anything else is chat nobody reads.
local CALLOUTS = { [10] = true, [5] = true, [4] = true, [3] = true, [2] = true, [1] = true }

RR.MIN_PULL = 3
RR.MAX_PULL = 60

function RR.PullActive()
    return running
end

function RR.PullSecondsLeft()
    if not running then return nil end
    local left = endsAt - GetTime()
    if left < 0 then return 0 end
    return left
end

function RR.CancelPull(quiet)
    if ticker then
        ticker:Cancel()
        ticker = nil
    end

    local wasRunning = running
    running = false
    endsAt = 0
    said = {}

    if wasRunning and not quiet then
        RR.Announce("Pull cancelled.")
    end
    if RR.RefreshPullUI then RR.RefreshPullUI() end
end

function RR.StartPull(seconds)
    seconds = tonumber(seconds) or tonumber(RR.db.pullSeconds) or 15
    if seconds < RR.MIN_PULL then seconds = RR.MIN_PULL end
    if seconds > RR.MAX_PULL then seconds = RR.MAX_PULL end

    -- Starting a second one replaces the first rather than running two
    -- countdowns into the same raid warning channel.
    RR.CancelPull(true)

    running = true
    endsAt = GetTime() + seconds
    said = {}

    RR.Announce(string.format("Pull in %d seconds.", seconds))
    said[seconds] = true

    ticker = C_Timer.NewTicker(0.2, function()
        if not running then return end

        local left = endsAt - GetTime()

        if left <= 0 then
            -- Say it first, stop second: whatever happens to the timer after
            -- this, the raid has been told to go.
            RR.Announce("Pull!")
            RR.CancelPull(true)
            return
        end

        -- The whole second the countdown is currently inside. Announced once,
        -- however many times this ticker runs during it.
        local mark = math.floor(left + 0.5)
        if CALLOUTS[mark] and not said[mark] then
            said[mark] = true
            RR.Announce(tostring(mark))
        end

        if RR.RefreshPullUI then RR.RefreshPullUI() end
    end)

    if RR.RefreshPullUI then RR.RefreshPullUI() end
end

function RR.TogglePull(seconds)
    if running then
        RR.CancelPull()
    else
        RR.StartPull(seconds)
    end
end

function RR.Pull_Init()
    -- A reload kills the ticker with it; never claim a countdown is still
    -- running when nothing is counting.
    running = false
    endsAt = 0
    said = {}
end
