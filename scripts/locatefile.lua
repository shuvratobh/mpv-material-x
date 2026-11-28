-- locatefile.lua — reveal current file in OS file manager or open stream URL

local msg = require('mp.msg')
local mputils = require('mp.utils')

local function is_url(path)
  return path ~= nil and (path:match('^https?://') ~= nil or path:match('^[%a][%w+.-]*://') ~= nil)
end

local function is_windows()
  return os.getenv('windir') ~= nil or package.config:sub(1, 1) == '\\'
end

local function is_macos()
  local homedir = os.getenv('HOME')
  return homedir ~= nil and homedir:sub(1, 6) == '/Users'
end

local function resolve_local_path(path)
  if is_windows() then
    path = path:gsub('/', '\\')
    local is_abs = path:match('^%a:\\') or path:match('^\\\\')
    if not is_abs then
      local cwd = mputils.getcwd()
      if cwd and cwd ~= '' then
        path = mputils.join_path(cwd, path):gsub('/', '\\')
      end
    end
    return path
  end

  if path:sub(1, 1) ~= '/' then
    local cwd = mputils.getcwd()
    if cwd and cwd ~= '' then
      path = mputils.join_path(cwd, path)
    end
  end
  return path
end

-- Fast Win32 ShellExecuteW via LuaJIT FFI (0ms, no console, Unicode-safe)
local win32_shell_open = nil
if is_windows() then
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
        -- SW_SHOWNORMAL = 1; ShellExecuteW returns > 32 cast as HINSTANCE on success
        local res = tonumber(ffi.cast('intptr_t', shell32.ShellExecuteW(nil, op, file, params, nil, 1)))
        return res ~= nil and res > 32
      end
    end
  end
end

local function ps_quote(s)
  return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local function locate_current_file()
  local path = mp.get_property('path')
  if not path or path == '' then
    mp.osd_message('Locate: nothing playing', 2)
    return
  end

  if is_url(path) then
    mp.osd_message('Open URL\n' .. path, 3)
    if is_windows() then
      if not (win32_shell_open and win32_shell_open(path, nil)) then
        mp.command_native_async({
          name = 'subprocess',
          playback_only = false,
          detach = true,
          args = { 'powershell.exe', '-NoProfile', '-WindowStyle', 'Hidden', '-Command', '& { param($u) Start-Process $u } ' .. ps_quote(path) },
        })
      end
    elseif is_macos() then
      mp.command_native_async({ name = 'subprocess', playback_only = false, detach = true, args = { 'open', path } })
    else
      mp.command_native_async({ name = 'subprocess', playback_only = false, detach = true, args = { 'xdg-open', path } })
    end
    return
  end

  local full_path = resolve_local_path(path)
  mp.osd_message('Browse\n' .. full_path, 3)

  if is_windows() then
    local info = mputils.file_info(full_path)
    local params
    if info and not info.is_dir then
      params = '/select,"' .. full_path:gsub('"', '""') .. '"'
    else
      local dir = full_path:match('^(.*)\\[^\\]+$') or full_path
      params = '"' .. dir:gsub('"', '""') .. '"'
    end

    if win32_shell_open and win32_shell_open('explorer.exe', params) then
      return
    end

    -- Fallback using named parameter (& { param($p) ... }) so PowerShell -Command receives path properly
    mp.command_native_async({
      name = 'subprocess',
      playback_only = false,
      detach = true,
      args = {
        'powershell.exe',
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-Command',
        [[& { param($p) if (Test-Path -LiteralPath $p) { Start-Process explorer.exe -ArgumentList ('/select,"' + ($p -replace '"', '""') + '"') } else { $d = Split-Path -LiteralPath $p -Parent; if ($d -and (Test-Path -LiteralPath $d)) { Start-Process explorer.exe -ArgumentList ('"' + $d + '"') } else { Start-Process explorer.exe } } } ]] .. ps_quote(full_path),
      },
    })
  elseif is_macos() then
    mp.command_native_async({ name = 'subprocess', playback_only = false, detach = true, args = { 'open', '-a', 'Finder', '-R', full_path } })
  else
    mp.command_native_async({
      name = 'subprocess',
      playback_only = false,
      detach = true,
      args = {
        'dbus-send', '--print-reply', '--dest=org.freedesktop.FileManager1',
        '/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1.ShowItems',
        'array:string:file:' .. full_path, 'string:',
      },
    })
  end
end

mp.add_key_binding('.', 'locate-current-file', locate_current_file)
