-- notify_skip.lua
-- Simplified intro/outro skipping with chapter priority and silence detection fallback
-- Streamlined to two-mode system

package.path = package.path .. ';portable_config/scripts/?.lua;'

-- Set up package path for button infrastructure
local script_dir = debug.getinfo(1, 'S').source:match('@(.*/)') or './'
package.path = script_dir .. '?.lua;' .. package.path

-- Initialize button infrastructure globals first
config = {
	opacity = {tooltip = 1, controls = 0},
	refine = {},
	font = 'Google Sans Flex',
}
options = {
	controls_size = 32,
	controls_margin = 8,
	text_border = 1.2,
	font_bold = false,
	flash_duration = 1000,
	animation_duration = 100,
}
fg = 'FFFFFF'
bg = '000000'
display = {width = 1920, height = 1080, initialized = false}

-- Initialize button infrastructure state
button_state = {
	render_timer = nil,
	render_last_time = 0,
	render_delay = 1/60,
	platform = 'windows',
	scale = 1,
	radius = 4,
	hidpi_scale = 1,
	fullormaxed = false,
	fullscreen = false,
	maximized = false,
}

-- Set global state for button infrastructure compatibility
state = button_state

-- Load button infrastructure
assdraw = require('mp.assdraw')
opt = require('mp.options')
utils = require('mp.utils')
msg = require('mp.msg')
osd = mp.create_osd_overlay('ass-events')
require('lib/std')
require('lib/ass')
require('lib/utils')
Elements = require('elements/Elements')
local mp = require 'mp'
local options = require 'mp.options'

local opts = {
    auto_skip = false,
    skip_categories = "opening;ending;preview;recap",
    blackdetect_notify_args = "d=0.25:pic_th=0.98",
    blackdetect_skip_args = "d=0.35:pic_th=0.92:pix_th=0.10",
    silencedetect_notify_args = "n=-52dB:d=1.6",
    silencedetect_skip_args = "n=-35dB:d=0.8",
    show_notification = true,
    notification_duration = 30,
    filters_notification_duration = 12,
    min_skip_duration = 10,  -- Minimum duration to consider as valid skip exit (seconds)
    intro_time_window = 420,
    outro_time_window = 420,
    opening_patterns = "^OP$|^OP[0-9]+$|^Opening|Opening$|^Intro|Intro$|^Introduction$|^Theme Song$|^Main Theme$|^Title Sequence$|^Cold Open$|^Teaser$",
    ending_patterns = "^ED$|^ED[0-9]+$|^Ending|Ending$|^Outro|Outro$|^End Credits$|^Credits$|^Closing|Closing$|^Epilogue$|^End Theme$|^Closing Theme$",
    preview_patterns = "Preview|Next Episode|^Next Time|^Coming Up|^Next Week|^Trailer$",
    recap_patterns = "^Recap$|^Previously|Previously$|^Last Time|Last Time$|^Summary$|^Story So Far$"
}
options.read_options(opts, "notify_skip")

-- Initialize the skip notification button
local SkipNotificationButton = require('elements/SkipNotificationButton')
local skip_button = SkipNotificationButton:new()

-- State management
local state = {
    mode = "none", -- "chapter" or "silence"
    silence_active = false,
    blackframe_skip_active = false,
    skip_start_time = 0,
    intro_skipped = false,
    
    detection = {
        notification_active = false,
        skipping_active = false
    },

    ui = {
        overlay = nil,
        overlay_timer = nil,
        skip_suppression_timer = nil,
        active_chapter_index = nil,
        click_bound = false,
    },

    observers = {
        blackdetect_notify = nil,
        silencedetect_notify = nil,
        silencedetect_skip = nil,
        blackdetect_skip = nil
    },

    cache = {
        skippable_chapters = nil
    },
    last_black_start = nil,
    black_segment_detected = false,
    detected_skip_end = nil
}

-- Constants
local max_speed = 100
local normal_speed = 1
local skip_suppression_duration = 5
local intro_threshold = 60

-- Utility functions
function set_time(time) mp.set_property_number('time-pos', time) end
function get_time() return mp.get_property_native('time-pos') or 0 end
function set_speed(speed) mp.set_property('speed', speed) end
function set_pause(state) mp.set_property_bool('pause', state) end
function set_mute(state) mp.set_property_bool('mute', state) end

-- Chapter detection functions
function matches_chapter_pattern(title, category)
    local pattern_string = opts[category .. '_patterns']
    if not title or not pattern_string then return false end
    for pattern in string.gmatch(pattern_string, "([^|]+)") do
        if string.match(title, pattern) then return true end
    end
    return false
end

function calculate_chapter_duration(chapters, index)
    if index < #chapters then
        return chapters[index + 1].time - chapters[index].time
    else
        local duration = mp.get_property_native("duration")
        if duration then return duration - chapters[index].time end
    end
    return 0
end

function find_skip_chapters()
    local chapters = mp.get_property_native("chapter-list")
    if not chapters or #chapters == 0 then return {} end

    local titled_skip_chapters = {}
    local positional_skip_chapters = {}
    local categories = {}
    for category in string.gmatch(opts.skip_categories, "([^;]+)") do
        categories[category:lower():gsub("%s+", "")] = true
    end

    local total_dur = mp.get_property_native("duration") or 0
    for i = 1, #chapters do
        local chapter = chapters[i]
        local duration = calculate_chapter_duration(chapters, i)
        local has_titled_match = false
        local is_outro_pos = (total_dur > 0 and chapter.time >= (total_dur - opts.outro_time_window)) or (i >= #chapters - 1 and i > 2)

        -- Allow titled chapters up to intro/outro window bounds
        if duration > 0 and duration <= math.max(opts.intro_time_window, opts.outro_time_window) then
            -- Check for titled chapters first
            for category_name, _ in pairs(categories) do
                if matches_chapter_pattern(chapter.title, category_name) then
                    table.insert(titled_skip_chapters, {
                        index = i, time = chapter.time, title = chapter.title,
                        category = category_name, duration = duration, titled = true,
                    })
                    has_titled_match = true
                    break
                end
            end

            -- Positional fallback ONLY for untitled chapters when no titled match:
            -- Allows 2-5 min prologue in Chapter 1 followed by 15-150s Opening Theme in Chapter 2,
            -- and short End Credits / Title Card chapters inside outro_time_window.
            if not has_titled_match then
                local is_generic = not chapter.title or chapter.title == "" or chapter.title:match("^Chapter%s*%d+$") or chapter.title:match("^%d%d:%d%d")
                if is_generic then
                    if i == 2 and chapter.time >= 10 and chapter.time <= opts.intro_time_window and duration >= 15 and duration <= 150 then
                        if categories["opening"] then
                            table.insert(positional_skip_chapters, {
                                index = i, time = chapter.time, title = chapter.title or ("Chapter " .. i),
                                category = "opening", duration = duration, titled = false,
                            })
                        end
                    elseif i == 1 and chapter.time < 5 and duration >= 20 and duration <= 130 then
                        local next_dur = (#chapters >= 2) and calculate_chapter_duration(chapters, 2) or 999
                        if next_dur > 150 and categories["opening"] then
                            table.insert(positional_skip_chapters, {
                                index = i, time = chapter.time, title = chapter.title or ("Chapter " .. i),
                                category = "opening", duration = duration, titled = false,
                            })
                        end
                    elseif is_outro_pos and duration >= 10 and duration <= 240 then
                        if categories["ending"] then
                            table.insert(positional_skip_chapters, {
                                index = i, time = chapter.time, title = chapter.title or ("Chapter " .. i),
                                category = "ending", duration = duration, titled = false,
                            })
                        end
                    end
                end
            end
        end
    end

    -- Prioritize titled chapters over positional ones
    if #titled_skip_chapters > 0 then
        return titled_skip_chapters
    else
        return positional_skip_chapters
    end
end

-- Filter management functions
function init_filter(property, label, name, params)
    local filters = mp.get_property_native(property) or {}
    local exists = false
    for _, f in ipairs(filters) do
        if f.label == label then
            exists = true
            break
        end
    end
    if not exists then
        local filter_string = "@" .. label .. ":" .. name
        if params and params.graph then
            filter_string = filter_string .. "=[" .. params.graph .. "]"
        end
        mp.commandv(property, "add", filter_string)
    end
end

function set_filter_state(property, label, is_enabled)
    local filters = mp.get_property_native(property) or {}
    for i = #filters, 1, -1 do
        if filters[i].label == label then
            if filters[i].enabled ~= is_enabled then
                filters[i].enabled = is_enabled
                mp.set_property_native(property, filters)
            end
            return
        end
    end
end

function init_notification_filters()
    init_filter('vf', 'blackdetect_notify', 'lavfi', { graph = 'blackdetect=' .. opts.blackdetect_notify_args })
    mp.msg.info("blackdetect_notify initialized")
    init_filter('af', 'silencedetect_notify', 'lavfi', { graph = 'silencedetect=' .. opts.silencedetect_notify_args })
    mp.msg.info("silencedetect_notify initialized")
end

function init_skipping_filters()
    init_filter('af', 'silencedetect_skip', 'lavfi', { graph = 'silencedetect=' .. opts.silencedetect_skip_args })
    mp.msg.info("silencedetect_skip initialized")
    init_filter('vf', 'blackdetect_skip', 'lavfi', { graph = 'blackdetect=' .. opts.blackdetect_skip_args })
    mp.msg.info("blackdetect_skip initialized")

    -- Disable skip filters by default
    set_filter_state('af', 'silencedetect_skip', false)
    set_filter_state('vf', 'blackdetect_skip', false)
end

-- Notification detection functions
function notification_trigger(name, value, source)
    if not state.detection.notification_active or not value or value == '{}' then return end
    if not string.match(value, 'lavfi%.black_start') and not string.match(value, 'lavfi%.silence_start') then return end
    if state.ui.skip_suppression_timer or state.intro_skipped or state.silence_active then return end
    if skip_button.min_visibility > 0 then return end

    local current_time = get_time()
    local duration = mp.get_property_native("duration") or 0
    local message = ""

    -- Skip initial t < 4s black fade-in so cold opens don't false-trigger at 00:00
    if current_time >= 4 and current_time <= opts.intro_time_window then
        message = "Skip Opening"
    elseif duration > 0 and current_time >= (duration - opts.outro_time_window) then
        message = "Skip Ending"
    end

    if message ~= "" then
        mp.msg.info("Notification trigger from '" .. source .. "' at " .. current_time .. "s")
        local current_chapter_idx = mp.get_property_native("chapter")
        show_skip_overlay(message, opts.filters_notification_duration, true, current_chapter_idx and (current_chapter_idx + 1) or nil)
        start_skip_suppression()
    end
end

-- Skip detection functions for silence mode
function skip_detection_trigger(name, value, source)
    if not state.detection.skipping_active or not value or value == '{}' then return end
    
    local current_time = get_time()
    local event_data = {}
    local skip_time = nil -- Explicitly declare skip_time
    
    -- Parse the damn events properly
    for key, val in string.gmatch(value, '"([^"]+)":"([^"]*)"') do
        event_data[key] = val
    end

    if source == "blackframe" then
        mp.msg.info("BLACKDETECT EVENT: " .. (value or "nil"))
    
        -- CRITICAL FIX: Check for black_end first and use a more reliable condition
        if event_data['lavfi.black_end'] then
            local black_end = tonumber(event_data['lavfi.black_end'])
            mp.msg.info("BLACK END DETECTED: " .. black_end)

            mp.msg.info("DEBUG: Condition check - black_end=" .. black_end .. ", skip_start_time=" .. state.skip_start_time)
    
            -- Check if this black_end is relevant to our current skip session.
            -- The key is that the end of the black scene should be after the skip started.
            if black_end > state.skip_start_time then
                skip_time = black_end
                mp.msg.info("Potential skip target: " .. skip_time)

                -- >>>>> Add your minimum duration check here <<<<<
                local potential_duration = skip_time - state.skip_start_time
                if potential_duration < opts.min_skip_duration then
                    mp.msg.info("Ignoring short " .. source .. " period of " .. potential_duration .. "s, continuing skip")
                    state.skip_start_time = skip_time -- Reset start to continue from this point
                    return -- Abort this skip, but continue the fast-forwarding
                end
                -- >>>>> End of the added block <<<<<

                mp.msg.info("SKIPPING TO BLACK END: " .. skip_time)
                state.detected_skip_end = skip_time
                stop_silence_skip()
                set_time(skip_time)
                return -- Exit immediately after acting
            end
        end
    
        -- Track black_start for debugging
        if event_data['lavfi.black_start'] then
            state.last_black_start = tonumber(event_data['lavfi.black_start'])
            mp.msg.info("Black start: " .. state.last_black_start)
        end
        
    elseif source == "silence" then
        mp.msg.info("SILENCEDETECT: " .. (value or "nil"))
        
        -- Only use silence if we haven't seen ANY black detection
        if not state.last_black_start then
            if event_data['lavfi.silence_start'] then
                local silence_start = tonumber(event_data['lavfi.silence_start'])
                if silence_start > current_time + 1 then
                    skip_time = silence_start
                    mp.msg.info("Potential silence fallback target: " .. skip_time)

                    -- >>>>> Add the SAME minimum duration check here <<<<<
                    local potential_duration = skip_time - state.skip_start_time
                    if potential_duration < opts.min_skip_duration then
                        mp.msg.info("Ignoring short " .. source .. " period of " .. potential_duration .. "s, continuing skip")
                        state.skip_start_time = skip_time
                        return
                    end
                    -- >>>>> End of the added block <<<<<

                    mp.msg.info("SILENCE FALLBACK: " .. silence_start)
                    state.detected_skip_end = silence_start
                    stop_silence_skip()
                    set_time(silence_start)
                    return
                end
            end
        else
            mp.msg.info("Ignoring silence - black detection was active")
        end
    end
end

function reset_black_detection()
    state.last_black_start = nil
    state.black_segment_detected = false
end

function start_silence_skip()
    if state.silence_active then return end

    reset_black_detection() -- Reset state before starting
    
    state.skip_start_time = get_time()
    state.silence_active = true
    state.blackframe_skip_active = true
    state.detection.skipping_active = true
    
    -- Activate skip detection filters
    set_filter_state('af', 'silencedetect_skip', true)
    set_filter_state('vf', 'blackdetect_skip', true)
    
    -- Set up observers for skip detection
    state.observers.silencedetect_skip = function(n, v) skip_detection_trigger(n, v, "silence") end
    state.observers.blackdetect_skip = function(n, v) skip_detection_trigger(n, v, "blackframe") end
    
    mp.observe_property('af-metadata/silencedetect_skip', 'string', state.observers.silencedetect_skip)
    mp.observe_property('vf-metadata/blackdetect_skip', 'string', state.observers.blackdetect_skip)
    
    set_pause(false)
    set_mute(true)
    set_speed(max_speed)
    show_skip_overlay("▷▷ Fast Forward", 0, false)
    
    mp.msg.info("Silence skip started with dual detection")
end

function stop_silence_skip()
    if not state.silence_active and not state.blackframe_skip_active then return end
    
    -- NEW: Check if this was a substantial intro skip
    -- Use detected end time if available, otherwise fall back to current time
    local end_time = state.detected_skip_end or get_time()
    local skip_duration = end_time - state.skip_start_time
    
    mp.msg.info("DEBUG: skip_duration=" .. skip_duration .. "s, skip_start_time=" .. state.skip_start_time .. "s, end_time=" .. end_time .. "s")
    
    -- Keep dynamic detection available after a filter skip so if a prologue was skipped
    -- right before the actual opening theme music starts, Skip Opening still triggers.
    
    state.silence_active = false
    state.blackframe_skip_active = false
    state.detection.skipping_active = false
    
    -- Deactivate skip detection filters
    set_filter_state('af', 'silencedetect_skip', false)
    set_filter_state('vf', 'blackdetect_skip', false)
    
    -- Remove observers
    if state.observers.silencedetect_skip then
        mp.unobserve_property(state.observers.silencedetect_skip)
        state.observers.silencedetect_skip = nil
    end
    if state.observers.blackdetect_skip then
        mp.unobserve_property(state.observers.blackdetect_skip)
        state.observers.blackdetect_skip = nil
    end
    
    set_mute(false)
    set_speed(normal_speed)
    hide_skip_overlay()
    
    mp.msg.info("Silence skip stopped")
end

-- Notification filter management
function start_notification_filters()
    if state.detection.notification_active then return end
    state.detection.notification_active = true
    
    set_filter_state('vf', 'blackdetect_notify', true)
    set_filter_state('af', 'silencedetect_notify', true)

    state.observers.blackdetect_notify = function(n, v) notification_trigger(n, v, "blackdetect") end
    state.observers.silencedetect_notify = function(n, v) notification_trigger(n, v, "silencedetect") end
    
    mp.observe_property('vf-metadata/blackdetect_notify', 'string', state.observers.blackdetect_notify)
    mp.observe_property('af-metadata/silencedetect_notify', 'string', state.observers.silencedetect_notify)
    
    mp.msg.info("Notification detection filters started")
end

function stop_notification_filters()
    if not state.detection.notification_active then return end
    state.detection.notification_active = false
    
    set_filter_state('vf', 'blackdetect_notify', false)
    set_filter_state('af', 'silencedetect_notify', false)

    if state.observers.blackdetect_notify then
        mp.unobserve_property(state.observers.blackdetect_notify)
        state.observers.blackdetect_notify = nil
    end
    if state.observers.silencedetect_notify then
        mp.unobserve_property(state.observers.silencedetect_notify)
        state.observers.silencedetect_notify = nil
    end

    mp.msg.info("Notification detection filters stopped")
end

function update_notification_filters_state()
    local should_be_active = false
    local current_time = get_time()
    local duration = mp.get_property_native("duration") or 0
    
    -- Simplified check for time windows
    local in_intro_window = (current_time <= opts.intro_time_window)
    local in_outro_window = (duration > 0 and current_time >= (duration - opts.outro_time_window))
    
    -- NEW: Reset intro_skipped when entering outro window
    if in_outro_window and state.intro_skipped then
        state.intro_skipped = false
        mp.msg.info("Entered outro window, reset intro_skipped to allow outro notifications")
    end
    
    if in_intro_window or in_outro_window then
        should_be_active = true
    end
    
    -- Apply the decision
    if should_be_active and not state.detection.notification_active then
        start_notification_filters()
    elseif not should_be_active and state.detection.notification_active then
        stop_notification_filters()
    end
end

-- Chapter skipping functions
function skip_to_chapter_end(chapter_index)
    local chapters = mp.get_property_native("chapter-list")
    if not chapters then return false end
    
    if chapter_index < #chapters then
        set_time(chapters[chapter_index + 1].time)
    else
        local duration = mp.get_property_native("duration")
        if duration then
            -- Prevent looping by stopping slightly before the end
            set_time(duration - 1)
        end
    end
    return true
end

-- UI/Notification functions
local function update_click_binding(hovered)
    hovered = hovered and skip_button.min_visibility > 0
    skip_button:set_hovered(hovered)
    if hovered and not state.ui.click_bound then
        mp.add_forced_key_binding('MBTN_LEFT', 'notify_skip_click', perform_skip)
        state.ui.click_bound = true
    elseif not hovered and state.ui.click_bound then
        mp.remove_key_binding('notify_skip_click')
        state.ui.click_bound = false
    end
end

function on_mouse_pos(_, pos)
    if skip_button.min_visibility <= 0 then
        update_click_binding(false)
        return
    end
    local mouse = pos or mp.get_property_native('mouse-pos')
    local hovered = mouse and skip_button:hit_test(mouse.x, mouse.y) or false
    update_click_binding(hovered)
end

function hide_skip_overlay()
    if state.ui.overlay_timer then
        state.ui.overlay_timer:kill()
        state.ui.overlay_timer = nil
    end
    state.ui.active_chapter_index = nil
    update_click_binding(false)
    -- Hide the interactive button
    skip_button:hide()
end

function show_skip_overlay(message, duration, is_prompt, chapter_index)
    if not opts.show_notification then return end
    hide_skip_overlay()

    is_prompt = is_prompt or false
    state.ui.active_chapter_index = chapter_index
    local display_duration = duration or opts.notification_duration

    -- Show the interactive button instead of ASS overlay
    skip_button:set_message(message, is_prompt)
    on_mouse_pos(nil, mp.get_property_native('mouse-pos'))

    if display_duration > 0 then
        state.ui.overlay_timer = mp.add_timeout(display_duration, hide_skip_overlay)
    end
end

function start_skip_suppression()
    if state.ui.skip_suppression_timer then
        state.ui.skip_suppression_timer:kill()
    end
    state.ui.skip_suppression_timer = mp.add_timeout(skip_suppression_duration, function()
        state.ui.skip_suppression_timer = nil
    end)
end

-- Chapter entry notification
function notify_on_chapter_entry()
    if not opts.show_notification then return end

    local current_chapter_idx = mp.get_property_native("chapter")
    local skip_chapters = state.cache.skippable_chapters or {}

    -- Hide immediately if we exited the chapter that triggered the current Skip pill
    if state.ui.active_chapter_index ~= nil then
        if current_chapter_idx == nil or current_chapter_idx + 1 ~= state.ui.active_chapter_index then
            hide_skip_overlay()
        end
    end

    if state.mode ~= "chapter" or state.intro_skipped then return end

    for _, chapter in ipairs(skip_chapters) do
        if current_chapter_idx ~= nil and chapter.index == current_chapter_idx + 1 then
            local category_display = chapter.category:gsub("^%l", string.upper)
            local message = "Skip " .. category_display

            show_skip_overlay(message, chapter.duration > 0 and math.min(chapter.duration, opts.notification_duration) or nil, true, chapter.index)
            start_skip_suppression()
            return
        end
    end
end

function check_auto_skip()
    if not opts.auto_skip or state.mode ~= "chapter" then return end
    
    local current_chapter_idx = mp.get_property_native("chapter")
    local skip_chapters = state.cache.skippable_chapters or {}
    
    local categories = {}
    for category in string.gmatch(opts.skip_categories, "([^;]+)") do
        categories[category:lower():gsub("%s+", "")] = true
    end

    for _, chapter in ipairs(skip_chapters) do
        if current_chapter_idx ~= nil and chapter.index == current_chapter_idx + 1 then
            -- Check if this is a titled chapter (not positional)
            local is_titled = false
            for category_name, _ in pairs(categories) do
                if matches_chapter_pattern(chapter.title, category_name) then
                    is_titled = true
                    break
                end
            end
            
            if is_titled then
                mp.msg.info("Auto-skipping titled chapter: " .. chapter.title)
                skip_to_chapter_end(chapter.index)
                return
            end
        end
    end
end

-- Main skip function
function perform_skip()
    mp.msg.info("=== PERFORM_SKIP DEBUG ===")
    mp.msg.info("state.mode: " .. state.mode)
    mp.msg.info("state.intro_skipped before: " .. tostring(state.intro_skipped))

    start_skip_suppression() -- Start suppression immediately on key press
    hide_skip_overlay()
    
    local current_time = get_time()
    local duration = mp.get_property_native("duration") or 0
    
    if state.mode == "chapter" then
        mp.msg.info("In chapter mode skip logic")
        local skip_chapters = state.cache.skippable_chapters or {}
        local current_chapter_idx = mp.get_property_native("chapter")
        mp.msg.info("current_chapter_idx: " .. tostring(current_chapter_idx))
        mp.msg.info("skip_chapters count: " .. #skip_chapters)

        -- Try to skip current chapter
        if current_chapter_idx ~= nil then
            for _, chapter in ipairs(skip_chapters) do
                mp.msg.info("Checking chapter for current skip: " .. chapter.title .. " (index: " .. chapter.index .. ")")
                if chapter.index == current_chapter_idx + 1 then
                    mp.msg.info("MATCH - skipping current chapter: " .. chapter.title)
                    mp.msg.info("Chapter category: " .. chapter.category)
                    -- NEW: Check if this is an opening-category chapter
                    if chapter.category == "opening" then
                        state.intro_skipped = true
                        mp.msg.info("SETTING intro_skipped = TRUE")
                    else
                        mp.msg.info("NOT setting intro_skipped - chapter doesn't match opening pattern")
                    end
                    return skip_to_chapter_end(chapter.index)
                end
            end
        end
        
        -- Try to skip approaching chapter  
        for _, chapter in ipairs(skip_chapters) do
            mp.msg.info("Checking chapter for approaching skip: " .. chapter.title .. " (time: " .. chapter.time .. ")")
            -- Look for chapters starting soon (within next 10 seconds)
            if chapter.time > current_time and chapter.time <= current_time + opts.min_skip_duration then
                mp.msg.info("MATCH - skipping approaching chapter: " .. chapter.title)
                mp.msg.info("Chapter category: " .. chapter.category)
                -- NEW: Check if this is an opening-category chapter
                if chapter.category == "opening" then
                    state.intro_skipped = true
                    mp.msg.info("SETTING intro_skipped = TRUE")
                else
                    mp.msg.info("NOT setting intro_skipped - chapter doesn't match opening pattern")
                end
                set_time(chapter.time)
                return skip_to_chapter_end(chapter.index)
            end
        end
        
        -- Dynamic fallback if user clicks while in intro/outro window (e.g. triggered by music/blackframe)
        local in_intro = current_time <= opts.intro_time_window and not state.intro_skipped
        local in_ending = duration > 0 and current_time >= duration - opts.outro_time_window
        if in_intro or in_ending then
            start_silence_skip()
            return true
        end

        show_skip_overlay("Nothing to skip", 2, false)
        return false
        
    elseif state.mode == "silence" then
        local in_intro = current_time <= opts.intro_time_window and not state.intro_skipped  -- NEW: Add intro_skipped check
        local in_ending = duration > 0 and current_time >= duration - opts.outro_time_window

        if not in_intro and not in_ending then
            show_skip_overlay("✖ Nothing to skip", 2, false)
            return false
        end
        
        if state.silence_active or state.blackframe_skip_active then
            stop_silence_skip()
            set_time(state.skip_start_time)
            show_skip_overlay("✓ Skip Cancelled", 2, false)
        else
        start_silence_skip()
        end
        return true
    end

    show_skip_overlay("✖ Nothing to skip", 2, false)
    return false
end

-- Dynamic subtitle cue & chapter state monitoring
function on_sub_text_change(_, sub_text)
    if not opts.show_notification or not sub_text or sub_text == "" then return end
    if state.intro_skipped or state.ui.skip_suppression_timer or state.silence_active then return end
    if skip_button.min_visibility > 0 then return end

    local lower = sub_text:lower()
    local is_music_cue = lower:find("music", 1, true) and (lower:find("[", 1, true) or lower:find("(", 1, true) or lower:find("theme", 1, true) or lower:find("playing", 1, true))
        or lower:find("theme song", 1, true)
        or lower:find("opening theme", 1, true)
        or lower:find("intro music", 1, true)
        or lower:find("end credits", 1, true)
        or lower:find("closing theme", 1, true)
        or sub_text:find("♪", 1, true)
        or sub_text:find("♫", 1, true)
    if not is_music_cue then return end

    local current_time = get_time()
    local duration = mp.get_property_native("duration") or 0
    if current_time >= 5 and current_time <= opts.intro_time_window then
        local current_chapter_idx = mp.get_property_native("chapter")
        show_skip_overlay("Skip Opening", opts.filters_notification_duration, true, current_chapter_idx and (current_chapter_idx + 1) or nil)
        start_skip_suppression()
    elseif duration > 0 and current_time >= (duration - opts.outro_time_window) then
        local current_chapter_idx = mp.get_property_native("chapter")
        show_skip_overlay("Skip Ending", opts.filters_notification_duration, true, current_chapter_idx and (current_chapter_idx + 1) or nil)
        start_skip_suppression()
    end
end

-- Chapter-based notification check (auto-hide when leaving chapter, or show when inside)
function check_chapter_notifications()
    if state.ui.active_chapter_index ~= nil then
        local current_chapter_idx = mp.get_property_native("chapter")
        if current_chapter_idx == nil or (current_chapter_idx + 1) ~= state.ui.active_chapter_index then
            hide_skip_overlay()
        end
    end

    if not opts.show_notification or state.mode ~= "chapter" then return end
    if state.intro_skipped or state.ui.skip_suppression_timer or skip_button.min_visibility > 0 then return end

    local current_chapter_idx = mp.get_property_native("chapter")
    local skip_chapters = state.cache.skippable_chapters or {}
    for _, chapter in ipairs(skip_chapters) do
        if current_chapter_idx ~= nil and chapter.index == current_chapter_idx + 1 then
            local category_display = chapter.category:gsub("^%l", string.upper)
            show_skip_overlay("Skip " .. category_display, opts.notification_duration, true, chapter.index)
            start_skip_suppression()
            return
        end
    end
end

-- Main update function
function update_notifications_and_state()
    update_notification_filters_state()
    check_chapter_notifications()
end

-- Setup functions
function finalize_setup()
    state.cache.skippable_chapters = find_skip_chapters()
    init_notification_filters()
    init_skipping_filters()

    if #state.cache.skippable_chapters > 0 then
        state.mode = "chapter"
        mp.msg.info("Found " .. #state.cache.skippable_chapters .. " skippable chapters. Chapter + dynamic skipping enabled.")
        check_auto_skip()
        notify_on_chapter_entry()
    else
        state.mode = "silence"
        mp.msg.info("Using dynamic music/silence/black-frame skip detection.")
    end
end

function on_file_loaded()
    reset_script_state()
    -- Brief delay to let demuxer chapters stabilize
    mp.add_timeout(0.5, finalize_setup)
end

function reset_script_state()
    hide_skip_overlay()
    stop_notification_filters()
    if state.silence_active or state.blackframe_skip_active then 
        stop_silence_skip() 
    end
    
    if state.ui.skip_suppression_timer then
        state.ui.skip_suppression_timer:kill()
        state.ui.skip_suppression_timer = nil
    end
    
    state.mode = "none"
    state.silence_active = false
    state.blackframe_skip_active = false
    state.skip_start_time = 0
    state.intro_skipped = false
    state.detection.notification_active = false
    state.detection.skipping_active = false
    state.cache.skippable_chapters = nil
end

-- Event handlers
function on_time_change()
    if state.mode ~= "none" then
        update_notifications_and_state()
    end
end

function on_chapter_change()
    if state.mode ~= "none" then
        check_auto_skip()
        notify_on_chapter_entry()
    end
end

function on_seek()
    hide_skip_overlay()
    start_skip_suppression() -- Activate suppression on any seek

    local seek_back = state.skip_start_time + intro_threshold

    -- NEW: Reset intro_skipped if seeking back before any substantial skip point
    if state.intro_skipped and get_time() < seek_back then
        state.intro_skipped = false
        mp.msg.info("Seeked back to beginning, re-enabling intro skip")
    end
end

function on_shutdown()
    hide_skip_overlay()
    stop_notification_filters()
    if state.silence_active or state.blackframe_skip_active then 
        stop_silence_skip() 
    end
end

-- Button infrastructure setup
function update_display_dimensions()
	local real_width, real_height = mp.get_osd_size()
	if real_width <= 0 then return end
	display.width, display.height = real_width, real_height
	display.initialized = true
	Elements:trigger('display')
	Elements:update_proximities()
	request_render()
end

function render()
	if not display.initialized then return end
	button_state.render_last_time = mp.get_time()

	local ass = assdraw.ass_new()

	-- Render elements
	for _, element in Elements:ipairs() do
		if element.enabled then
			local result = element:maybe('render')
			if result then
				ass:new_event()
				ass:merge(result)
			end
		end
	end

	if osd.res_x == display.width and osd.res_y == display.height and osd.data == ass.text then
		return
	end

	osd.res_x = display.width
	osd.res_y = display.height
	osd.data = ass.text
	osd.z = 2000
	osd:update()
end

function request_render()
	if button_state.render_timer and button_state.render_timer:is_enabled() then return end
	local timeout = math.max(0, button_state.render_delay - (mp.get_time() - button_state.render_last_time))
	button_state.render_timer.timeout = timeout
	button_state.render_timer:resume()
end



-- Register events and key bindings
mp.register_event("file-loaded", on_file_loaded)
mp.register_event("shutdown", on_shutdown)
mp.observe_property("time-pos", "number", on_time_change)
mp.observe_property("chapter", "number", on_chapter_change)
mp.observe_property("sub-text", "string", on_sub_text_change)
mp.observe_property("mouse-pos", "native", on_mouse_pos)
mp.register_event("seek", on_seek)
mp.observe_property('osd-dimensions', 'native', update_display_dimensions)
mp.add_key_binding('Tab', 'perform_skip', perform_skip)
mp.add_key_binding('z', 'perform_skip_z', perform_skip)
mp.add_key_binding('Z', 'perform_skip_Z', perform_skip)

-- Start render loop
button_state.render_timer = mp.add_timeout(0, render)
