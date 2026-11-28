--[[
mpvshot — organised screenshots + Telegram publishing for mpv.
Copyright (C) 2026 Bestfast

Portions derived from Videoclip (https://github.com/Ajatt-Tools/videoclip)
Copyright (C) 2021 Ren Tatsumoto, GPL-3.0-or-later.
  - filename sanitising, adapted from encoder.lua's clean_filename /
    clean_forbidden_characters for the folder layout used here.

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program.  If not, see <https://www.gnu.org/licenses/>.
]]

local mp = require('mp')
local utils = require('mp.utils')
local msg = require('mp.msg')
local config = require('config')
local meta = require('meta')

local this = {}

local MAX_COMPONENT = 120
local sep = config.sep

function this.join(...)
    local parts = { ... }
    local out = parts[1] or ''
    for i = 2, #parts do
        out = out .. sep .. parts[i]
    end
    return out
end

--- Make one path component safe on Windows (the strictest of the platforms).
function this.sanitise(name)
    name = tostring(name or '')
    name = name:gsub('[<>:"/\\|%?%*]', '_')
    name = name:gsub('%c', ' ')
    name = name:gsub('%s+', ' ')
    name = name:gsub('^%s+', ''):gsub('%s+$', '')
    if #name > MAX_COMPONENT then
        name = name:sub(1, MAX_COMPONENT)
    end
    -- Windows silently drops trailing dots and spaces; do it ourselves so the
    -- name we write is the name we later hand to curl.
    name = name:gsub('[%.%s]+$', '')
    if name == '' then
        name = '_'
    end
    return name
end

function this.exists(path)
    return utils.file_info(path) ~= nil
end

local function is_dir(path)
    local info = utils.file_info(path)
    return info ~= nil and info.is_dir
end

local function parent_of(path)
    local dir = path:match('^(.*)[/\\][^/\\]+$')
    if dir == nil or dir == '' then return nil end
    -- "C:" is not a directory we can create or test; stop there.
    if dir:match('^%a:$') then return nil end
    return dir
end

local function mkdir_one(path)
    if utils.mkdir then
        return utils.mkdir(path)
    end
    -- Older mpv: shell out. stdout is captured, so no console window appears.
    local args = config.windows
            and { 'cmd', '/c', 'mkdir', (path:gsub('/', '\\')) }
            or { 'mkdir', '-p', path }
    local r = mp.command_native({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    })
    return r ~= nil and r.status == 0
end

--- Create a directory and any missing ancestors. Returns true on success.
function this.ensure_dir(dir)
    if dir == nil or dir == '' or is_dir(dir) then
        return dir ~= nil and dir ~= ''
    end
    local missing = {}
    local cursor = dir
    while cursor and not is_dir(cursor) do
        table.insert(missing, 1, cursor)
        cursor = parent_of(cursor)
    end
    for _, path in ipairs(missing) do
        if not mkdir_one(path) and not is_dir(path) then
            msg.error('could not create directory: ' .. path)
            return false
        end
    end
    return true
end

--- Append " (2)", " (3)", ... until the name is free.
function this.dedupe(dir, stem, ext)
    local candidate = this.join(dir, stem .. ext)
    if not this.exists(candidate) then
        return candidate
    end
    for n = 2, 999 do
        candidate = this.join(dir, string.format('%s (%d)%s', stem, n, ext))
        if not this.exists(candidate) then
            return candidate
        end
    end
    -- Pathological case only; a timestamped name is still better than failing.
    return this.join(dir, string.format('%s (%d)%s', stem, os.time(), ext))
end

--- Where a shot of `info` taken at `seconds` belongs.
-- Returns dir, stem (both sanitised, no extension on the stem).
function this.layout(info, seconds)
    local root = config.values.screenshot_root
    local stamp = meta.file_time(seconds)

    if info.kind == 'jellyfin_episode' or info.kind == 'local_episode' then
        local series = this.sanitise(info.series)
        local stem = string.format('%s - %s - %s', series, meta.episode_code(info), stamp)
        return this.join(root, 'TV', series), this.sanitise(stem)
    end

    if info.kind == 'jellyfin_movie' or info.kind == 'movie' then
        local movie = this.sanitise(info.movie)
        local folder = info.year and this.sanitise(string.format('%s (%s)', info.movie, info.year)) or movie
        return this.join(root, 'Movies', folder), this.sanitise(string.format('%s - %s', movie, stamp))
    end

    if info.kind == 'clip' then
        local month = info.month or os.date('%Y-%m')
        local label = this.sanitise(info.label)
        return this.join(root, 'Clips', this.sanitise(month)), this.sanitise(string.format('%s - %s', label, stamp))
    end

    local label = this.sanitise(info.label or 'stream')
    return this.join(root, 'Unsorted'), this.sanitise(string.format('%s - %s', label, stamp))
end

--- Full absolute path for the archive PNG, directory already created.
-- Absolute paths make the shim's own `screenshot_dir: Desktop` irrelevant here.
function this.archive_png(info, seconds)
    local dir, stem = this.layout(info, seconds)
    if not this.ensure_dir(dir) then
        return nil
    end
    return this.dedupe(dir, stem, '.jpg')
end

local temp_counter = 0

--- Scratch JPEG, uploaded then deleted. Only exists because sendPhoto caps at
-- 10 MB / 10000px summed, which a 4K PNG can breach.
function this.temp_jpeg()
    local base = os.getenv('TEMP') or os.getenv('TMPDIR') or (config.windows and 'C:\\Windows\\Temp' or '/tmp')
    local dir = this.join(base:gsub('[/\\]+$', ''), 'mpvshot')
    if not this.ensure_dir(dir) then
        return nil
    end
    temp_counter = temp_counter + 1
    return this.join(dir, string.format('%d-%d-%04d.jpg', os.time(), temp_counter, math.random(0, 9999)))
end

function this.remove(path)
    if path == nil then return end
    os.remove(path)
end

return this
