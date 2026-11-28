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

-- Classification, captions and hashtags.
--
-- jellyfin-mpv-shim sets exactly one metadata property, force-media-title,
-- formatted by Video.get_proper_title() as "%s - s%de%.2d - %s" for episodes
-- and "Title (Year)" for movies, with " (Transcode)" appended while
-- transcoding. That makes rules 1 and 2 an exact match against a known
-- producer rather than guesswork.
--
-- Everything else is a filename, read the way a release parser reads one.
-- The approach is autobrr's (github.com/autobrr/autobrr, via moistari/rls):
-- normalise the separators, drop the bracketed metadata, then cut the title
-- at the first release tag. No code is taken from it — the tag list here is
-- much smaller, and only has to be good enough to find where a title ends
-- rather than to describe the release. That is what makes
-- "[SubsPlease] Show - 05 (1080p) [A1B2C3D4].mkv" and
-- "Show.Name.S01E05.1080p.WEB-DL.x264-GRP.mkv" both land on "Show".

local mp = require('mp')
local msg = require('mp.msg')
local config = require('config')

local this = {}

-- Extensions that make a URL tail worth parsing as a filename. A Jellyfin
-- stream URL ends in something like ".../Items/<guid>/Download?api_key=…",
-- whose "filename" is an API endpoint, not a title — running the episode and
-- movie patterns over that produces nonsense (a hex id yields "e1" -> S01E01).
local MEDIA_EXTENSIONS = {
    mkv = true, mp4 = true, m4v = true, avi = true, mov = true, webm = true,
    ts = true, m2ts = true, mts = true, wmv = true, flv = true, mpg = true,
    mpeg = true, ogv = true, ogm = true, rmvb = true, rm = true, vob = true,
    divx = true, asf = true, f4v = true, ['3gp'] = true,
}

-- The tokens a release name uses *after* the title: source, resolution,
-- codec, audio, language, platform. The first one marks where the name ends.
-- Deliberately excludes short or title-shaped words (dd, dv, max, final,
-- complete, remastered): cutting a real title short is worse than keeping a
-- tag. Resolutions, bit depths and version suffixes are matched by shape.
local RELEASE_TAGS = {}
for tag in ([[
    bluray blu-ray bdrip bdmv bdremux brrip bd dvdrip dvd hdtv hdrip pdtv
    web webrip web-dl webdl webhd uhd remux tvrip vodrip sdtv hdtvrip
    x264 x265 h264 h265 h.264 h.265 hevc avc av1 xvid divx vp9 hi10 hi10p
    aac ac3 eac3 ddp dts dtshd truehd atmos flac opus mp3 vorbis
    hdr hdr10 sdr 4k
    multi multisub multi-sub dual dual-audio subs subbed dubbed uncensored
    censored batch repack proper raw
    amzn nf dsnp hulu atvp crunchyroll funimation vrv
    eng ita jpn spa fre ger vostfr
    ass srt pgs
]]):gmatch('%S+') do
    RELEASE_TAGS[tag] = true
end

local DASH = '\226\128\148' -- em dash

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function nonempty(s)
    if type(s) == 'string' then
        s = trim(s)
        if s ~= '' then return s end
    end
    return nil
end

local function remove_extension(name)
    return (name:gsub('%.%w%w?%w?%w?$', ''))
end

local function collapse(s)
    return trim((s:gsub('%s+', ' ')))
end

-- media-title is already human-readable; only collapse whitespace.
local function clean_title(s)
    return nonempty((s:gsub('%s+', ' ')))
end

-- A bare 4-digit number in the plausible release-year range. Used both to
-- find the year and to stop the episode rules reading one as an episode.
local function year_like(text)
    if text == nil or #text ~= 4 then return false end
    local n = tonumber(text)
    return n ~= nil and n >= 1900 and n <= 2099
end

--------------------------------------------------------------------------------
-- Release names
--------------------------------------------------------------------------------

--- Scene and fansub separators become spaces.
-- Underscores always ("[gg]_Show_-_05"); dots only when the name has no
-- spaces of its own, so "Show.Name.S01E05" splits while "Show - 07.5" and
-- "Dr. Stone - 12" keep the dots that mean something.
local function normalise_separators(s)
    s = s:gsub('_', ' ')
    if not s:find(' ') then
        s = s:gsub('%.', ' ')
    end
    return collapse(s)
end

--- Drop bracketed metadata: group tags, CRC hashes, [1080p][Multi Sub].
-- A parenthesised year is the one thing inside brackets worth keeping.
local function strip_brackets(s)
    s = s:gsub('%[.-%]', ' ')
    s = s:gsub('%b()', function(block)
        return year_like(trim(block:sub(2, -2))) and block or ' '
    end)
    return collapse(s)
end

local function is_release_tag(token)
    token = token:lower()
    -- "x264-GRP" and "WEB-DL" are recognised by their head as well as whole.
    local head = token:match('^([%w%.]+)') or token
    return RELEASE_TAGS[token] == true
            or RELEASE_TAGS[head] == true
            or head:match('^%d%d%d%d?p$') ~= nil  -- 480p … 2160p
            or head:match('^%d+bits?$') ~= nil    -- 10bit
            or head:match('^v%d+$') ~= nil        -- v2
end

--- Keep everything up to the first release tag: "Show Name 1080p WEB" -> "Show Name".
-- The first token is never a tag, so a film called "Raw" survives.
local function cut_release_tags(s)
    local kept = {}
    for token in s:gmatch('%S+') do
        if #kept > 0 and is_release_tag(token) then break end
        table.insert(kept, token)
    end
    return table.concat(kept, ' ')
end

--- Separators left dangling once the episode marker was cut off the end.
local function clean_edges(s)
    return trim((s:gsub('^[%s%-%._~]+', ''):gsub('[%s%-%._~]+$', '')))
end

--- "Show Name 2023" / "Show Name (2023)" -> "Show Name".
local function strip_trailing_year(s)
    local head, year = s:match('^(.-)%s*%((%d%d%d%d)%)$')
    if head == nil then
        head, year = s:match('^(.-)%s+(%d%d%d%d)$')
    end
    if head and year_like(year) and trim(head) ~= '' then
        return trim(head)
    end
    return s
end

--- "Show S2", "Show Season 2", "Show 2nd Season" -> "Show", 2.
local function split_season(title)
    local head, n = title:match('^(.-)%s+[Ss](%d%d?)$')
    if head == nil then
        head, n = title:match('^(.-)%s+[Ss]eason%s+(%d%d?)$')
    end
    if head == nil then
        head, n = title:match('^(.-)%s+(%d%d?)%a%a%s+[Ss]eason$')
    end
    if head and trim(head) ~= '' then
        return trim(head), tonumber(n)
    end
    return title, nil
end

--- The release name with separators normalised and brackets removed.
local function release_name(base)
    return strip_brackets(normalise_separators(base))
end

--- The part of a release name that is the title.
local function release_title(prefix)
    return cut_release_tags(clean_edges(prefix))
end

--- The release year and where it starts, or nil.
-- A parenthesised year wins outright. Otherwise take the LAST year-like
-- token: scene naming puts the year after the title, and titles themselves
-- can contain one ("Blade Runner 2049 2017 2160p" -> 2017, not 2049).
local function find_year(name)
    local start, _, paren = name:find('%((%d%d%d%d)%)')
    if start and year_like(paren) then
        return paren, start
    end
    local year, position
    local from = 1
    -- Trailing sentinel so a year at the very end ("The Matrix 1999") still
    -- has the separator the pattern needs. Positions stay valid for `name`.
    local probe = name .. ' '
    while true do
        local s, _, candidate = probe:find('[%.%s](%d%d%d%d)[%.%s]', from)
        if s == nil then break end
        if year_like(candidate) then
            year, position = candidate, s
        end
        from = s + 1
    end
    return year, position
end

-- Episode markers, first match wins. `seasoned` rules carry their own season
-- number; the rest are absolute numbering and default to season 1 unless the
-- title itself names one ("Show S2 - 05"). A leading space is prepended
-- before matching, so every rule can demand a separator in front of the
-- marker without a special case for the start of the name.
local EPISODE_RULES = {
    -- "Show.S01E05", "Show S01 E05", "Show S1E5"
    { pattern = '^(.-)[%s%-%._][Ss](%d%d?%d?)%s*[Ee](%d%d?%d?%d?)', seasoned = true },
    -- "Show 1x05"
    { pattern = '^(.-)[%s%-%._](%d%d?)[xX](%d%d?%d?)', seasoned = true },
    -- Fansub and nyaa absolute numbering: "[Group] Show - 05", "Show - 07.5v2"
    { pattern = '^(.-)%s%-%s(%d%d?%d?%d?%.?%d?)' },
    -- "Show Episode 5", "Show EP05", "Show - Ep. 5"
    { pattern = '^(.-)[%s%-%._][Ee]pisode%s*(%d%d?%d?%d?)' },
    { pattern = '^(.-)[%s%-%._][Ee][Pp]%.?%s?(%d%d?%d?%d?)' },
    -- "Show - E05". Two digits minimum, or every stray "e" becomes an episode.
    { pattern = '^(.-)[%s%-%._][Ee](%d%d%d?%d?)' },
}

--- Read season/episode off a release name, or nil when it carries neither.
local function parse_episode(name)
    local probe = ' ' .. name
    for _, rule in ipairs(EPISODE_RULES) do
        local prefix, a, b = probe:match(rule.pattern)
        local season, episode
        if rule.seasoned then
            season, episode = a, b
        else
            -- "The Matrix - 1999" is not episode 1999 of anything.
            episode = (not year_like(a)) and a or nil
        end
        if prefix and episode then
            -- "Dated.Show.2023.S01E02": the year belongs to the series, not
            -- the name. A movie keeps its trailing year ("Blade Runner 2049"),
            -- so only the episode rules drop one.
            local title, title_season = split_season(strip_trailing_year(release_title(prefix)))
            if title ~= '' then
                return {
                    kind = 'local_episode',
                    series = title,
                    season = tonumber(season) or title_season or 1,
                    episode = tonumber(episode),
                }
            end
        end
    end
    return nil
end

--- Read a movie off a release name: a year, and no episode marker before it.
local function parse_movie(name)
    local year, position = find_year(name)
    if year == nil then
        return nil
    end
    local title = release_title(position > 1 and name:sub(1, position - 1) or name)
    if title == '' then
        return nil
    end
    return { kind = 'movie', movie = title, year = year }
end

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

--- Compact human time: M:SS, MM:SS, H:MM:SS past an hour.
function this.human_time(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds < 0 then seconds = 0 end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return string.format('%d:%02d:%02d', h, m, s)
    end
    return string.format('%d:%02d', m, s)
end

--- Filename time: always HH.MM.SS, since ':' is illegal on Windows.
function this.file_time(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds < 0 then seconds = 0 end
    return string.format('%02d.%02d.%02d',
            math.floor(seconds / 3600), math.floor((seconds % 3600) / 60), seconds % 60)
end

--- The configured category name for a kind, e.g. "TV". May be '' (disabled).
local function category_name(kind)
    local v = config.values
    if kind == 'jellyfin_episode' or kind == 'local_episode' then
        return v.tag_tv
    elseif kind == 'jellyfin_movie' or kind == 'movie' then
        return v.tag_movie
    elseif kind == 'clip' then
        return v.tag_clip
    end
    return v.tag_other
end

--- Reduce text to what Telegram accepts in a hashtag. May return ''.
local function clean_tag(text)
    return (tostring(text or '')
            :gsub("['\226\128\153]", '')      -- drop apostrophes, ASCII and typographic
            :gsub('[^%w_]', '_')
            :gsub('_+', '_')
            :gsub('^_+', '')
            :gsub('_+$', ''))
end

--- "Frieren: Beyond Journey's End" -> "#Frieren_Beyond_Journeys_End"
-- Telegram won't linkify a hashtag that starts with a digit, so those (and
-- anything that reduces to nothing) fall back to the kind's category name —
-- the same string the category tag uses, so the two collapse into one.
function this.hashtag(text, kind)
    local tag = clean_tag(text)
    if tag == '' or tag:match('^%d') then
        tag = clean_tag(category_name(kind))
        if tag == '' then
            tag = 'video'
        end
    end
    return '#' .. tag
end

--------------------------------------------------------------------------------
-- Classification
--------------------------------------------------------------------------------

--- Classify the currently playing file. Returns a table describing it.
-- Every property read is nil-guarded: during a network stream `path` is an
-- HTTP URL and `filename` is a URL tail, and either can be missing entirely.
function this.classify(media_title, path, filename)
    local title = nonempty(media_title)
    if title then
        -- the shim appends this while transcoding; it is not part of the name
        title = trim((title:gsub('%s*%(Transcode%)%s*$', '')))
    end
    path = path or ''
    local is_url = path:match('^https?://') ~= nil

    local raw = filename or ''
    if is_url then
        -- mpv keeps the query string in `filename`; it is never part of a name
        raw = raw:gsub('%?.*$', '')
    end
    local base = remove_extension(raw)
    local extension = raw:match('%.([%w]+)$')

    -- Filename-derived rules only make sense for a real media file: a local
    -- path, or a URL that actually ends in one.
    local filename_is_real = (not is_url)
            or (extension ~= nil and MEDIA_EXTENSIONS[extension:lower()] == true)
    if not filename_is_real then
        base = ''
    end

    -- 1. Jellyfin episode, straight from the shim's own formatter.
    if title then
        local series, season, episode, ep_title = title:match('^(.-) %- [sS](%d+)[eE](%d+) %- (.*)$')
        if series and trim(series) ~= '' then
            return {
                kind = 'jellyfin_episode',
                series = trim(series),
                season = tonumber(season),
                episode = tonumber(episode),
                ep_title = nonempty(ep_title),
            }
        end
    end

    -- 2. Jellyfin movie: "Title (Year)" over a network path.
    if title and is_url then
        local movie, year = title:match('^(.-) %((%d%d%d%d)%)$')
        if movie and trim(movie) ~= '' then
            return { kind = 'jellyfin_movie', movie = trim(movie), year = year }
        end
    end

    -- 3. Clip, checked before the release rules: OBS and videoclip both
    -- default to "YYYY-MM-DD HH-MM-SS", which rule 4 would misread. Keyed off
    -- the filename pattern, not the folder — one folder often holds both.
    if base ~= '' then
        local y, mo = base:match('^(%d%d%d%d)%-(%d%d)%-%d%d %d%d%-%d%d%-%d%d$')
        if y then
            return { kind = 'clip', label = base, month = y .. '-' .. mo }
        end
    end

    -- 4. A release name: episode markers first, then a bare year for a movie.
    local name = base ~= '' and release_name(base) or ''
    if name ~= '' then
        local episode = parse_episode(name)
        if episode then
            return episode
        end
        local movie = parse_movie(name)
        if movie then
            return movie
        end
    end

    -- 5. Same shape as rule 2 but over a local path, checked only after the
    -- filename rules have had their say. Rule 2 stays http-only as specified;
    -- this just rescues "Title (Year)" container metadata from Unsorted.
    if title then
        local movie, year = title:match('^(.-) %((%d%d%d%d)%)$')
        if movie and trim(movie) ~= '' and year_like(year) then
            return { kind = 'movie', movie = trim(movie), year = year }
        end
    end

    -- 6. Fallback. When nothing set a real title mpv reports the filename as
    -- media-title, extension and all — don't carry that into names, and for a
    -- URL don't carry the endpoint either. "stream" is better than "Download".
    local from_title = title and clean_title(title) or nil
    if from_title and filename and from_title == filename then
        from_title = filename_is_real and nonempty(base) or nil
    end
    local label = from_title
            or nonempty(cut_release_tags(name))
            or nonempty(base)
            or 'stream'
    return { kind = 'unknown', label = label }
end

--------------------------------------------------------------------------------
-- Captions
--------------------------------------------------------------------------------

--- "S01E05", or "S01E07.5" for the half-episodes fansubs ship.
function this.episode_code(info)
    local season = info.season or 1
    local episode = info.episode or 0
    if episode % 1 ~= 0 then
        return string.format('S%02dE%04.1f', season, episode)
    end
    return string.format('S%02dE%02d', season, episode)
end

--- Display name without the timestamp, e.g. "Show — S01E05".
function this.title_line(info)
    if info.kind == 'jellyfin_episode' or info.kind == 'local_episode' then
        return string.format('%s %s %s', info.series, DASH, this.episode_code(info))
    elseif info.kind == 'jellyfin_movie' or info.kind == 'movie' then
        if info.year then
            return string.format('%s (%s)', info.movie, info.year)
        end
        return info.movie
    end
    return info.label
end

--- The configurable category tag for a kind, or nil when switched off.
function this.category_tag(kind)
    -- Cleaned the same way as any other tag, so a stray space or accent can't
    -- produce something Telegram won't linkify.
    local tag = clean_tag(category_name(kind))
    if tag == '' or tag:match('^%d') then
        return nil
    end
    return '#' .. tag
end

--- Title line + hashtag line. Plain text, no deep link.
function this.caption(info, seconds)
    local head = string.format('%s %s %s', this.title_line(info), DASH, this.human_time(seconds))
    local subject
    if info.kind == 'jellyfin_episode' or info.kind == 'local_episode' then
        subject = info.series
    elseif info.kind == 'jellyfin_movie' or info.kind == 'movie' then
        subject = info.movie
    else
        subject = info.label
    end

    local tags = this.hashtag(subject, info.kind)
    local category = this.category_tag(info.kind)
    -- A generic title can reduce to the same tag as its category (#clip/#clip)
    if category and category:lower() ~= tags:lower() then
        tags = tags .. ' ' .. category
    end
    return head .. '\n' .. tags
end

--- Read mpv's properties and classify, nil-guarded throughout.
function this.current()
    local media_title = mp.get_property('media-title')
    local path = mp.get_property('path')
    local filename = mp.get_property('filename')
    local info = this.classify(media_title, path, filename)
    msg.debug(string.format('classified as %s (media-title=%q filename=%q)',
            info.kind, media_title or '', filename or ''))
    return info
end

return this
