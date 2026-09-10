-- Keep In Gear: pins the gearbox to the gear the road speed calls for.
--
-- Runs on OnTick, which IngameState.updateInternal() fires after IsoWorld.update() and so
-- after CarController. OnPlayerUpdate fires before the vehicle physics and any correction
-- made there is overwritten in the same frame.

local MAX_LOCAL_PLAYERS = 4

-- Keyed by local player number: only a driven vehicle is corrected, so there are at most
-- four entries and none need reaping.
local tracked = {}

local function trackerFor(playerNum, vehicleId)
    local t = tracked[playerNum]
    if not t or t.vehicleId ~= vehicleId then
        t = { vehicleId = vehicleId }
        tracked[playerNum] = t
    end
    return t
end

-- Tyre grip, 0..1. The game's own skid sound is 1 minus this.
local function gripOf(vehicle)
    local grip = vehicle:getMinWheelSkid()
    if grip < 0 then return 0 end
    if grip > 1 then return 1 end
    return grip
end

-- Horizontal speed in km/h, direction-independent. nil until sampleSpeedUnits has run.
local function groundSpeedKmh(vehicle)
    local ratio = KeepInGear.unitsPerKmh
    if not ratio or ratio <= 0 then return nil end
    return vehicle:getSpeed2D() / ratio
end

-- getCurrentSpeedKmHour counts only travel along the car's own axis, so a car sliding
-- sideways reads as nearly stopped. The larger of the two readings keeps the gear band
-- correct through a slide and is identical in a straight line.
local function bandSpeed(vehicle, absSpeed)
    local ground = groundSpeedKmh(vehicle)
    if ground and ground > absSpeed then return ground end
    return absSpeed
end

-- Cosine of the slip angle. Every impulse the mod applies is aimed along the direction of
-- travel, which coincides with the car's own axis only while this is high.
local function alignedWithTravel(vehicle, absSpeed)
    local ground = groundSpeedKmh(vehicle)
    if not ground or ground <= 0 then return true end
    return (absSpeed / ground) >= KeepInGear.SPIN_ALIGNED
end

-- Gear for the given road speed, with hysteresis in both directions so a speed sitting on
-- a band edge does not flip the gear every tick.
local function targetGear(vehicle, speed, currentGear)
    local script = vehicle:getScript()
    if not script then return nil end

    local count = script:getGearRatioCount()
    local maxSpeed = vehicle:getMaxSpeed()
    if count < 1 or maxSpeed <= 0 then return nil end

    local perGear = maxSpeed / count
    local clamped = speed
    if clamped < 0 then clamped = 0 end
    if clamped > maxSpeed then clamped = maxSpeed end

    local raw = math.floor(clamped / perGear) + 1
    if raw > count then raw = count end

    if not currentGear or currentGear < 1 or currentGear > count then return raw, count end
    if raw == currentGear then return currentGear, count end

    if raw > currentGear then
        if clamped < (currentGear + KeepInGear.SHIFT_HYSTERESIS) * perGear then
            return currentGear, count
        end
    else
        if clamped > (currentGear - 1 - KeepInGear.SHIFT_HYSTERESIS) * perGear then
            return currentGear, count
        end
    end
    return raw, count
end

-- control_ForwardNew shifts straight to the gear matching road speed rather than stepping
-- through, so a gear may never have been occupied and its value never seen. Falls back to
-- the nearest cached gear, preferring the lower of two equally close.
local function nearestCachedGear(gear, gearCount)
    local cache = KeepInGear.gearCache
    if cache[gear] then return cache[gear], gear end

    for distance = 1, gearCount do
        local lower = gear - distance
        if lower >= 1 and cache[lower] then return cache[lower], lower end

        local higher = gear + distance
        if higher <= gearCount and cache[higher] then return cache[higher], higher end
    end
    return nil
end

-- Neutral is the only state control_ForwardNew mints a gear from, so handing the box back
-- for one frame is how an unseen value enters the cache.
--
-- The reverse clause covers R left over from before the car crossed zero:
-- control_ForwardNew changes gear only from N or upward and reverse sits below every
-- forward gear. It keys off the direction of travel because isGasPedalPressed is
-- isGas or isGasR, which is true throughout ordinary reversing.
local function shouldReleaseToNeutral(vehicle, t, speed, absSpeed)
    if t.heldGear == KeepInGear.REVERSE then return speed >= 0 end
    if not vehicle:isGasPedalPressed() then return false end

    local target = targetGear(vehicle, bandSpeed(vehicle, absSpeed), t.heldGear)
    return target ~= nil and KeepInGear.gearCache[target] == nil
end

-- Revs follow road speed at the ratio observed when the driver last lifted off. A gear's
-- top speed is proportional to its index in the game's model, so a downshift scales the
-- ratio by the same factor.
local function coastRpm(t, gear, absSpeed, idleSpeed)
    if not t.revsPerKmh or not t.revsGear then return nil end

    if gear > 0 and t.revsGear > 0 then
        if gear ~= t.revsGear then
            t.revsPerKmh = t.revsPerKmh * (t.revsGear / gear)
            t.revsGear = gear
        end
    elseif gear ~= t.revsGear then
        -- Direction reversed since the ratio was sampled; wait for a fresh one.
        return nil
    end

    local rpm = t.revsPerKmh * absSpeed
    if rpm < idleSpeed then rpm = idleSpeed end
    return rpm
end

-- CarController.brakingForce is unreachable from Lua: it is computed and passed to
-- Bullet.controlVehicle inside one method. Impulses are the only lever. Direction comes
-- from the step the vehicle took last tick, which accounts for a slide. Positive decel
-- slows the car, negative pushes it along.
local function pushAgainstTravel(vehicle, t, decel)
    if not t.prevX then return end

    local x, y = vehicle:getX(), vehicle:getY()
    local dx, dy = x - t.prevX, y - t.prevY
    if math.sqrt(dx * dx + dy * dy) < KeepInGear.MIN_STEP then return end

    if decel > KeepInGear.MAX_DECEL then decel = KeepInGear.MAX_DECEL end
    if decel < -KeepInGear.MAX_DECEL then decel = -KeepInGear.MAX_DECEL end
    if decel == 0 then return end

    local mult = getGameTime():getMultiplier() / 0.8
    local magnitude = vehicle:getMass() * decel * KeepInGear.TICK_SECONDS * mult

    -- applyImpulseGeneric normalises the direction itself. Taking the origin at the
    -- vehicle's own position leaves relPos zero, so the impulse carries no torque.
    vehicle:applyImpulseGeneric(x, y, vehicle:getZ(), -dx, -dy, 0.0, magnitude)
end

-- Scaled by grip because the impulse acts on the body directly, bypassing the wheels, and
-- withheld across a slide because a push along travel is then a push across the car.
local function applyEngineBraking(vehicle, t, gear, gearCount, rpm, absSpeed)
    if not KeepInGear.engineBrakingEnabled() then return end
    if not alignedWithTravel(vehicle, absSpeed) then return end

    local grip = gripOf(vehicle)
    if grip <= 0 then return end

    -- Engine drag grows with revs and a low gear multiplies it at the wheels. Reverse is
    -- geared much like first.
    local gearFactor = gearCount / (gear > 0 and gear or 1)
    local decel = KeepInGear.ENGINE_BRAKE_DECEL
                * (rpm / KeepInGear.REF_RPM)
                * gearFactor
                * KeepInGear.engineBrakingStrength()
                * grip
    if decel <= 0 then return end

    pushAgainstTravel(vehicle, t, decel)
end

-- Second gear only. First carries a x1.5 engine power multiplier that no other gear has,
-- and pinning the gear to road speed gives it up without the run-up vanilla's rev-gated
-- shift would have built. Applies only while the car fails to accelerate on its own, so a
-- car that can pull never receives it.
local function applyLoadAssist(vehicle, t, gear, speed)
    if gear ~= 2 or not t.prevSpeed then return end

    local dt = KeepInGear.TICK_SECONDS * (getGameTime():getMultiplier() / 0.8)
    if dt <= 0 then return end
    if ((speed - t.prevSpeed) / 3.6) / dt >= KeepInGear.LOAD_ASSIST_MIN_ACCEL then return end

    local grip = gripOf(vehicle)
    if grip <= 0 then return end

    pushAgainstTravel(vehicle, t, -KeepInGear.LOAD_ASSIST_ACCEL * grip)
end

-- The game reads the accelerator as a brake while the car travels backwards along its own
-- axis: if (forward) { if (speed < 0) isBreak = true; ... }. The key is therefore read
-- directly. Against-travel stands in for forwards only once the car has come round, hence
-- the alignment gate. Joypads are not visible this way.
local function applySpinRecovery(vehicle, t, speed)
    if speed >= 0 then return end
    if not vehicle:isKeyboardControlled() then return end
    if not GameKeyboard.isKeyDown("Forward") then return end
    if not alignedWithTravel(vehicle, math.abs(speed)) then return end

    local grip = gripOf(vehicle)
    if grip <= 0 then return end

    pushAgainstTravel(vehicle, t, KeepInGear.SPIN_RECOVERY_ACCEL * grip)
end

-- At speed in a straight line getSpeed2D and getCurrentSpeedKmHour describe the same
-- motion, so their ratio converts the physics engine's units to km/h.
local function sampleSpeedUnits(vehicle, absSpeed)
    if absSpeed < KeepInGear.UNIT_SAMPLE_KMH then return end

    local units = vehicle:getSpeed2D()
    if units > 0 then KeepInGear.unitsPerKmh = units / absSpeed end
end

-- Still moving with almost no forward speed to show for it: a slide. Re-asserts the gear
-- and leaves the revs to the game, since the wheels are not turning at road speed.
local function holdGearThroughSlide(vehicle, t)
    if not t.heldGear then return false end

    local ground = groundSpeedKmh(vehicle)
    if not ground or ground < KeepInGear.STOP_THRESHOLD_KMH then return false end

    local value = KeepInGear.gearCache[t.heldGear]
    if not value then return false end

    vehicle:changeTransmission(value)
    return true
end

-- Returns the gear index set, or nil if none could be.
local function correct(vehicle, t, speed, absSpeed, underPower)
    local script = vehicle:getScript()
    if not script then return nil end

    local wanted, gearCount
    if t.reversing then
        -- Pressing forward against a reverse roll sets isBreak, not isGas, and
        -- control_ForwardNew cannot climb out of R. Declining is enough: control_Braking
        -- puts the box in neutral every tick.
        if vehicle:isBrakePedalPressed() then return nil end
        wanted, gearCount = KeepInGear.REVERSE, script:getGearRatioCount()
    else
        wanted, gearCount = targetGear(vehicle, bandSpeed(vehicle, absSpeed), t.heldGear)
    end
    if not wanted then return nil end

    -- Revs and impulses use the gear road speed calls for, not the one the cache could
    -- supply, so a gap in the cache is only ever a wrong letter on the dash.
    local gearValue, shown
    if wanted == KeepInGear.REVERSE then
        gearValue, shown = KeepInGear.gearCache[wanted], wanted
    else
        gearValue, shown = nearestCachedGear(wanted, gearCount)
    end
    if not gearValue then return nil end

    vehicle:changeTransmission(gearValue)

    if underPower then
        -- The game owns the revs here. Sample the ratio so a lift-off continues from it.
        if absSpeed > 1.0 then
            t.revsPerKmh = vehicle:getEngineSpeed() / absSpeed
            t.revsGear = wanted
            sampleSpeedUnits(vehicle, absSpeed)
        end
        applyLoadAssist(vehicle, t, wanted, speed)
        return shown
    end

    local rpm = coastRpm(t, wanted, absSpeed, script:getEngineIdleSpeed())
    if not rpm then return shown end

    vehicle:setEngineSpeed(rpm)
    applyEngineBraking(vehicle, t, wanted, gearCount, rpm, absSpeed)
    return shown
end

local function updateDriver(playerNum, player)
    local vehicle = player:getVehicle()
    if not vehicle or vehicle:getDriver() ~= player then
        tracked[playerNum] = nil
        return
    end

    local t = trackerFor(playerNum, vehicle:getId())
    local gearIdx = vehicle:getTransmissionNumber()

    -- Every TransmissionNumber the mod can set has to be borrowed from a vehicle as it
    -- goes past. Neutral included: the release below needs it.
    KeepInGear.gearCache[gearIdx] = vehicle:getTransmissionNumberEnum()

    local speed = vehicle:getCurrentSpeedKmHour()
    local absSpeed = math.abs(speed)

    -- Reverse is a mode the driver selects, not a direction of travel. control_Reverse is
    -- the only thing that sets R and runs only on the reverse pedal. A car spun round on
    -- the handbrake travels backwards along its own axis in a forward gear.
    if gearIdx == KeepInGear.REVERSE and vehicle:isGasPedalPressed() then
        t.reversing = true
    elseif speed >= 0 then
        t.reversing = false
    end

    if not vehicle:isEngineRunning() then
        t.heldGear = nil

    elseif absSpeed < KeepInGear.STOP_THRESHOLD_KMH then
        if not holdGearThroughSlide(vehicle, t) then t.heldGear = nil end

    elseif t.heldGear and shouldReleaseToNeutral(vehicle, t, speed, absSpeed) then
        local neutral = KeepInGear.gearCache[KeepInGear.NEUTRAL]
        if neutral then vehicle:changeTransmission(neutral) end
        t.heldGear = nil

    else
        -- Cruise control holds the throttle open with no pedal down, so it counts as
        -- under power.
        local underPower = vehicle:isGasPedalPressed() or vehicle:isRegulator()
        t.heldGear = correct(vehicle, t, speed, absSpeed, underPower)
    end

    if vehicle:isEngineRunning() then applySpinRecovery(vehicle, t, speed) end

    t.prevX, t.prevY = vehicle:getX(), vehicle:getY()
    t.prevSpeed = speed
end

local function onTick()
    for i = 0, MAX_LOCAL_PLAYERS - 1 do
        local player = getSpecificPlayer(i)
        if player and not player:isDead() then
            updateDriver(i, player)
        else
            tracked[i] = nil
        end
    end
end

-- reloadLuaFile() would otherwise stack a second handler on the first. The handle lives on
-- the global table so it survives the reload.
if KeepInGear.tickHandler then
    Events.OnTick.Remove(KeepInGear.tickHandler)
end
KeepInGear.tickHandler = onTick
Events.OnTick.Add(onTick)
