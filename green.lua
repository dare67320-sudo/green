-- Green (Matcha) - basketball auto shot
-- Lock key (Z) toggles the aim lock: while holding the ball it sets power and locks the
-- shift-lock camera on the solved aim. Shoot key (X) fires when READY; pressed during WAIT
-- it queues and fires the moment it turns READY. Right Shift opens the menu.
-- Auto guard (N / menu): follows the opponent who has the ball; stops the moment you have it.

local lp  = game.Players.LocalPlayer
local cam = workspace.CurrentCamera

-- settings (lock/shoot keys, jump shots and ball switch are also in the menu)
local LOCK_KEY    = 0x5A  -- Z
local SHOOT_KEY   = 0x58  -- X
local JUMP_SHOTS  = true  -- timed jump shot past STAND_MAX (steadier than standing at long range)
local BALL_SWITCH = false -- keep the ball in the hand away from the nearest defender
local AUTO_GUARD  = false -- follow the opponent with the ball (off whenever you have it)
local GUARD_KEY   = 0x4E  -- N
local GUARD_GAP   = 4     -- when far: stand this far in front of them, toward their hoop
local STEAL_RANGE = 6     -- when this close: go for the ball itself (steals are touch-based)
local STEAL_LEAD  = 0.15  -- minimum lead: aim where they'll be this far ahead (server lag)
local RUN_SPEED   = 16    -- your run speed; lead grows with distance so you intercept, not chase
local JUMP_REACH  = 6     -- height above your root you can touch at the top of a jump
local JUMP_RISE   = 0.22  -- seconds from pressing jump to reaching that height

local HOLD       = 0.35   -- mouse hold for a shot
local STAND_MAX  = 50     -- with jump shots on, X jumps from here out (standing long shots vary +-1.5 studs)
local MAX_RANGE  = 72.5   -- jump-shot limit
local JUMP_DELAY = 0.36   -- jump shot: shoot this long after leaving the ground
local AIM_GAIN   = 0.9    -- camera correction per frame (1 = snap)
local LAG_EXTRA  = 0.06   -- ball launches from where you were ~ping + this before the press (measured 0.09s at 33ms)

-- verified standing makes (shift lock): {distance, power, pitch}
local STAND = {
    {10, 35, 57.5}, {15, 40, 62.85}, {20, 50, 63.74}, {25, 60, 68.42},
    {30, 65, 63.40}, {35, 75, 67.03}, {40, 80, 66.19}, {45, 85, 64.58},
    {50, 85, 60.79}, {55, 85, 58.13}, {58, 85, 55.90}, {60, 85, 54.37},
    {61, 85, 52.90}, {63, 85, 50.45}, {65, 85, 47.10}, {66, 85, 45.60},
}
-- verified jump-shot makes (power 85): {distance, pitch}
local JUMP = {
    {50, 61.34}, {54, 58.20}, {58, 55.48}, {62, 52.84},
    {66, 51.0}, {68, 47.5}, {70, 43.5}, {72, 38.0},
}
-- range change per degree of pitch, by power (for distances between rows of different power)
local SLOPE = {[35]=-0.3, [40]=-0.47, [50]=-0.6, [60]=-1.5, [65]=-1.9, [75]=-1.1, [80]=-1.27, [85]=-0.75}

-- ball physics: v = 1.08*power*cameraDir + 40.5 up, gravity 196.2 (used for your own jumps)
local G, K, C, H0, RIM_REL = 196.2, 1.08, 40.5, 2.0, 10.5
local PX_YAW, PX_PITCH = 21.3, 23.7 -- mouse pixels per degree

-- one instance at a time: stop and remove the previous load
local S = _G.GREEN or {}
_G.GREEN = S
S.gen = (S.gen or 0) + 1
if S.ui then pcall(function() S.ui:Destroy() end) S.ui = nil end
local gen = S.gen

local function wrap(a) a = a % 360 if a > 180 then a = a - 360 end return a end
local function camPitch() local l = cam.CFrame.LookVector return math.deg(math.asin(l.Y)) end
local function camYaw() local l = cam.CFrame.LookVector return math.deg(math.atan2(-l.X, -l.Z)) end
local function root() return lp.Character and lp.Character:FindFirstChild("HumanoidRootPart") end
local function ball() local c = lp.Character return c and c:FindFirstChild("Basketball") end
local function tap(k) keypress(k) task.wait(0.05) keyrelease(k) end

-- hoops
local GOALS = {}
for _, folder in ipairs({ workspace:FindFirstChild("Courts"), workspace:FindFirstChild("PracticeArea") }) do
    if folder then
        for _, d in ipairs(folder:GetDescendants()) do
            if (d.Name == "Goal" or d.Name == "GoalHome" or d.Name == "GoalAway") and d.ClassName == "Part" then
                table.insert(GOALS, d.Position)
            end
        end
    end
end
local function nearestGoal(p)
    local best, bd
    for _, g in ipairs(GOALS) do
        local d = math.sqrt((g.X - p.X)^2 + (g.Z - p.Z)^2)
        if not bd or d < bd then best, bd = g, d end
    end
    return best, bd
end

-- the players you're matched against on your court (other side of _CourtPlayers)
local function opponents()
    local court = workspace:FindFirstChild("Courts") and workspace.Courts:FindFirstChild(tostring(lp:GetAttribute("ActiveCourt")))
    local slots = court and court:FindFirstChild("_CourtPlayers")
    if not slots then return nil end
    local function playerIn(v) local ok, p = pcall(function() return v.Value end)
        return ok and p and pcall(function() return p.ClassName end) and p.ClassName == "Player" and p or nil end
    local mySide
    for _, v in ipairs(slots:GetChildren()) do if playerIn(v) == lp then mySide = v.Name:match("^(%a+)") end end
    if mySide ~= "Home" and mySide ~= "Away" then return nil end
    local list = {}
    for _, v in ipairs(slots:GetChildren()) do
        local side, p = v.Name:match("^(%a+)"), playerIn(v)
        if p and p ~= lp and (side == "Home" or side == "Away") and side ~= mySide then table.insert(list, p) end
    end
    return list
end

-- standing shot: (power, pitch) for a distance
local function solveStand(d)
    for i = 1, #STAND - 1 do
        local a, b = STAND[i], STAND[i+1]
        if d >= a[1] and d <= b[1] and a[2] == b[2] then
            return a[2], a[3] + (b[3] - a[3]) * (d - a[1]) / (b[1] - a[1])
        end
    end
    local best, bd
    for _, e in ipairs(STAND) do
        if not bd or math.abs(e[1] - d) < bd then best, bd = e, math.abs(e[1] - d) end
    end
    return best[2], math.clamp(best[3] + (d - best[1]) / (SLOPE[best[2]] or -1), 15, 80)
end

-- jump shot pitch: piecewise-linear, end segments extended
local function solveJump(d)
    local i = 1
    while i < #JUMP - 1 and d > JUMP[i+1][1] do i = i + 1 end
    local a, b = JUMP[i], JUMP[i+1]
    return a[2] + (b[2] - a[2]) * (d - a[1]) / (b[1] - a[1])
end

-- launching dh higher (your own jump, or a different rim height) changes range;
-- keep the verified range and correct only for the height difference
local function modelRange(p, pitch, dh)
    local a = math.rad(pitch)
    local vh, vy = K*p*math.cos(a), K*p*math.sin(a) + C
    local disc = vy*vy - 2*G*(RIM_REL - H0 - dh)
    if disc < 0 then return nil end
    return vh * (vy + math.sqrt(disc)) / G
end
local function adjustForHeight(p, pitch, dh)
    if math.abs(dh) < 0.05 then return pitch end
    local want = modelRange(p, pitch, 0)
    if not want then return pitch end
    local lo, hi = pitch, 85
    if dh < 0 then lo, hi = math.max(pitch - 25, 10), pitch end
    for _ = 1, 30 do
        local mid = (lo + hi) / 2
        if (modelRange(p, mid, dh) or 0) > want then lo = mid else hi = mid end
    end
    return (lo + hi) / 2
end

local function lagSeconds()
    local ms = 80
    pcall(function() ms = tonumber(lp.PlayerGui.TopbarInsets.PING.PingLabel.Text:match("(%d+)")) or ms end)
    return ms / 1000 + LAG_EXTRA
end

-- position history: the server launches the ball from where it last saw you
local hist, groundY, still = {}, nil, 0
local function record()
    local r = root() if not r then return end
    local now, p = os.clock(), r.Position
    table.insert(hist, {now, p})
    while #hist > 0 and now - hist[1][1] > 1 do table.remove(hist, 1) end
    if math.abs(r.AssemblyLinearVelocity.Y) < 0.6 then still = still + 1 else still = 0 end
    if still >= 6 then groundY = p.Y end -- grounded only after ~0.1s of no vertical speed
end
local function posAgo(dt)
    local t = os.clock() - dt
    for i = #hist, 1, -1 do if hist[i][1] <= t then return hist[i][2] end end
    return hist[1] and hist[1][2]
end

-- power steps in the background so the camera lock never stalls
local powerBusy = false
local function nudgePower(target)
    if powerBusy or lp:GetAttribute("Power") == target then return end
    powerBusy = true
    task.spawn(function()
        tap(lp:GetAttribute("Power") < target and 0x45 or 0x51) -- E / Q
        task.wait(0.22)
        powerBusy = false
    end)
end

local function shiftLockOn()
    local function on()
        mousemoverel(40, 0) task.wait(0.25)
        local l = root().CFrame.LookVector
        return math.abs(wrap(math.deg(math.atan2(-l.X, -l.Z)) - camYaw())) < 3
    end
    if on() then return end
    tap(0xA0) task.wait(0.3) -- Left Shift
end

-- on-screen status (kept in S so a reload always removes the previous copy's label)
if S.hud then pcall(function() S.hud:Remove() end) S.hud = nil end
local hudText
pcall(function()
    hudText = Drawing.new("Text")
    S.hud = hudText
    hudText.Size = 18 hudText.Outline = true hudText.Center = true
    hudText.Position = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y * 0.72)
    hudText.Visible = true
end)
local ui, lockToggle, statusLabel, lastStatus
local function status(t, green)
    S.status = t
    if hudText then
        hudText.Text = t
        hudText.Color = green and Color3.fromRGB(80, 255, 120) or Color3.fromRGB(255, 120, 90)
    end
    if statusLabel and t ~= lastStatus then
        lastStatus = t
        pcall(function() statusLabel:SetDescription(t) end)
    end
end

local locked, firing = false, false
local guardToggle
local function setGuard(v, fromMenu)
    if v == AUTO_GUARD then return end
    AUTO_GUARD = v
    if v then task.spawn(shiftLockOn) end
    if guardToggle and not fromMenu then pcall(function() guardToggle:SetValue(v) end) end
end
local function setLocked(v, fromMenu)
    if v == locked then return end
    locked = v
    if v then task.spawn(shiftLockOn) end
    if lockToggle and not fromMenu then pcall(function() lockToggle:SetValue(v) end) end
end

-- current solution
local sol = {}
local function solve()
    local r = root() if not r then return nil end
    local seen = posAgo(lagSeconds()) or r.Position -- where the server will launch from
    local goal, dist = nearestGoal(seen)
    if not goal then return nil, "no hoop" end
    local maxr = JUMP_SHOTS and MAX_RANGE or 67
    if dist > maxr then return nil, ("too far %.0f (max %.0f)"):format(dist, maxr) end
    local gy = groundY or r.Position.Y
    local dh = (seen.Y - gy) + (RIM_REL - (goal.Y - gy))
    local aimDist = dist
    local p, pitch, jumpShot
    if JUMP_SHOTS and aimDist > STAND_MAX then
        p, pitch, jumpShot = 85, solveJump(aimDist), true
    else
        p, pitch = solveStand(aimDist)
        pitch = adjustForHeight(p, pitch, dh)
    end
    sol.goal, sol.seen, sol.dist, sol.power, sol.pitch, sol.jumpShot = goal, seen, dist, p, pitch, jumpShot
    return sol
end

-- one camera correction step; yaw is aimed from the launch point the server uses
local function aim()
    local p = sol.seen
    local ty = math.deg(math.atan2(-(sol.goal.X - p.X), -(sol.goal.Z - p.Z)))
    local ep, ey = sol.pitch - camPitch(), wrap(ty - camYaw())
    if math.abs(ep) > 0.1 or math.abs(ey) > 0.15 then
        mousemoverel(math.floor(-ey * PX_YAW * AIM_GAIN + 0.5), math.floor(-ep * PX_PITCH * AIM_GAIN + 0.5))
    end
    return ep, ey
end

local function fire()
    if firing or not locked or not ball() or not sol.goal then return end
    firing = true
    if sol.jumpShot then
        tap(0x20) -- jump, keep the lock, shoot exactly JUMP_DELAY after leaving the ground
        local t = os.clock()
        while os.clock() - t < JUMP_DELAY - 0.05 do task.wait(1/60) end
    end
    local t0 = os.clock()
    mouse1press()
    while os.clock() - t0 < HOLD do task.wait(1/60) end
    mouse1release()
    firing = false
end

-- ball switch: + = ball in right hand, - = left hand (ball sits ~1.5 studs to that side)
local lastSwitch = 0
local function ballSwitch()
    if firing or os.clock() - lastSwitch < 0.5 then return end
    local r, b = root(), ball()
    if not (r and b and b:FindFirstChild("Ball")) then return end
    local me, right = r.Position, r.CFrame.RightVector
    local nearest, nd
    for _, pl in ipairs(opponents() or game.Players:GetPlayers()) do
        local oh = pl ~= lp and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
        if oh then
            local d = (oh.Position - me).Magnitude
            if not nd or d < nd then nearest, nd = oh, d end
        end
    end
    if not nearest then return end
    local od = nearest.Position - me
    local defSide = od.X*right.X + od.Z*right.Z
    if math.abs(defSide) < 0.75 then return end -- straight ahead/behind: leave it
    local bo = b.Ball.Position - me
    local ballSide = bo.X*right.X + bo.Y*right.Y + bo.Z*right.Z
    if math.abs(ballSide) < 0.6 then return end -- mid-move
    if (ballSide > 0) == (defSide > 0) then
        lastSwitch = os.clock()
        tap(0x48) -- H: switch handles
    end
end

-- auto guard: turn smoothly toward where you need to be and run forward (W only), so
-- movement never zig-zags and every step closes the distance
local guardHeldW, guardMoving = false, false
local function guardW(on)
    if guardHeldW == on then return end
    guardHeldW = on
    if on then keypress(0x57) else keyrelease(0x57) end
end
-- A/S/D for the bait race (W is shared with guardW)
local raceHeld = {}
local function raceKey(k, on)
    if (raceHeld[k] or false) == on then return end
    raceHeld[k] = on
    if on then keypress(k) else keyrelease(k) end
end
local function stopRace() raceKey(0x41, false) raceKey(0x53, false) raceKey(0x44, false) end
local function stopGuard() guardW(false) stopRace() guardMoving = false end

-- bait counter: opponent tosses the ball straight up to make you bite, then re-catches it.
-- Go to where it comes down (gravity 196.2) and jump to touch it first.
local lastOpp = nil
local ballTrack = {}
local lastJump = 0
local baitUntil = 0 -- once a toss is spotted, stay on it for the whole flight
local function steerTo(dest, me, stopAt, goAt)
    local dist = math.sqrt((dest.X - me.X)^2 + (dest.Z - me.Z)^2)
    if guardMoving and dist < stopAt then guardMoving = false
    elseif not guardMoving and dist > goAt then guardMoving = true end
    local ty = math.deg(math.atan2(-(dest.X - me.X), -(dest.Z - me.Z)))
    local ey = wrap(ty - camYaw())
    local ep = -8 - camPitch()
    if math.abs(ey) > 0.5 or math.abs(ep) > 2 then
        mousemoverel(math.floor(-math.clamp(ey * 0.5, -30, 30) * PX_YAW + 0.5), math.floor(-ep * PX_PITCH * 0.3 + 0.5))
    end
    guardW(guardMoving and math.abs(ey) < 45)
    return dist
end
local function baitCounter(r)
    local b = lastOpp and lastOpp.ball
    -- someone else picked it up since (you, a teammate): it's no longer their toss
    local holderChar = b and b.Parent and b.Parent.Parent
    if holderChar and holderChar ~= workspace and holderChar ~= (lastOpp.who and lastOpp.who.Character) then lastOpp = nil return nil end
    if not (b and b.Parent and b.Parent.Parent == workspace) then ballTrack = {} baitUntil = 0 return nil end -- not a loose ball
    local who = lastOpp.who
    local now, p = os.clock(), b.Position
    if #ballTrack == 0 then ballTrack.start = now end
    -- skip the first ~0.08s after release: the ball is still moving with the hand
    if now - ballTrack.start < 0.05 then table.insert(ballTrack, {now, p}) return nil end
    table.insert(ballTrack, {now, p})
    while #ballTrack > 1 and now - ballTrack[1][1] > 0.25 do table.remove(ballTrack, 1) end
    local t0, p0 = ballTrack[1][1], ballTrack[1][2]
    if now - t0 < 0.05 then return nil end
    -- velocity over the window; vertical part corrected for gravity over that window
    local dt = now - t0
    local v = (p - p0) / dt
    v = Vector3.new(v.X, v.Y - G * dt / 2, v.Z)
    local me = r.Position
    local catchY = me.Y + 2
    if p.Y < catchY - 1 and v.Y < 0 then baitUntil = 0 return nil end -- it's down; normal guarding takes over
    -- where it comes down to catch height
    local dy = p.Y - catchY
    local disc = v.Y*v.Y + 2*G*dy
    local tLand = disc > 0 and (v.Y + math.sqrt(disc)) / G or 0
    local land = Vector3.new(p.X + v.X*tLand, catchY, p.Z + v.Z*tLand)
    if now > baitUntil then
        -- a shot comes down at a hoop; a bait toss comes down somewhere on the floor
        local hoop, hd = nearestGoal(land)
        if hoop and hd < 6 then return nil end
        baitUntil = now + 3
    end
    -- race: move straight at the landing spot with W/A/S/D in your own frame, no turning first
    local look, right = r.CFrame.LookVector, r.CFrame.RightVector
    local dx, dz = land.X - me.X, land.Z - me.Z
    local dist = math.sqrt(dx*dx + dz*dz)
    local fwd, side = (dx*look.X + dz*look.Z) / math.max(dist, 0.01), (dx*right.X + dz*right.Z) / math.max(dist, 0.01)
    local go = dist > 0.6
    guardW(go and fwd > 0.38)  raceKey(0x53, go and fwd < -0.38)
    raceKey(0x44, go and side > 0.38) raceKey(0x41, go and side < -0.38)
    -- jump early so you're at the top of your jump (reach ~6 above your root) when the ball
    -- comes down through that height - above where they can catch it standing
    local reachY = me.Y + JUMP_REACH
    local dyr = p.Y - reachY
    local discR = v.Y*v.Y + 2*G*dyr
    local tReach = (discR > 0 and dyr > 0) and (v.Y + math.sqrt(discR)) / G or -1
    if dist < 3 and tReach > 0 and tReach <= JUMP_RISE and os.clock() - lastJump > 0.6 then
        lastJump = os.clock()
        task.spawn(tap, 0x20)
    end
    return ("bait counter: racing to %s's toss (%.1f studs, lands in %.2fs)"):format(who.Name, dist, tLand)
end

local function guardStep()
    local r = root() if not r then stopGuard() return "guard: no character" end
    local opp = opponents()
    if not opp then stopGuard() return "guard: not in a match" end
    -- look the ball up once: it can leave their hands between two lookups
    local handler, hbFolder
    for _, pl in ipairs(opp) do
        local f = pl.Character and pl.Character:FindFirstChild("Basketball")
        if f then handler, hbFolder = pl, f break end
    end
    local hr = handler and handler.Character and handler.Character:FindFirstChild("HumanoidRootPart")
    local hball = hbFolder and hbFolder:FindFirstChild("Ball")
    if hr then
        stopRace() -- back to normal guarding: only W is used
        lastOpp = hball and { ball = hball, who = handler } or lastOpp
    else
        local s = baitCounter(r)
        if s then return s end
        stopGuard() return "guard: opponent doesn't have the ball"
    end
    local hp, me = hr.Position, r.Position
    local stealing = hball ~= nil and (hp - me).Magnitude <= STEAL_RANGE

    local dest
    if stealing then
        -- close: run into where the dribbled ball will be (steals are touch-based)
        dest = hball.Position
    else
        -- far: get between them and their hoop
        dest = hp
        local hoop = nearestGoal(hp)
        if hoop then
            local dx, dz = hoop.X - hp.X, hoop.Z - hp.Z
            local m = math.sqrt(dx*dx + dz*dz)
            if m > 0.5 then dest = hp + Vector3.new(dx / m, 0, dz / m) * math.min(GUARD_GAP, m) end
        end
    end
    -- intercept: lead by about how long it takes you to get there
    local v = hr.AssemblyLinearVelocity
    local raw = math.sqrt((dest.X - me.X)^2 + (dest.Z - me.Z)^2)
    local lead = math.clamp(raw / RUN_SPEED, STEAL_LEAD, 0.6)
    dest = dest + Vector3.new(v.X, 0, v.Z) * lead
    local dist = math.sqrt((dest.X - me.X)^2 + (dest.Z - me.Z)^2)

    -- start/stop with hysteresis so W doesn't flicker
    local stopAt, goAt = 1.0, 2.0
    if stealing then stopAt, goAt = 0.3, 0.7 end
    if guardMoving and dist < stopAt then guardMoving = false
    elseif not guardMoving and dist > goAt then guardMoving = true end

    -- face where you're running; once in position, face the ball handler
    local face = guardMoving and dest or (stealing and dest or hp)
    local ty = math.deg(math.atan2(-(face.X - me.X), -(face.Z - me.Z)))
    local ey = wrap(ty - camYaw())
    local ep = -8 - camPitch()
    local turn = math.clamp(ey * 0.5, -30, 30) -- smooth, capped turn per frame
    if math.abs(ey) > 0.5 or math.abs(ep) > 2 then
        mousemoverel(math.floor(-turn * PX_YAW + 0.5), math.floor(-ep * PX_PITCH * 0.3 + 0.5))
    end
    guardW(guardMoving and math.abs(ey) < 45) -- turn first if the target is off to the side

    return ("%s %s (%.1f studs)"):format(stealing and "going for the ball:" or "guarding", handler.Name, (hp - me).Magnitude)
end

-- main loop
task.spawn(function()
    local lockWas, shootWas, guardWas = false, false, false
    local queued, queuedAt, ready, readyFrames = false, 0, false, 0
    while S.gen == gen do
      local okStep, stepErr = pcall(function()
        record()
        local active = isrbxactive()
        local lk, sk = iskeypressed(LOCK_KEY), iskeypressed(SHOOT_KEY)
        if active and lk and not lockWas then setLocked(not locked) end
        if active and sk and not shootWas and locked then
            if ready and not firing then task.spawn(fire) else queued, queuedAt = true, os.clock() end
        end
        lockWas, shootWas = lk, sk
        local gk = iskeypressed(GUARD_KEY)
        if active and gk and not guardWas then setGuard(not AUTO_GUARD) end
        guardWas = gk

        local holding = ball() ~= nil
        if holding then lastOpp = nil end -- your own shot is never an opponent's bait toss
        if not locked or not holding or os.clock() - queuedAt > 4 then queued = false end
        ready = false
        if BALL_SWITCH and active and holding then task.spawn(ballSwitch) end

        local menuOpen = false
        if ui then pcall(function() menuOpen = ui:IsOpen() end) end

        -- auto guard only runs while you don't have the ball
        local guardStatus
        if AUTO_GUARD and not holding and active and not menuOpen then guardStatus = guardStep() else stopGuard() end

        if not locked then
            readyFrames = 0
            status("Green: " .. (guardStatus or "off"), false)
        elseif menuOpen then
            readyFrames = 0
            status("Green: paused (menu open)", false)
        elseif not holding then
            readyFrames = 0
            status("Green: " .. (guardStatus or "no ball"), false)
        else
            local s, why = solve()
            if not s then
                readyFrames = 0
                status("Green: " .. tostring(why), false)
            elseif active then
                nudgePower(s.power)
                local ep, ey = aim()
                -- READY: power and aim right for 3 frames in a row; a sudden jump in position
                -- (respawn/teleport) makes the server's view stale, so wait for it to catch up
                local now = root().Position
                local gap = Vector3.new(now.X - s.seen.X, 0, now.Z - s.seen.Z).Magnitude
                -- while moving the camera trails the target by ~0.5 deg; that still goes in
                -- (moving jump shots too: the launch point lag is measured, ~ping + 0.06s)
                local ok = lp:GetAttribute("Power") == s.power and math.abs(ep) < 0.35 and math.abs(ey) < 0.7
                    and gap < 6
                readyFrames = ok and readyFrames + 1 or 0
                ready = readyFrames >= 3
                if queued and ready and not firing then queued = false task.spawn(fire) end
                local tag = ready and "READY" or (queued and "QUEUED" or "WAIT")
                status(("%s%s  %.1f studs  P%d  %.1f deg"):format(tag, s.jumpShot and " JUMP SHOT" or "", s.dist, s.power, s.pitch), ready)
            end
        end
      end)
        if not okStep then
            -- one bad frame (e.g. the ball changed hands mid-frame) must not kill the script
            S.lastError = tostring(stepErr)
            pcall(stopGuard)
        end
        task.wait(1/60)
    end
    stopGuard()
    if hudText then hudText:Remove() end
end)

-- menu (jdui). Hotkeys work even if it fails to load.
local okUi, err = pcall(function()
    ui = loadstring(game:HttpGet("https://raw.githubusercontent.com/jdev-studio/jdui/refs/heads/main/JDUI"))() or _G.JDUI
    assert(ui, "jdui returned nothing")
    S.ui = ui
    pcall(function() ui:SetTitle("Green") end)

    local tab = ui:AddTab({ Title = "Green", Icon = "bolt" })
    lockToggle = tab:AddToggle({ Title = "Aim lock", Default = false, Save = false,
        Callback = function(on) setLocked(on, true) end })
    tab:AddKeybind({ Title = "Lock key", Default = LOCK_KEY, Flag = "lockKey",
        Callback = function(vk) LOCK_KEY = vk end })
    tab:AddKeybind({ Title = "Shoot key", Default = SHOOT_KEY, Flag = "shootKey",
        Callback = function(vk) SHOOT_KEY = vk end })
    tab:AddToggle({ Title = "Jump shots (50-72 studs)", Default = true, Flag = "jumpShots",
        Callback = function(on) JUMP_SHOTS = on end })
    tab:AddToggle({ Title = "Ball switch (away from defender)", Default = false, Flag = "ballSwitch",
        Callback = function(on) BALL_SWITCH = on end })
    guardToggle = tab:AddToggle({ Title = "Auto guard (follow opponent with the ball)", Default = false, Save = false,
        Callback = function(on) setGuard(on, true) end })
    tab:AddKeybind({ Title = "Guard key", Default = GUARD_KEY, Flag = "guardKey",
        Callback = function(vk) GUARD_KEY = vk end })
    statusLabel = tab:AddLabel({ Title = "Status", Description = "off", Icon = "info" })
    tab:AddButton({ Title = "Unload", ButtonText = "Unload", Callback = function()
        S.gen = S.gen + 1
        pcall(function() ui:Destroy() end)
        S.ui = nil
    end })

    -- tidy jdui's built-in pages: drop Home and its test button, Settings goes last
    pcall(function()
        for i = #ui.Tabs, 1, -1 do if ui.Tabs[i] == ui.Home then table.remove(ui.Tabs, i) end end
        local st = ui.Settings
        for i = #st.Controls, 1, -1 do if st.Controls[i].Title == "Test notification" then table.remove(st.Controls, i) end end
        for i, t in ipairs(ui.Tabs) do if t == st then table.remove(ui.Tabs, i) break end end
        table.insert(ui.Tabs, st)
    end)

    pcall(function() ui:SetConfig("green") end)
    pcall(function() ui:SetOpen(false) end)
end)
if not okUi then warn("Green: menu failed to load, hotkeys still work: " .. tostring(err)) end
