-- trash_after_watch.lua — Queue current local video to move to Windows Recycle Bin when watch finishes.
-- Strictly uses Recycle Bin (SendToRecycleBin) and NEVER performs permanent deletion.

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')

local marked_paths = {}   -- set of normalized absolute paths queued for Recycle Bin on finish
local pending_send = {}   -- files released at EOF and ready to be sent to Recycle Bin
local current_abs_path = nil
local current_finished = false

local function is_windows()
    return os.getenv('windir') ~= nil or package.config:sub(1, 1) == '\\'
end

local function is_url(path)
    return path ~= nil and (path:match('^https?://') ~= nil or path:match('^[%a][%w+.-]*://') ~= nil)
end

local function resolve_local_path(path)
    if not path or path == '' or is_url(path) then return nil end
    if is_windows() then
        path = path:gsub('/', '\\')
        if not (path:match('^%a:\\') or path:match('^\\\\')) then
            local cwd = utils.getcwd()
            if cwd and cwd ~= '' then
                path = utils.join_path(cwd, path):gsub('/', '\\')
            end
        end
        return path
    end
    if path:sub(1, 1) ~= '/' then
        local cwd = utils.getcwd()
        if cwd and cwd ~= '' then
            path = utils.join_path(cwd, path)
        end
    end
    return path
end

local function ps_quote(s)
    return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local function move_to_recycle_bin(path, delay_ms)
    if not path or path == '' then return end
    local info = utils.file_info(path)
    if not info or info.is_dir then return end

    if is_windows() then
        local wait_cmd = delay_ms and delay_ms > 0
            and string.format('Start-Sleep -Milliseconds %d; ', delay_ms)
            or ''
        -- Strictly uses SendToRecycleBin — never permanent delete
        local ps_script = string.format(
            [[& { param($p) %sAdd-Type -AssemblyName Microsoft.VisualBasic; if (Test-Path -LiteralPath $p) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin') } } %s]],
            wait_cmd,
            ps_quote(path)
        )
        mp.command_native_async({
            name = 'subprocess',
            playback_only = false,
            detach = true,
            args = { 'powershell.exe', '-NoProfile', '-WindowStyle', 'Hidden', '-Command', ps_script },
        }, function(success, res)
            if success and res and res.status == 0 then
                msg.info('Moved to Recycle Bin: ' .. path)
                mp.osd_message('Moved to Recycle Bin:\n' .. (path:match('[^\\/]+$') or path), 3)
            else
                msg.warn('Failed to move to Recycle Bin (file kept intact): ' .. path)
            end
        end)
    else
        mp.command_native_async({
            name = 'subprocess',
            playback_only = false,
            detach = true,
            args = { 'gio', 'trash', path },
        })
    end
end

local function toggle_recycle()
    local path = resolve_local_path(mp.get_property('path'))
    if not path then
        mp.osd_message('Recycle Bin: only local files can be queued', 2.5)
        return
    end
    local filename = path:match('[^\\/]+$') or path

    if marked_paths[path] then
        marked_paths[path] = nil
        mp.osd_message('Cancelled Recycle Bin:\n' .. filename, 2.5)
        msg.info('Unmarked from Recycle Bin: ' .. path)
    else
        marked_paths[path] = true
        mp.osd_message('Will move to Recycle Bin after watch finishes:\n' .. filename .. '\n(Press again to cancel)', 3.5)
        msg.info('Queued for Recycle Bin after watch finishes: ' .. path)
    end
end

local function on_file_loaded()
    current_abs_path = resolve_local_path(mp.get_property('path'))
    current_finished = false
end

local function on_eof_reached(_, eof)
    if not eof or current_finished then return end
    current_finished = true

    if current_abs_path and marked_paths[current_abs_path] then
        local target = current_abs_path
        marked_paths[target] = nil
        pending_send[target] = true

        -- Release mpv's file handle (important when keep-open=yes is enabled)
        local count = mp.get_property_number('playlist-count', 1)
        local pos = mp.get_property_number('playlist-pos', 0)
        if pos < count - 1 then
            mp.commandv('playlist-next')
        else
            mp.command('stop')
        end
    end
end

local function on_end_file(ev)
    if ev and ev.reason == 'eof' and current_abs_path and marked_paths[current_abs_path] then
        pending_send[current_abs_path] = true
        marked_paths[current_abs_path] = nil
    end

    for target, _ in pairs(pending_send) do
        pending_send[target] = nil
        -- Tiny delay lets OS finalize closing handle before Recycle Bin moves the file
        move_to_recycle_bin(target, 250)
    end
end

local function on_shutdown()
    -- If user closes mpv right after playback reached EOF on a marked file, finish recycling it
    if current_finished and current_abs_path and marked_paths[current_abs_path] then
        pending_send[current_abs_path] = true
        marked_paths[current_abs_path] = nil
    end
    for target, _ in pairs(pending_send) do
        pending_send[target] = nil
        move_to_recycle_bin(target, 500)
    end
end

mp.register_event('file-loaded', on_file_loaded)
mp.register_event('end-file', on_end_file)
mp.register_event('shutdown', on_shutdown)
mp.observe_property('eof-reached', 'bool', on_eof_reached)
mp.add_key_binding(nil, 'toggle-recycle', toggle_recycle)
