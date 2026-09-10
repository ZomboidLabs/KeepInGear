-- Keep In Gear: keeps fuel use while coasting at vanilla levels.
--
-- Vehicles.Update.GasTank bills in direct proportion to engine speed and scales by gear
-- number through speedToNextTransmission. Vanilla coasts in neutral at idle, so a held
-- gear at held revs would charge several times as much. The vehicle is shown to the
-- original function as vanilla would have left it and restored immediately after.

KeepInGear = KeepInGear or {}

local function installFuelWrapper()
    if not Vehicles or not Vehicles.Update or not Vehicles.Update.GasTank then return end

    -- The true original is kept globally so a reload re-wraps it rather than wrapping the
    -- existing wrapper.
    local original = KeepInGear.gasTankOriginal or Vehicles.Update.GasTank
    KeepInGear.gasTankOriginal = original

    Vehicles.Update.GasTank = function(vehicle, part, elapsedMinutes)
        -- Part updates also arrive for VirtualVehicle, which carries the gear and the
        -- engine speed but neither setter.
        if not vehicle.setEngineSpeed or not vehicle.changeTransmission then
            return original(vehicle, part, elapsedMinutes)
        end
        if not KeepInGear.isHoldingRevs(vehicle) then
            return original(vehicle, part, elapsedMinutes)
        end

        local script = vehicle:getScript()
        if not script then return original(vehicle, part, elapsedMinutes) end

        local neutral = KeepInGear.gearCache[KeepInGear.NEUTRAL]
        local rpm = vehicle:getEngineSpeed()
        local gear = vehicle:getTransmissionNumberEnum()

        vehicle:setEngineSpeed(script:getEngineIdleSpeed())
        if neutral then vehicle:changeTransmission(neutral) end

        original(vehicle, part, elapsedMinutes)

        vehicle:setEngineSpeed(rpm)
        if neutral then vehicle:changeTransmission(gear) end
    end
end

-- Vehicles.lua may not have been read yet on a cold start, hence the boot event; on a
-- reload that event has already fired, hence the direct call. Either order is safe.
Events.OnGameBoot.Add(installFuelWrapper)
installFuelWrapper()
