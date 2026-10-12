-- Auto Shot v2 (Matcha)
-- Z = toggle lock. While locked and holding the ball it keeps power set and the
-- shift-lock camera locked on the solved aim every frame (jump-compensated).
-- Shoot with your normal MB1, or press X to let it fire for you.
-- HUD turns green (READY) when power and aim are both correct.

local TOGGLE_KEY = 0x5A   -- Z
local SHOOT_KEY  = 0x58   -- X
local HOLD       = 0.35
local MAXRANGE   = 70
local LONG_SHOT  = 65.5   -- beyond standing range, X takes a jump shot

local lp  = game.Players.LocalPlayer
local cam = workspace.CurrentCamera

-- verified standing makes (shift lock): {distance, power, pitch}
local TABLE = {
    {10, 35, 57.5}, {15, 40, 62.85}, {20, 50, 63.74}, {25, 60, 68.42},
    {30, 65, 63.40}, {35, 75, 67.03}, {40, 80, 66.19}, {45, 85, 64.58},
    {50, 85, 60.79}, {55, 85, 58.13}, {58, 85, 55.90}, {60, 85, 54.37},
    {61, 85, 52.90}, {63, 85, 50.45}, {65, 85, 44.00},
}
local SLOPE = {[35]=-0.3, [40]=-0.47, [50]=-0.6, [60]=-1.5, [65]=-1.9, [75]=-1.1, [80]=-1.27, [85]=-0.75}

-- ball physics (measured): v = K*power*cameraDir + (0, C, 0), gravity 196.2,
-- launch H0 above standing root, calibration rim height RIM_REL above standing root
local G, K, C, H0, RIM_REL = 196.2, 1.08, 40.5, 2.0, 10.5
local LAG_EXTRA = 0.10      -- server launches from where it saw you ~ping+0.10s ago
local PX_YAW, PX_PITCH = 21.3, 23.7

local function wrap(a) a = a % 360 if a > 180 then a = a - 360 end return a end
local function camPitch() local l = cam.CFrame.LookVector return math.deg(math.asin(l.Y)) end
local function camYaw()   local l = cam.CFrame.LookVector return math.deg(math.atan2(-l.X, -l.Z)) end
local function hrp() return lp.Character and lp.Character:FindFirstChild("HumanoidRootPart") end
local function held() local c = lp.Character return c and c:FindFirstChild("Basketball") end

-- hoops
local GOALS = {}
local function scan(root)
    if not root then return end
    for _, d in ipairs(root:GetDescendants()) do
        if (d.Name == "Goal" or d.Name == "GoalHome" or d.Name == "GoalAway") and d.ClassName == "Part" then
            table.insert(GOALS, d.Position)
        end
    end
end
scan(workspace:FindFirstChild("Courts"))
scan(workspace:FindFirstChild("PracticeArea"))

local function nearestGoal(p)
    local best, bd
    for _, gp in ipairs(GOALS) do
        local dx, dz = gp.X - p.X, gp.Z - p.Z
        local d = math.sqrt(dx*dx + dz*dz)
        if not bd or d < bd then best, bd = gp, d end
    end
    return best, bd
end

-- standing table -> (power, pitch)
local function solveTable(d)
    for i = 1, #TABLE - 1 do
        local a, b = TABLE[i], TABLE[i+1]
        if d >= a[1] and d <= b[1] and a[2] == b[2] then
            local f = (d - a[1]) / (b[1] - a[1])
            return a[2], a[3] + (b[3] - a[3]) * f
        end
    end
    local best, bd
    for _, e in ipairs(TABLE) do
        if not bd or math.abs(e[1] - d) < bd then best, bd = e, math.abs(e[1] - d) end
    end
    return best[2], math.clamp(best[3] + (d - best[1]) / (SLOPE[best[2]] or -1), 15, 80)
end

-- model range at rim height for a launch dh higher than standing
local function modelRange(p, pitch, dh)
    local a = math.rad(pitch)
    local vh, vy = K*p*math.cos(a), K*p*math.sin(a) + C
    local disc = vy*vy - 2*G*(RIM_REL - H0 - dh)
    if disc < 0 then return nil end
    return vh * (vy + math.sqrt(disc)) / G
end

-- keep the table's real range, correct only for the height change
local function adjustPitch(p, pitch, dh)
    if math.abs(dh) < 0.05 then return pitch end
    local want = modelRange(p, pitch, 0)
    if not want then return pitch end
    local lo, hi
    if dh > 0 then lo, hi = pitch, 85 else lo, hi = math.max(pitch - 25, 10), pitch end
    for _ = 1, 30 do
        local mid = (lo + hi) / 2
        local r = modelRange(p, mid, dh) or 0
        -- descending branch: more pitch = shorter
        if r > want then lo = mid else hi = mid end
    end
    return (lo + hi) / 2
end

-- ping from the game's own label
local function lagSeconds()
    local ms = 80
    pcall(function()
        local t = lp.PlayerGui.TopbarInsets.PING.PingLabel.Text
        ms = tonumber(t:match("(%d+)")) or ms
    end)
    return ms / 1000 + LAG_EXTRA
end

-- root position history (for lag compensation)
local hist, groundY, still = {}, nil, 0
local function record()
    local r = hrp() if not r then return end
    local now = os.clock()
    local p = r.Position
    table.insert(hist, {now, p})
    while #hist > 0 and now - hist[1][1] > 1 do table.remove(hist, 1) end
    -- grounded = vertical speed ~0 for ~0.1s (a jump's apex only touches 0 for a frame)
    if math.abs(r.AssemblyLinearVelocity.Y) < 0.6 then still = still + 1 else still = 0 end
    if still >= 6 then groundY = p.Y end
end
local function posAgo(dt)
    local target = os.clock() - dt
    for i = #hist, 1, -1 do if hist[i][1] <= target then return hist[i][2] end end
    return hist[1] and hist[1][2]
end

-- power stepping runs in the background so the camera lock never stalls
local powerBusy = false
local function nudgePower(target)
    if powerBusy or lp:GetAttribute("Power") == target then return end
    powerBusy = true
    task.spawn(function()
        local cur = lp:GetAttribute("Power")
        local k = cur < target and 0x45 or 0x51 -- E / Q
        keypress(k) task.wait(0.05) keyrelease(k) task.wait(0.22)
        powerBusy = false
    end)
end

local function shiftLockOn()
    local function check()
        mousemoverel(40, 0) task.wait(0.25)
        local l = hrp().CFrame.LookVector
        return math.abs(wrap(math.deg(math.atan2(-l.X, -l.Z)) - camYaw())) < 3
    end
    if check() then return true end
    keypress(0xA0) task.wait(0.05) keyrelease(0xA0) task.wait(0.3)
    return check()
end

-- HUD
local label
pcall(function()
    label = Drawing.new("Text")
    label.Size = 18 label.Outline = true label.Center = true
    label.Position = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y * 0.72)
    label.Visible = true
end)
local function hud(t, ready)
    _G.AUTOSHOT_STATUS = t
    if label then
        label.Text = t
        label.Color = ready and Color3.fromRGB(80, 255, 120) or Color3.fromRGB(255, 120, 90)
    end
end

local locked, firing = false, false
local cur = {}   -- current solution
_G.AUTOSHOT_SOLUTION = cur

local function solveNow()
    local r = hrp() if not r then return nil end
    local lp_ = posAgo(lagSeconds()) or r.Position
    local goal, dist = nearestGoal(lp_)
    if not goal then return nil, "no hoop" end
    if dist > MAXRANGE then return nil, ("too far %.0f"):format(dist) end
    local gy = groundY or r.Position.Y
    -- height above ground the server will launch from + rim height difference vs calibration
    local dh = (lp_.Y - gy) + (RIM_REL - (goal.Y - gy))
    local p, pitch = solveTable(dist)
    pitch = adjustPitch(p, pitch, dh)
    cur.goal, cur.dist, cur.power, cur.pitch, cur.dh = goal, dist, p, pitch, dh
    return cur
end

local function aimStep(gain)
    local r = hrp()
    local p = r.Position
    local ty = math.deg(math.atan2(-(cur.goal.X - p.X), -(cur.goal.Z - p.Z)))
    local ep, ey = cur.pitch - camPitch(), wrap(ty - camYaw())
    if math.abs(ep) > 0.15 or math.abs(ey) > 0.2 then
        mousemoverel(math.floor(-ey * PX_YAW * gain + 0.5), math.floor(-ep * PX_PITCH * gain + 0.5))
    end
    return ep, ey
end

local function fire()
    if firing or not locked or not held() or not cur.goal then return end
    firing = true
    -- long shots: jump and release near the top (server-side) for extra range
    if cur.dist > LONG_SHOT and (cur.dh or 0) < 1 then
        keypress(0x20) task.wait(0.04) keyrelease(0x20)
        local t, best = os.clock(), -1
        while os.clock() - t < 0.6 do
            task.wait(1/60)
            local dh = cur.dh or 0
            if dh >= 6.5 or (best > 5 and dh < best - 0.1) then break end
            if dh > best then best = dh end
        end
    end
    local t0 = os.clock()
    mouse1press()
    while os.clock() - t0 < HOLD do task.wait(1/60) end
    mouse1release()
    firing = false
end
_G.autoshotFire = fire

_G.AUTOSHOT_GEN = (_G.AUTOSHOT_GEN or 0) + 1
local gen = _G.AUTOSHOT_GEN

-- main loop
task.spawn(function()
    local zWas, xWas = false, false
    while _G.AUTOSHOT_GEN == gen do
        record()
        local active = isrbxactive()
        local z, x = iskeypressed(TOGGLE_KEY), iskeypressed(SHOOT_KEY)
        if active and z and not zWas then
            locked = not locked
            if locked then task.spawn(shiftLockOn) end
        end
        if active and x and not xWas then task.spawn(fire) end
        zWas, xWas = z, x

        if not locked then
            hud("auto shot OFF (Z)", false)
        elseif not held() then
            hud("auto shot ON - no ball", false)
        else
            local s, why = solveNow()
            if not s then
                hud("auto shot ON - " .. tostring(why), false)
            else
                if active then
                    nudgePower(s.power)
                    local ep, ey = aimStep(0.5)
                    local ready = lp:GetAttribute("Power") == s.power and math.abs(ep) < 0.4 and math.abs(ey) < 0.5
                    hud(("%s  %.1f studs  P%d  %.1f°  jump+%.1f"):format(ready and "READY" or "WAIT", s.dist, s.power, s.pitch, s.dh), ready)
                end
            end
        end
        task.wait(1/60)
    end
    if label then label:Remove() end
end)
_G.autoshotToggle = function(v) locked = v if v then task.spawn(shiftLockOn) end end
print("auto shot v2 loaded, hoops:", #GOALS)
