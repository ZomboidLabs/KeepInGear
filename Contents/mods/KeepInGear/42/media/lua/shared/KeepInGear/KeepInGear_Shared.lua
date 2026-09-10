-- Keep In Gear: constants and state shared by the client and server.

KeepInGear = KeepInGear or {}

-- Indices from zombie.vehicles.TransmissionNumber. Forward gears are 1..8.
KeepInGear.REVERSE = -1
KeepInGear.NEUTRAL = 0

-- Road speed below which the gearbox is left alone, km/h.
KeepInGear.STOP_THRESHOLD_KMH = 5.0

-- Engine braking: m/s^2 at REF_RPM in top gear, before the strength setting.
KeepInGear.ENGINE_BRAKE_DECEL = 1.0
KeepInGear.REF_RPM = 3000.0

-- Ceiling on any deceleration the mod applies, m/s^2.
KeepInGear.MAX_DECEL = 6.0

-- One logic tick in seconds. GameTime's multiplier corrects for the real frame rate.
KeepInGear.TICK_SECONDS = 1.0 / 60.0

-- getSpeed2D is in the physics engine's own units. Above this forward speed a car is
-- travelling where it points, so the two readings describe the same motion and their
-- ratio is the conversion. It is a property of the physics, not of a vehicle.
KeepInGear.UNIT_SAMPLE_KMH = 20.0
-- KeepInGear.unitsPerKmh is filled in at runtime by the drivetrain.

-- How far past a gear band edge the road speed must go before the gear follows, as a
-- fraction of band width.
KeepInGear.SHIFT_HYSTERESIS = 0.10

-- Drive given back to a car in second that cannot accelerate on its own, m/s^2 at full
-- grip, and the measured acceleration below which it counts as such.
KeepInGear.LOAD_ASSIST_ACCEL = 1.2
KeepInGear.LOAD_ASSIST_MIN_ACCEL = 0.8

-- Drive supplied out of a slide, m/s^2 at full grip.
KeepInGear.SPIN_RECOVERY_ACCEL = 1.5

-- Minimum share of a car's motion that must run down its own axis before either drive is
-- applied: the cosine of the slip angle.
KeepInGear.SPIN_ALIGNED = 0.7

-- Position deltas below this give no usable direction of travel.
KeepInGear.MIN_STEP = 0.0005

-- TransmissionNumber is not on LuaManager's expose whitelist, so it has no metatable and
-- its values can be neither constructed nor named. The only source is
-- BaseVehicle:getTransmissionNumberEnum(). Values are global enum constants, so one cache
-- serves every vehicle.
KeepInGear.gearCache = KeepInGear.gearCache or {}

-- True when the mod is holding a vehicle's engine speed above vanilla. Vanilla puts the
-- box in neutral whenever the accelerator is up, so a gear engaged with no throttle is the
-- mod's signature.
--
-- Inferred rather than flagged so the server reaches the same answer: the gear and the
-- engine speed travel in the physics packet, client state does not.
--
-- VirtualVehicle is handed to the same part updates and has no isRegulator.
function KeepInGear.isHoldingRevs(vehicle)
    if vehicle:getTransmissionNumber() == KeepInGear.NEUTRAL then return false end
    if vehicle:isGasPedalPressed() then return false end
    if not vehicle:isEngineRunning() then return false end
    if vehicle.isRegulator and vehicle:isRegulator() then return false end
    return true
end

-- Read fresh each call: SandboxVars is not populated when this file loads. Both fall back
-- to the default when the table is absent, as in the main menu or in a world created
-- before the mod was added.
function KeepInGear.engineBrakingEnabled()
    local vars = SandboxVars.KeepInGear
    if not vars then return true end
    return vars.EngineBraking ~= false
end

-- Stored as a percentage, used as a multiplier.
function KeepInGear.engineBrakingStrength()
    local vars = SandboxVars.KeepInGear
    if not vars or not vars.EngineBrakingStrength then return 1.0 end
    return vars.EngineBrakingStrength / 100.0
end
