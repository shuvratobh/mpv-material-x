--[[
mpvshot — organised screenshots + Telegram publishing for mpv.
Copyright (C) 2026 Bestfast

Portions derived from Videoclip (https://github.com/Ajatt-Tools/videoclip)
Copyright (C) 2021 Ren Tatsumoto, GPL-3.0-or-later.
  - the mp.command_native{name="subprocess", playback_only=false, ...} table
    shape (helpers.lua),
  - the curl-over-subprocess structure and its exit-code check (videoclip.lua,
    upload_to_catbox),
  - curl.exe vs curl resolution (platform.lua).

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
local paths = require('paths')

local this = {}

local curl_exe = config.windows and 'curl.exe' or 'curl'
local API = 'https://api.telegram.org/bot'

local function osd(text, duration)
    mp.osd_message(text, duration or 3)
end

local function endpoint(method)
    return API .. config.values.bot_token .. '/' .. method
end

-- Never let a token reach the log or the OSD.
local function redact(args)
    local out = {}
    for i, a in ipairs(args) do
        out[i] = (a:gsub(API .. '[^/]+/', API .. '<token>/'))
    end
    return out
end

local function subprocess_table(args)
    return {
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }
end

--------------------------------------------------------------------------------
-- Jobs
--------------------------------------------------------------------------------

-- A job is: { method, field, topic, items = { {file, caption, temp}, ... } }
-- `field` is "photo" or "document"; it doubles as the media type inside an
-- album. Jobs are JSON-serialisable so a failed one can sit in the outbox.

function this.photo_job(items, topic)
    return { method = #items > 1 and 'sendMediaGroup' or 'sendPhoto', field = 'photo', topic = topic, items = items }
end

function this.document_job(items, topic)
    return { method = #items > 1 and 'sendMediaGroup' or 'sendDocument', field = 'document', topic = topic, items = items }
end

--- The thread id to actually send, or nil to omit the parameter.
-- The General topic is thread 1, but the Bot API rejects
-- `message_thread_id=1` with "message thread not found" — posting to General
-- means leaving the parameter out entirely. Other topic ids pass through.
local function thread_id(topic)
    if topic == nil then
        return nil
    end
    local t = tostring(topic):gsub('%s+', '')
    if t == '' or t == '1' or t:lower() == 'general' then
        return nil
    end
    return t
end

local function build_args(job)
    local v = config.values
    local args = { curl_exe, '-s', '-S', '--max-time', '600', '-F', 'chat_id=' .. tostring(v.chat_id) }

    local topic = thread_id(job.topic)
    if topic ~= nil then
        table.insert(args, '-F')
        table.insert(args, 'message_thread_id=' .. topic)
    end

    if job.method == 'sendMediaGroup' then
        local media = {}
        for i, item in ipairs(job.items) do
            local name = 'file' .. i
            media[i] = { type = job.field, media = 'attach://' .. name, caption = item.caption }
            table.insert(args, '-F')
            -- Quoting the value protects paths containing , and ; from curl's
            -- own -F parsing.
            table.insert(args, string.format('%s=@"%s"', name, item.file))
        end
        table.insert(args, '-F')
        table.insert(args, 'media=' .. utils.format_json(media))
    else
        local item = job.items[1]
        if item.caption then
            table.insert(args, '-F')
            table.insert(args, 'caption=' .. item.caption)
        end
        table.insert(args, '-F')
        table.insert(args, string.format('%s=@"%s"', job.field, item.file))
    end

    table.insert(args, endpoint(job.method))
    return args
end

local function describe(job)
    local names = {}
    for i, item in ipairs(job.items) do
        names[i] = item.file
    end
    return string.format('%s x%d -> %s', job.method, #job.items, table.concat(names, ', '))
end

--- Turn a finished subprocess into ok, error-message.
-- Exit codes in [0, 99] come from curl itself; anything else means the shell
-- failed to run curl at all. (Kept from videoclip — easy to get wrong.)
local function interpret(r)
    if r == nil then
        return false, 'subprocess failed to start'
    end
    if r.status < 0 or r.status > 99 then
        return false, 'curl not found (install curl or put it in PATH)'
    end
    if r.status ~= 0 then
        return false, 'curl exited ' .. tostring(r.status) .. ' ' .. (r.stderr or ''):gsub('%s+$', '')
    end
    local body = utils.parse_json(r.stdout or '')
    if type(body) ~= 'table' then
        return false, 'unreadable response from Telegram'
    end
    if body.ok ~= true then
        return false, string.format('Telegram: %s (%s)', tostring(body.description), tostring(body.error_code))
    end
    return true, nil
end

--------------------------------------------------------------------------------
-- Outbox
--------------------------------------------------------------------------------

local outbox_counter = 0

local function park(job)
    if not paths.ensure_dir(config.values.outbox_dir) then
        return
    end
    outbox_counter = outbox_counter + 1
    local name = string.format('%d-%d-%04d.json', os.time(), outbox_counter, math.random(0, 9999))
    local path = paths.join(config.values.outbox_dir, name)
    local fh = io.open(path, 'w')
    if not fh then
        msg.error('could not write outbox job ' .. path)
        return
    end
    job.created = job.created or os.time()
    fh:write(utils.format_json(job))
    fh:close()
    msg.warn('parked in outbox: ' .. path)
end

local function read_job(path)
    local fh = io.open(path, 'r')
    if not fh then return nil end
    local text = fh:read('*a')
    fh:close()
    local job = utils.parse_json(text or '')
    if type(job) ~= 'table' or type(job.items) ~= 'table' or job.method == nil then
        return nil
    end
    return job
end

--- Drop items whose files have since disappeared. Returns false if nothing is
-- left to send.
local function prune(job)
    local kept = {}
    for _, item in ipairs(job.items) do
        if paths.exists(item.file) then
            table.insert(kept, item)
        else
            msg.warn('dropping missing file from job: ' .. tostring(item.file))
        end
    end
    job.items = kept
    if #kept == 0 then
        return false
    end
    -- A pruned album may have shrunk to a single item.
    if #kept == 1 and job.method == 'sendMediaGroup' then
        job.method = job.field == 'document' and 'sendDocument' or 'sendPhoto'
    end
    return true
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

local function cleanup(job)
    for _, item in ipairs(job.items) do
        if item.temp then
            paths.remove(item.file)
        end
    end
end

--- Send one job. `done(ok, err)` is always called.
-- `sync` runs it blocking, which is what the shutdown flush needs.
local function send_one(job, sync, done)
    if not prune(job) then
        done(true, nil)
        return
    end

    local args = build_args(job)

    if config.values.dry_run then
        msg.info('[dry run] ' .. describe(job))
        for _, item in ipairs(job.items) do
            if item.caption then
                msg.info('[dry run] caption: ' .. item.caption:gsub('\n', ' | '))
            end
        end
        msg.info('[dry run] argv: ' .. utils.format_json(redact(args)))
        cleanup(job)
        done(true, nil)
        return
    end

    msg.debug('curl ' .. utils.format_json(redact(args)))

    if sync then
        local ok, err = interpret(mp.command_native(subprocess_table(args)))
        if ok then cleanup(job) else park(job) end
        done(ok, err)
        return
    end

    mp.command_native_async(subprocess_table(args), function(success, result, error_string)
        local ok, err
        if not success then
            ok, err = false, tostring(error_string or 'subprocess error')
        else
            ok, err = interpret(result)
        end
        if ok then
            msg.info('posted ' .. describe(job))
            cleanup(job)
        else
            msg.error('post failed: ' .. tostring(err))
            park(job)
        end
        done(ok, err)
    end)
end

--- Send jobs one after another; report once at the end.
function this.send(jobs, sync, on_finished)
    on_finished = on_finished or function() end
    if #jobs == 0 then
        on_finished(true, nil)
        return
    end

    local index = 0
    local failure = nil

    local function step()
        index = index + 1
        if index > #jobs then
            on_finished(failure == nil, failure)
            return
        end
        send_one(jobs[index], sync, function(ok, err)
            if not ok then failure = failure or err end
            step()
        end)
    end

    step()
end

--- Retry everything parked earlier. Runs on script load and after each
-- successful flush.
function this.drain_outbox()
    if not config.telegram_ready() or config.values.dry_run then
        return
    end
    local entries = utils.readdir(config.values.outbox_dir, 'files')
    if not entries or #entries == 0 then
        return
    end
    table.sort(entries)

    local pending = 0
    local sent = 0
    for _, name in ipairs(entries) do
        if name:match('%.json$') then
            local path = paths.join(config.values.outbox_dir, name)
            local job = read_job(path)
            if job == nil then
                msg.warn('discarding unreadable outbox job: ' .. path)
                os.remove(path)
            else
                pending = pending + 1
                -- Remove first: send_one re-parks under a new name on failure,
                -- so the job is never lost and never duplicated.
                os.remove(path)
                send_one(job, false, function(ok)
                    if ok then sent = sent + 1 end
                    pending = pending - 1
                    if pending == 0 and sent > 0 then
                        osd(string.format('mpvshot: sent %d queued upload%s', sent, sent == 1 and '' or 's'))
                    end
                end)
            end
        end
    end
    if pending > 0 then
        msg.info(string.format('draining outbox: %d job(s)', pending))
    end
end

function this.outbox_count()
    local entries = utils.readdir(config.values.outbox_dir, 'files')
    if not entries then return 0 end
    local n = 0
    for _, name in ipairs(entries) do
        if name:match('%.json$') then n = n + 1 end
    end
    return n
end

return this
