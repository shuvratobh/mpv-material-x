-- hold-space-speed.lua
local hold_threshold = 2.0 -- 2 seconds threshold
local speed_multiplier = 2.0
local is_speeding = false
local timer = nil
local pre_hold_speed = 1.0
local was_paused = false

local function speed_on()
    is_speeding = true
    timer = nil
    pre_hold_speed = mp.get_property_number("speed", 1) or 1.0
    was_paused = mp.get_property_bool("pause", false)
    if was_paused then
        mp.set_property_bool("pause", false)
    end
    mp.set_property_number("speed", speed_multiplier)
    mp.osd_message(string.format("▶▶ %gx (Hold to 2x)", speed_multiplier), 10)
end

local function speed_off()
    if is_speeding then
        is_speeding = false
        mp.set_property_number("speed", pre_hold_speed)
        if was_paused then
            mp.set_property_bool("pause", true)
        end
        mp.osd_message(string.format("▶ %gx", pre_hold_speed), 1)
    end
end

local function handle_space(event)
    local ev = event and event.event
    if ev == "down" then
        if timer then
            timer:kill()
            timer = nil
        end
        timer = mp.add_timeout(hold_threshold, speed_on)
    elseif ev == "repeat" then
        -- Ignore OS keyboard repeat events while holding
        return
    elseif ev == "up" then
        if timer then
            timer:kill()
            timer = nil
        end
        if is_speeding then
            speed_off()
        else
            -- Released before 2 seconds: regular pause toggle
            mp.commandv("cycle", "pause")
        end
    end
end

mp.add_forced_key_binding("SPACE", "hold_space_speedup", handle_space, {complex = true})
