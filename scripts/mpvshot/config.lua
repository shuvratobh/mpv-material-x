--[[
mpvshot — organised screenshots + Telegram publishing for mpv.
Copyright (C) 2026 Bestfast

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

-- One config source: script-opts\mpvshot.conf, the standard mpv location.
-- Every key can also be set per-run with --script-opts=mpvshot-key=value.
--
-- Uploading is off unless telegram=yes AND a token and chat id are present.
-- With none of those, this is purely a screenshot organiser.

local msg = require('mp.msg')
local options = require('mp.options')

local this = {}

this.windows = (os.getenv('OS') or ''):find('Windows') ~= nil
this.sep = this.windows and '\\' or '/'

local function home()
    return os.getenv('USERPROFILE') or os.getenv('HOME') or '.'
end

-- Where failed uploads wait to be retried. Runtime state, not configuration,
-- so it follows the platform's data directory rather than the config one.
local function default_outbox()
    if this.windows then
        local appdata = os.getenv('APPDATA') or (home() .. '\\AppData\\Roaming')
        return appdata .. '\\mpvshot\\outbox'
    end
    local state = os.getenv('XDG_STATE_HOME') or (home() .. '/.local/state')
    return state .. '/mpvshot/outbox'
end

local defaults = {
    -- Master switch. Off means: organise screenshots, upload nothing, ever.
    telegram = false,
    bot_token = '',
    chat_id = '',
    topic_photos = '',
    topic_docs = '',

    screenshot_root = home() .. this.sep .. 'Pictures' .. this.sep .. 'mpv',
    outbox_dir = default_outbox(),

    -- Category hashtag added after the title's own. Empty disables that one.
    tag_tv = 'TV',
    tag_movie = 'Movie',
    tag_clip = 'Clip',
    tag_other = 'Stream',

    upload_photos = true,
    upload_docs = true,
    debounce = 2.5,
    jpeg_quality = 95,
    dry_run = false,
    screenshot_sw = false,
}

--- A fresh copy of the defaults, so a failed load still has something usable.
function this.defaults()
    local copy = {}
    for k, v in pairs(defaults) do
        copy[k] = v
    end
    return copy
end

this.values = this.defaults()

--- Read script-opts\mpvshot.conf and any --script-opts overrides.
-- Never raises: a missing or malformed file leaves the defaults in place,
-- which is what keeps this harmless under plain mpv.
function this.load()
    local values = this.defaults()
    -- read_options infers types from the defaults it is handed, so booleans
    -- accept yes/no and numbers are parsed as numbers.
    local ok, err = pcall(options.read_options, values, 'mpvshot')
    if not ok then
        msg.warn('could not read script-opts/mpvshot.conf: ' .. tostring(err))
        values = this.defaults()
    end

    if type(values.debounce) ~= 'number' or values.debounce < 0 then values.debounce = 0 end
    if type(values.jpeg_quality) ~= 'number' then values.jpeg_quality = defaults.jpeg_quality end
    if values.jpeg_quality < 0 then values.jpeg_quality = 0 end
    if values.jpeg_quality > 100 then values.jpeg_quality = 100 end
    values.screenshot_root = values.screenshot_root:gsub('[/\\]+$', '')
    values.outbox_dir = values.outbox_dir:gsub('[/\\]+$', '')

    this.values = values
    return values
end

--- True when uploading is switched on and actually usable.
-- dry_run counts as usable on purpose: captions and argv can be checked
-- without a bot token, which is the whole point of the development loop.
function this.telegram_ready()
    local v = this.values
    if v.telegram ~= true then
        return false
    end
    return v.dry_run == true or (v.bot_token ~= '' and v.chat_id ~= '')
end

--- Switched on but not usable — worth telling the user about once.
function this.telegram_incomplete()
    return this.values.telegram == true and not this.telegram_ready()
end

return this
