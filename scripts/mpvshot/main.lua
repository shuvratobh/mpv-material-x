--[[
mpvshot — organised screenshots + Telegram publishing for mpv.
Copyright (C) 2026 Bestfast

Portions derived from Videoclip (https://github.com/Ajatt-Tools/videoclip)
Copyright (C) 2021 Ren Tatsumoto, GPL-3.0-or-later. See README.md.

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

package.path = mp.get_script_directory() .. '/?.lua;' .. package.path

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')

local config = require('config')
local meta = require('meta')
local paths = require('paths')
local telegram = require('telegram')

local ALBUM_MAX = 10 -- Telegram's cap on items in one media group

local queue = {}
local debounce_timer = nil
local hinted = false
local last_screenshot_path = nil

local flush -- defined below, referenced by take_screenshot

math.randomseed(os.time() + (mp.get_property_number('pid') or 0))

local function osd(text, duration)
    mp.osd_message('mpvshot: ' .. text, duration or 2)
end

local is_windows = config.windows

local function ps_quote(s)
    return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local win32_shell_open = nil
if is_windows then
    local ok, ffi = pcall(require, 'ffi')
    if ok then
        pcall(ffi.cdef, [[
            int __stdcall MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags,
                const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
            void* __stdcall ShellExecuteW(void* hwnd, const wchar_t* lpOperation,
                const wchar_t* lpFile, const wchar_t* lpParameters, const wchar_t* lpDirectory, int nShowCmd);
        ]])
        local shell32_ok, shell32 = pcall(ffi.load, 'shell32')
        local kernel32_ok, kernel32 = pcall(ffi.load, 'kernel32')
        if shell32_ok and kernel32_ok then
            local function to_wide(utf8)
                local n = kernel32.MultiByteToWideChar(65001, 0, utf8, -1, nil, 0)
                if n <= 0 then return nil end
                local buf = ffi.new('wchar_t[?]', n)
                kernel32.MultiByteToWideChar(65001, 0, utf8, -1, buf, n)
                return buf
            end
            win32_shell_open = function(target_exe, params_str)
                local op = to_wide('open')
                local file = to_wide(target_exe)
                local params = params_str and to_wide(params_str) or nil
                if not op or not file then return false end
                local res = tonumber(ffi.cast('intptr_t', shell32.ShellExecuteW(nil, op, file, params, nil, 1)))
                return res ~= nil and res > 32
            end
        end
    end
end

local function copy_image_to_clipboard(path)
    if not is_windows or not path or not paths.exists(path) then return end
    -- Pure Win32 CF_DIB (format 8) via OpenClipboard/EmptyClipboard/SetClipboardData:
    -- bypasses .NET WinForms OleFlushClipboard failures in hidden processes so WhatsApp & Win+V always get the latest image.
    local ps_cmd = [[& { param($p) Add-Type -AssemblyName System.Drawing; $src=[System.Drawing.Image]::FromFile($p); $bmp=New-Object System.Drawing.Bitmap($src.Width,$src.Height,[System.Drawing.Imaging.PixelFormat]::Format32bppRgb); $g=[System.Drawing.Graphics]::FromImage($bmp); $g.DrawImage($src,0,0,$src.Width,$src.Height); $g.Dispose(); $src.Dispose(); $ms=New-Object IO.MemoryStream; $bmp.Save($ms,[System.Drawing.Imaging.ImageFormat]::Bmp); $bmp.Dispose(); $bytes=$ms.ToArray(); $ms.Dispose(); $dibLen=$bytes.Length-14; Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class WinClip { [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr hWnd); [DllImport("user32.dll")] public static extern bool CloseClipboard(); [DllImport("user32.dll")] public static extern bool EmptyClipboard(); [DllImport("user32.dll")] public static extern IntPtr SetClipboardData(uint fmt, IntPtr hMem); [DllImport("kernel32.dll")] public static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes); [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr hMem); [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr hMem); }'; $h=[WinClip]::GlobalAlloc(0x0042,[UIntPtr]::new([uint32]$dibLen)); $ptr=[WinClip]::GlobalLock($h); [System.Runtime.InteropServices.Marshal]::Copy($bytes,14,$ptr,$dibLen); [WinClip]::GlobalUnlock($h)|Out-Null; for($i=0;$i -lt 25;$i++){ if([WinClip]::OpenClipboard([IntPtr]::Zero)){ [WinClip]::EmptyClipboard()|Out-Null; [WinClip]::SetClipboardData(8,$h)|Out-Null; [WinClip]::CloseClipboard()|Out-Null; break }; Start-Sleep -Milliseconds 40 } } ]] .. ps_quote(path)
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        detach = true,
        args = { 'powershell.exe', '-NoProfile', '-WindowStyle', 'Hidden', '-Command', ps_cmd },
    })
end

local function reveal_last_screenshot()
    if mp.get_property_bool('fullscreen') then
        mp.set_property_bool('fullscreen', false)
    end

    local target = last_screenshot_path
    if not target or not paths.exists(target) then
        local root = (config.values.screenshot_root or ''):gsub('/', '\\')
        osd('opening ' .. root, 2)
        if is_windows and root ~= '' then
            if not (win32_shell_open and win32_shell_open('explorer.exe', '"' .. root:gsub('"', '""') .. '"')) then
                mp.command_native_async({
                    name = 'subprocess', playback_only = false, detach = true,
                    args = { 'powershell.exe', '-NoProfile', '-WindowStyle', 'Hidden', '-Command', '& { param($d) Start-Process explorer.exe -ArgumentList (\'"\' + $d + \'"\') } ' .. ps_quote(root) },
                })
            end
        end
        return
    end

    target = target:gsub('/', '\\')
    local shown = target:match('[^\\]+$') or target
    osd('reveal ' .. shown, 2.5)
    if is_windows then
        local params = '/select,"' .. target:gsub('"', '""') .. '"'
        if win32_shell_open and win32_shell_open('explorer.exe', params) then
            return
        end
        mp.command_native_async({
            name = 'subprocess', playback_only = false, detach = true,
            args = { 'powershell.exe', '-NoProfile', '-WindowStyle', 'Hidden', '-Command', '& { param($p) Start-Process explorer.exe -ArgumentList (\'/select,"\' + ($p -replace \'"\',\'""\') + \'"\') } ' .. ps_quote(target) },
        })
    end
end

--------------------------------------------------------------------------------
-- Capture
--------------------------------------------------------------------------------

-- Nothing here may raise: this script must be harmless under plain mpv.
local function screenshot_to_file(path, flags)
    local ok, res, err = pcall(mp.command_native, { 'screenshot-to-file', path, flags })
    if not ok then
        msg.error('screenshot-to-file raised: ' .. tostring(res))
        return false
    end
    if res == nil and err ~= nil then
        msg.error('screenshot-to-file failed: ' .. tostring(err))
        return false
    end
    if not paths.exists(path) then
        msg.error('screenshot-to-file wrote nothing to ' .. path)
        return false
    end
    return true
end

local function with_properties(props, fn)
    local saved = {}
    for name, value in pairs(props) do
        saved[name] = mp.get_property(name)
        mp.set_property(name, value)
    end
    local ok, result = pcall(fn)
    for name, value in pairs(saved) do
        if value ~= nil then
            mp.set_property(name, value)
        end
    end
    if not ok then
        msg.error(tostring(result))
        return false
    end
    return result
end

--- One keypress: the archive PNG, plus a JPEG for the photo post.
-- Both screenshot-to-file calls happen inside this one callback, so they hit
-- the same frame; when paused they are identical by construction.
local function take_screenshot(mode)
    local seconds = mp.get_property_number('time-pos')
    if seconds == nil then
        osd('nothing playing')
        return
    end

    local info = meta.current()
    local png = paths.archive_png(info, seconds)
    if png == nil then
        osd('could not create the destination folder', 3)
        return
    end

    local shown = png:match('[^/\\]+$') or png
    osd('Capturing ' .. shown .. '...', 2)

    local flags = (mode == 'nosubs') and 'video' or 'subtitles'
    local capture = function()
        return screenshot_to_file(png, flags)
    end
    local fast_props = {
        ['screenshot-jpeg-quality'] = tostring(config.values.jpeg_quality or 92),
    }
    if config.values.screenshot_sw then
        fast_props['screenshot-sw'] = 'yes'
    end
    local wrote = with_properties(fast_props, capture)
    if not wrote then
        osd('screenshot failed (see the log)', 3)
        return
    end

    last_screenshot_path = png
    copy_image_to_clipboard(png)

    local caption = meta.caption(info, seconds)

    if mode == 'local' then
        osd('saved & copied ' .. shown)
        return
    end

    -- Uploading off, or on but unusable: the shot is still saved. Only the
    -- half-configured case is worth a one-time nudge; plain organiser mode
    -- says nothing beyond the filename.
    if not config.telegram_ready() then
        if config.telegram_incomplete() and not hinted then
            hinted = true
            osd('saved & copied ' .. shown .. ' \226\128\148 set bot_token and chat_id in script-opts/mpvshot.conf', 5)
        else
            osd('saved & copied ' .. shown)
        end
        return
    end

    local v = config.values
    local jpg = nil
    if v.upload_photos then
        jpg = paths.temp_jpeg()
        if jpg ~= nil then
            local ok = with_properties({ ['screenshot-jpeg-quality'] = tostring(v.jpeg_quality) }, function()
                return screenshot_to_file(jpg, flags)
            end)
            if not ok then
                paths.remove(jpg)
                jpg = nil
                msg.warn('no JPEG produced; the photo post will be skipped for this shot')
            end
        end
    end

    table.insert(queue, { png = png, jpg = jpg, caption = caption })
    osd(string.format('queued %s (%d)', shown, #queue))

    if debounce_timer then
        debounce_timer:kill()
    end
    if v.debounce > 0 then
        debounce_timer = mp.add_timeout(v.debounce, function() flush(false) end)
    else
        flush(false)
    end
end

--------------------------------------------------------------------------------
-- Flush
--------------------------------------------------------------------------------

local function chunks(items, size)
    local out = {}
    for i = 1, #items, size do
        local part = {}
        for j = i, math.min(i + size - 1, #items) do
            table.insert(part, items[j])
        end
        table.insert(out, part)
    end
    return out
end

--- Turn the queue into as few API calls as possible: one album per topic per
-- ten shots, or a plain sendPhoto/sendDocument for a lone shot.
local function build_jobs(entries)
    local v = config.values
    local photos, docs = {}, {}
    for _, entry in ipairs(entries) do
        if v.upload_photos and entry.jpg then
            table.insert(photos, { file = entry.jpg, caption = entry.caption, temp = true })
        end
        if v.upload_docs then
            table.insert(docs, { file = entry.png, caption = entry.caption })
        end
    end

    local jobs = {}
    for _, part in ipairs(chunks(photos, ALBUM_MAX)) do
        table.insert(jobs, telegram.photo_job(part, v.topic_photos))
    end
    for _, part in ipairs(chunks(docs, ALBUM_MAX)) do
        table.insert(jobs, telegram.document_job(part, v.topic_docs))
    end
    return jobs
end

function flush(sync)
    if debounce_timer then
        debounce_timer:kill()
        debounce_timer = nil
    end
    if #queue == 0 then
        return
    end

    local entries = queue
    queue = {}

    local jobs = build_jobs(entries)
    if #jobs == 0 then
        return
    end

    local count = #entries
    msg.info(string.format('flushing %d shot(s) as %d request(s)%s', count, #jobs, sync and ' (synchronous)' or ''))

    telegram.send(jobs, sync, function(ok, err)
        if ok then
            osd(string.format('posted %d shot%s', count, count == 1 and '' or 's'))
            if not sync then
                telegram.drain_outbox()
            end
        else
            osd('upload failed: ' .. tostring(err) .. ' (queued for retry)', 5)
        end
    end)
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

local function protected(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            msg.error(tostring(err))
            osd('internal error, see the log', 3)
        end
    end
end

-- A broken config must not stop the script from loading: it still saves
-- locally, and that is what keeps plain mpv error-free.
local loaded, load_err = pcall(config.load)
if not loaded then
    msg.error('config could not be read, falling back to defaults: ' .. tostring(load_err))
    config.values = config.defaults()
end

mp.add_key_binding('s', 'shot-subs', protected(function() take_screenshot('subs') end))
mp.add_key_binding('S', 'shot-nosubs', protected(function() take_screenshot('nosubs') end))
mp.add_key_binding('Ctrl+s', 'shot-local', protected(function() take_screenshot('local') end))
mp.add_key_binding('Alt+s', 'reveal-last', protected(reveal_last_screenshot))

-- Quitting right after a screenshot must not lose it.
mp.register_event('shutdown', protected(function() flush(true) end))

local telegram_state = config.telegram_ready() and 'on'
        or (config.telegram_incomplete() and 'on but unconfigured (no token/chat_id)' or 'off (organiser only)')
msg.info(string.format('ready \226\128\148 root=%s telegram=%s dry_run=%s',
        config.values.screenshot_root, telegram_state, tostring(config.values.dry_run)))

pcall(telegram.drain_outbox)
