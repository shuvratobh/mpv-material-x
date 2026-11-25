-- skip-intro.lua - Lightweight Netflix-style Skip Intro for mpv (zero-overhead chapter detection)
local mp = require 'mp'
local opt = require 'mp.options'

local options = {
    auto_skip = false,            -- Skip automatically without asking
    prompt_duration = 6,          -- How long the banner stays visible in seconds
    fallback_skip_seconds = 85,   -- Seconds to skip when pressing Tab/Z without named chapters
}
opt.read_options(options, 'skip-intro')

local overlay = mp.create_osd_overlay('ass-events')
local hide_timer = nil
local active_intro_end = nil
local is_showing_prompt = false

local intro_patterns = {
    'intro', 'opening', '^op$', '^op%s', '%sop$',
    'prologue', 'recap', 'avant', 'theme', 'title sequence',
    'オープニング'
}

local function is_intro_title(title)
    if not title or title == '' then return false end
    local lower = title:lower()
    for _, pattern in ipairs(intro_patterns) do
        if lower:match(pattern) then
            return true
        end
    end
    return false
end

local function get_chapter_end_time(index, chapters, duration)
    if not chapters then return nil end
    local next_chap = chapters[index + 2] -- chapter property is 0-based, Lua table is 1-based
    if next_chap and next_chap.time then
        return next_chap.time
    end
    return duration
end

local function hide_banner()
    if not is_showing_prompt then return end
    overlay.data = ''
    overlay:update()
    is_showing_prompt = false
    active_intro_end = nil
    if hide_timer then
        hide_timer:kill()
        hide_timer = nil
    end
end

local function show_banner(target_time)
    active_intro_end = target_time
    is_showing_prompt = true

    local d_w, d_h = mp.get_osd_size()
    if not d_w or d_w <= 0 then d_w, d_h = 1280, 720 end

    local btn_w, btn_h = 224, 44
    local bx = d_w - 36
    local by = d_h - 92
    local ax = bx - btn_w
    local ay = by - btn_h

    -- Frosted dark pill with rounded corners and light-blue (#008cfb -> BGR fb8c00) accent bar
    local r = 6
    local ass = string.format(
        '{\\pos(0,0)\\an7\\blur0\\bord1\\3c&H3A3A3A&\\1c&H141414&\\1a&H26&}' ..
        '{\\p1}m %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d{\\p0}',
        ax + r, ay, ax, ay, ax, ay, ax, ay + r,
        ax, by - r, ax, by, ax, by, ax + r, by,
        bx - r, by, bx, by, bx, by, bx, by - r,
        bx, ay + r, bx, ay, bx, ay, bx - r, ay
    )
    ass = ass .. string.format(
        '\\N{\\pos(0,0)\\an7\\bord0\\1c&Hfb8c00&\\1a&H00&}' ..
        '{\\p1}m %d %d l %d %d l %d %d l %d %d{\\p0}',
        ax + 1, ay + 6, ax + 5, ay + 6, ax + 5, by - 6, ax + 1, by - 6
    )
    ass = ass .. string.format(
        '\\N{\\pos(%d,%d)\\an4\\bord0\\shad0\\fnAsap Condensed Medium\\fs22\\1c&HFFFFFF&}Skip Intro  {\\fs16\\1c&HAAAAAA&}[Tab / Z]',
        ax + 18, ay + math.floor(btn_h / 2)
    )

    overlay.res_x = d_w
    overlay.res_y = d_h
    overlay.data = ass
    overlay:update()

    if hide_timer then hide_timer:kill() end
    hide_timer = mp.add_timeout(options.prompt_duration, hide_banner)
end

local function skip_to_target(target_time)
    if not target_time then return false end
    mp.set_property_number('time-pos', target_time)
    hide_banner()
    local formatted = string.format('%02d:%02d', math.floor(target_time / 60), math.floor(target_time % 60))
    mp.osd_message('⏭ Skipped Intro → ' .. formatted, 2)
    return true
end

local function execute_skip()
    if active_intro_end then
        return skip_to_target(active_intro_end)
    end

    local current_chapter = mp.get_property_number('chapter')
    local chapters = mp.get_property_native('chapter-list')
    local duration = mp.get_property_number('duration', 0)
    local current_time = mp.get_property_number('time-pos', 0)

    if current_chapter and chapters and chapters[current_chapter + 1] then
        local chap = chapters[current_chapter + 1]
        if is_intro_title(chap.title) then
            return skip_to_target(get_chapter_end_time(current_chapter, chapters, duration))
        end
    end

    -- Fallback: early in a chaptered episode, jump to next chapter
    if current_time < 240 and current_chapter and chapters and #chapters > 1 and current_chapter < 2 then
        local next_chap = chapters[current_chapter + 2]
        if next_chap and next_chap.time then
            return skip_to_target(next_chap.time)
        end
    end

    -- Fallback: fixed intro jump
    local target = math.min(duration, current_time + options.fallback_skip_seconds)
    mp.set_property_number('time-pos', target)
    local formatted = string.format('%02d:%02d', math.floor(target / 60), math.floor(target % 60))
    mp.osd_message(string.format('⏭ Skipped +%ds → %s', options.fallback_skip_seconds, formatted), 2)
    return true
end

local last_chapter = nil
mp.observe_property('chapter', 'number', function(_, current_chapter)
    if current_chapter == nil or current_chapter == last_chapter then return end
    last_chapter = current_chapter

    local chapters = mp.get_property_native('chapter-list')
    if not chapters or not chapters[current_chapter + 1] then
        hide_banner()
        return
    end

    local chap = chapters[current_chapter + 1]
    if is_intro_title(chap.title) then
        local duration = mp.get_property_number('duration', 0)
        local target = get_chapter_end_time(current_chapter, chapters, duration)
        if options.auto_skip then
            skip_to_target(target)
        else
            show_banner(target)
        end
    else
        hide_banner()
    end
end)

mp.register_event('end-file', function()
    last_chapter = nil
    hide_banner()
end)

mp.add_key_binding('Tab', 'skip_intro_tab', execute_skip)
mp.add_key_binding('z', 'skip-key', execute_skip)
mp.register_script_message('skip-intro', execute_skip)
