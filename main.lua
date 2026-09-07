--- @sync peek
--- @since 26.8.15

local M = {}

-- root of recents vfs
local RECENT_URL_ROOT = Url("recents:///@/")

local XDG_DATA_HOME = os.getenv("XDG_DATA_HOME")
local DATA_HOME = XDG_DATA_HOME and Path.os(XDG_DATA_HOME) or Path.os(os.getenv("HOME")):join(".local/share")

-- path to recently-used.xbel (~/.local/share/recently-used.xbel by default)
local RECENTLY_USED = Url(DATA_HOME:join("recently-used.xbel"))

-- empty recently-used.xbel file
local RECENTLY_USED_TEMPLATE = [[
<?xml version="1.0" encoding="UTF-8"?>
<xbel version="1.0"
      xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks"
      xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info"
></xbel>
]]

local DEFAULT_DIR_MODE = tonumber("40700", 8)
local DEFAULT_FILE_MODE = tonumber("100444", 8)

---parse (subset of) iso 8601 datetime
---@param datetime string
---@return number?
function parse_iso8601(datetime)
  local year, month, day, hour, minute, seconds, subsecond = datetime:match(
    "(%d+)%-(%d+)%-(%d+)T(%d+)%:(%d+)%:(%d+)%.?(%d*)Z?")
  if not year or not month or not day or not hour or not minute or not seconds then
    return nil
  end

  -- os.time() always return local time, subtract local unix time to get UTC
  local unix_time = os.time { year = 1970, month = 1, day = 1, hour = 0, isdst = false }

  local timestamp = os.time { year = year, month = month, day = day, hour = hour, min = minute, sec = seconds, isdst = false }
  local subsec = subsecond and tonumber(subsecond) or 0.0

  return timestamp + subsec / 1000. - unix_time
end

---format timestamp as iso 8601
---@param timestamp number
---@return string
local function iso_8601_timestamp(timestamp)
  local ms = math.floor((timestamp % 1) * 1000)
  local epochSeconds = math.floor(timestamp)
  return os.date("!%Y-%m-%dT%T", epochSeconds) .. "." .. ms .. "Z"
end

---get record key from recents url
---@param recents_url Url
---@return string?
local function recents_record_key(recents_url)
  if recents_url.spec.scheme ~= "recents" then
    ya.err(recents_url, "is not recents", recents_url.spec.scheme)
    return nil
  end

  local domain = recents_url.spec.domain
  if domain == "" then
    ya.err(recents_url, "has no domain")
    return nil
  end

  return domain
end

-- convert local file url to recents url of the form "recents:///<path escaped>/@/<file name>"
---@param url Url
---@return Url?
local function fs_to_recents_url(url)
  if not url.spec.is_regular then
    ya.err(url, "is not regular")
    return nil
  end
  if not url.is_absolute then
    ya.err(url, "is not absolute")
    return nil
  end

  local name = url.name
  if not name then
    ya.err("no name for", url)
    return nil
  end

  return RECENT_URL_ROOT:join(name):into_domain(tostring(url.path))
end

-- TODO: pares applications and show in custom spotter
---@class (exact) Record
---@field uri Url
---@field visited number?
---@field modified number?
---@field added number?

--- Record to File
---@param record Record
---@return File
local function rec_to_file(record)
  local backing = record.uri
  local cha = Cha {
    mode = DEFAULT_FILE_MODE,
    btime = record.added,
    atime = record.visited,
    mtime = record.modified,
    ctime = record.modified,
  }
  return File {
    cha = cha,
    url = fs_to_recents_url(backing),
    backing = backing.path,
  }
end

---@type fun(): table<string, Record>
local get_all_state_records = ya.sync(function(state)
  -- need to deep clone the map
  ---@type table<string, Record>
  local records = {}
  for k, v in pairs(state.records or {}) do
    records[k] = {
      uri = Url(v.uri), -- clone
      visited = v.visited,
      added = v.added,
      modified = v.modified
    }
  end
  return records
end)

---@type fun(records: table<string, Record>)
local set_state_records = ya.sync(function(state, records)
  state.records = records
end)
--- get Record for url
---@type fun(recents_url: Url): Record?
local get_record_for_recents = ya.sync(function(state, recents_url)
  local key = recents_record_key(recents_url)
  if not key or not state.records then
    return nil
  end
  local v = state.records[key]
  if not v then
    return nil
  end
  return {
    uri = Url(v.uri),
    visited = v.visited,
    added = v.added,
    modified = v.modified
  }
end)
---@type fun(record_key: string)
local remove_state_record = ya.sync(function(state, record_key)
  state.records[record_key] = nil
end)

---@type fun(): boolean
local get_state_records_init = ya.sync(function(state)
  return state.records_init == true -- handles nil
end)
---@type fun(init: boolean)
local set_state_records_init = ya.sync(function(state, init)
  state.records_init = init
end)

---@type fun(): integer
local get_state_recently_used_mtime = ya.sync(function(state)
  return state.recently_used_mtime or 0
end)
---@type fun(mtime: integer)
local set_state_recently_used_mtime = ya.sync(function(state, mtime)
  state.recently_used_mtime = mtime
end)

-- seperator for xmlstarlet output
local FIELD_SPERATOR = "|"

-- url scheme in recently-used
local LOCAL_URI_SCHEME = "file"

---Show error msg
---@param content string
---@param ... any
---@return Error
local function fail(content, ...)
  local msg = string.format(content, ...)
  ya.err(msg)
  ya.notify { title = "Recents", content = msg, timeout = 5, level = "error" }
  return Err(msg)
end

---Run a shell command, return stdout on success, show error on failure
---@param cmd string
---@param stdin string?
---@param ... any
---@return string?, Error?, Status?
local function run_cmd(cmd, stdin, ...)
  local fmt_cmd = function(cmd, ...)
    local s = { cmd }
    for _, arg in pairs(...) do
      s[#s + 1] = "'" .. arg .. "'"
    end
    return "`" .. table.concat(s, " ") .. "`"
  end

  -- ya.dbg("Running", fmt_cmd(cmd, ...))

  local child, err = Command(cmd):arg(...):stdin(Command.PIPED):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
  if not child or err then
    return nil, fail("Failed to spawn %s, error: %s", fmt_cmd(cmd, ...), err)
  end

  if stdin then
    child:write_all(stdin)
    child:flush() -- need to flush after write_all
  end
  local output, err = child:wait_with_output()

  if err then
    return nil, fail("Failed to run %s, error: %s", fmt_cmd(cmd, ...), err)
  end
  if not output then
    ya.dbg("no output for " .. fmt_cmd(cmd, ...))
    return "", nil
  end
  if not output.status.success then
    ya.dbg("status is " .. output.status.code .. " for " .. fmt_cmd(cmd, ...))
  end
  return output.stdout, nil, output.status
end

---Run xmlstarlet
---@param ... any
---@return string?, Error?, Status?
local function xmlstarlet(...)
  return run_cmd("xmlstarlet", nil, ...)
end

---Run xmlstarlet
---@param stdin string
---@param ... any
---@return string?, Error?, Status?
local function xmlstarlet_stdin(stdin, ...)
  return run_cmd("xmlstarlet", stdin, ...)
end

---@return Error?
local function init_records()
  if get_state_records_init() then
    -- use cached
    return nil
  end
  set_state_records_init(true)

  --- check if recently-used file exists
  if not fs.cha(RECENTLY_USED) then
    return nil
  end

  -- query recent files
  local stdout, err = xmlstarlet {
    "sel",
    "--text",
    "--template",
    "--match",
    ("/xbel/bookmark[starts-with(@href, '%s://')]"):format(LOCAL_URI_SCHEME),

    -- sort by visited (ISO-8601 timestamps)
    "--sort",
    "D:T:-",
    "@visited",

    -- print fields
    "-v",
    "@href",
    "-o",
    FIELD_SPERATOR,
    "-v",
    "@visited",
    "-o",
    FIELD_SPERATOR,
    "-v",
    "@modified",
    "-o",
    FIELD_SPERATOR,
    "-v",
    "@added",

    "-n",
    tostring(RECENTLY_USED),
  }
  if err or not stdout then
    return err
  end

  -- map field index to field name
  local FIELD_NAMES = {
    "uri",
    "visited",
    "modified",
    "added"
  }

  -- update records
  local records = {}
  local FIELD_PAT = ("([^%s]+)"):format(FIELD_SPERATOR)
  for line in stdout:gmatch("[^\n]+") do
    local record = {}
    local i = 1
    for field in line:gmatch(FIELD_PAT) do
      local field_name = FIELD_NAMES[i]
      if field_name == "uri" then
        -- change local:// to regular:// scheme and parse url
        record[field_name] = Url(field:gsub("^file", "regular", 1))
      else
        -- other fields  are iso timestamps
        record[field_name] = parse_iso8601(field)
      end

      i = i + 1
    end
    records[tostring(record.uri.path)] = record
  end
  set_state_records(records)

  return nil
end

-- convert recents url to local url
---@param recents_url Url
---@return Url?
local function recents_to_local(recents_url)
  -- find record
  local record = get_record_for_recents(Url(recents_url)) -- need to clone here
  if not record then
    ya.dbg("no record for", recents_url)
    return nil
  end

  return record.uri
end

--- convert a regular url to a xpath
---@param local_url Url
---@return string?, Error?
local function local_url_to_xpath(local_url)
  local href = ("%s://%s"):format(LOCAL_URI_SCHEME, tostring(local_url.path))
  local escaped, err = xmlstarlet { "esc", href }
  if not escaped or err then
    return nil, err
  end
  return escaped:match("(.*)\n$"), nil
end

---@param xpath string
---@return string
local function xpath_quoted(xpath) return ya.quote(xpath) end

---@param local_url Url
---@return Error?
local function add_recent(local_url)
  local href, err = local_url_to_xpath(local_url)
  if not href or err then
    return err
  end

  local timestamp_formated = iso_8601_timestamp(ya.time())

  -- query mime
  local next = require("mime.local"):fetch({
    files = { File {
      cha = fs.cha(local_url),
      url = local_url
    } }
  })
  local _, result = next()
  local mime = result[1] or "text/plain"

  local bookmark_xpath = ("/xbel/bookmark[@href=%s]"):format(xpath_quoted(href))

  -- need multiple calls here to work around https://martin7th.github.io/xmlstarlet-notes/#namespaces-insert-issue
  local update_bookmark_cmd = {
    "ed",

    -- create bookmark entry if it's missing
    "-s", ("/xbel[not(bookmark[@href=%s])]"):format(xpath_quoted(href)), "-t", "elem", "-n", "bookmark",

    -- add href attr (if bookmark was missing)
    "-s", "$prev", "-t", "attr", "-n", "href", "-v", href,

    -- add added/modifed/visited attr (if bookmark was missing)
    "-s", "$prev/..", "-t", "attr", "-n", "added", "-v", timestamp_formated,
    "-s", "$prev/..", "-t", "attr", "-n", "modified",
    "-s", "$prev/..", "-t", "attr", "-n", "visited",

    -- update modified and visited
    "-u", bookmark_xpath .. "/@modified", "-v", timestamp_formated,
    "-u", bookmark_xpath .. "/@visited", "-v", timestamp_formated,

    -- add bookmark:applications if missing
    "-s", bookmark_xpath .. "[not(info)]", "-t", "elem", "-n", "info",
    "-s", bookmark_xpath .. "/info[not(metadata)]", "-t", "elem", "-n", "metadata",
    "-s", "$prev", "-t", "attr", "-n", "owner", "-v", "http://freedesktop.org",
    "-s", "$prev/..", "-t", "elem", "-n", "mime:mime-type",
    "-s", "$prev", "-t", "attr", "-n", "type", "-v", mime,
    "-a", "$prev/..", "-t", "elem", "-n", "bookmark:applications",

    tostring(RECENTLY_USED),
  }


  local add_app_cmd = {
    "ed",

    -- add bookmark entry for Yazi if it doesn't exist
    "-s",
    bookmark_xpath .. '/info/metadata/bookmark:applications[not(bookmark:application/@name="Yazi")]',
    "-t", "elem", "-n", "bookmark:application",

    -- add name, exec, modified and count
    "-s", "$prev", "-t", "attr", "-n", "name", "-v", "Yazi",
    "-s", "$prev/..", "-t", "attr", "-n", "exec", "-v", "'yazi %f'", -- yazi doesn't understand 'fill://' Uris, use path instead
    "-s", "$prev/..", "-t", "attr", "-n", "modified",
    "-s", "$prev/..", "-t", "attr", "-n", "count", "-v", "0",
  }

  local app_bookmark_xpath = bookmark_xpath ..
      "/info/metadata/bookmark:applications/bookmark:application[@name='Yazi']"

  local update_app_cmd = {
    "ed",

    "-u", app_bookmark_xpath .. "/@modified", "-v", timestamp_formated,
    "-u", app_bookmark_xpath .. "/@count", "-x", ". + 1"
  }


  -- make sure file exists
  local fd, err = fs.access()
      :create_new(true)
      :write(true)
      :open(RECENTLY_USED)
  if fd and not err then
    -- create default of it does not
    fd:write_all(RECENTLY_USED_TEMPLATE)
    fd:flush()
    ya.drop(fd)
  end

  local stdout, err, status = xmlstarlet(update_bookmark_cmd)
  if err or not stdout or not status or not status.success then
    return err or Err("failed to run update_bookmark")
  end
  local stdout, err, status = xmlstarlet_stdin(stdout, add_app_cmd)
  if err or not stdout or not status or not status.success then
    return err or Err("failed to run add_app")
  end
  local stdout, err, status = xmlstarlet_stdin(stdout, update_app_cmd)
  if err or not stdout or not status or not status.success then
    return err or Err("failed to run update_app")
  end

  -- there is not commonly used locking mechanism when accessing recently-used.xbel unfortunately (at least gtk does not use one)
  -- best we can do is mimic what gtk does and use a write to tmp file + mv
  -- TODO: might want to check if mtime changed between reading and now and bail / retry if it did
  -- TODO: do this outside of lua to reduce chance of race with other recently used access (there is quite a bit of time between the write and rename syscalls calls here)
  local tmp = Url(os.tmpname())
  fs.write(tmp, stdout)
  fs.rename(tmp, RECENTLY_USED)
end

-- VFS


-- borrowed from https://github.com/sxyazi/yazi/blob/5f901b886b14de1f17460b6e52e9de5d67f8aba9/yazi-plugin/preset/plugins/trash.lua#L49-L64
function M:Absolute(job)
  local url = job.url
  if url.is_absolute then
    return fs.clean_url(url), nil
  end

  local cwd, err = fs.cwd()
  if not cwd then
    return nil, err
  end

  local root = cwd.path
  while root.parent do
    root = root.parent
  end
  return fs.clean_url(url:join(root:join(url.path)))
end

function M:Canonicalize(job) return self:Absolute(job) end

function M:Casefold(job) return job.url end

function M:SymlinkMetadata(_) return Cha { mode = DEFAULT_FILE_MODE } end

function M:Metadata(job) return self:SymlinkMetadata(job) end

function M:File(job)
  init_records()
  local record = get_record_for_recents(job.url)
  return record and rec_to_file(record) or nil
end

function M:ReadDir(job)
  if job.url.name then
    ya.dbg("ignoring read for", job.url)
    return {}
  end

  if job.url.parent then
    ya.dbg("ignoring reading recents subdir", job.url)
    return {}
  end

  init_records()

  -- reading root, return all records
  local dir_entries = {}
  for _, record in pairs(get_all_state_records()) do
    local file = rec_to_file(record)
    dir_entries[#dir_entries + 1] = {
      cha = file.cha,
      file = file,
    }
  end
  return dir_entries, nil
end

function M:Revalidate(job)
  local url = job.file.url
  -- ya.dbg("revalidate ", url)

  if not url.parent then
    -- only check recently-used file when revalidating root

    -- check if recently used file was updated
    local cha = fs.cha(RECENTLY_USED)
    if cha and cha.mtime then
      if cha.mtime == get_state_recently_used_mtime() then
        -- no need to update
        return nil
      end
      set_state_recently_used_mtime(cha.mtime)
    end

    -- need to update
    set_state_records_init(false)

    return File {
      cha = Cha { mode = DEFAULT_DIR_MODE },
      url = url,
    }
  end

  return File {
    cha = Cha { mode = DEFAULT_DIR_MODE },
    url = url,
  }
end

function M:RemoveFile(job)
  local local_url = recents_to_local(job.url)
  if not local_url then
    return nil
  end

  local href, err = local_url_to_xpath(local_url)
  if not href or err then
    return false, err
  end

  -- remove from recently-used file
  -- TODO: more robust file update
  local _, err = xmlstarlet {
    "ed",
    "--inplace",
    "--delete",
    ("/xbel/bookmark[@href=%s]"):format(xpath_quoted(href)),
    tostring(RECENTLY_USED),
  }
  if err then
    return false, err
  end

  -- remove from map
  local key = recents_record_key(job.url)
  if key then
    remove_state_record(key)
  else
    ya.err("couldn't find key for", job.url)
  end

  return true, nil
end

function M:Trash(_)
  local msg = "Trash is not supported, use Remove instead";
  ya.notify { title = "Recents", content = msg, timeout = 2, level = "warn" }
  return Error.fs {
    kind = "Other",
    message = msg,
  }
end

-- called after RemoveFile, ignore
function M:RemoveDir(_) return true, nil end

function M:provide(job)
  -- ya.dbg("request", job)

  local fn = self[job.op]
  if not fn then
    return nil, fail("Unsupported recent VFS operation: %s", tostring(job.op))
  end

  local res = fn(self, job)
  -- ya.dbg("response", res)
  return res
end

--- borrowed from https://github.com/yazi-rs/plugins/blob/4dc7f1b6458c2578f4494f10d468c68c1082214f/chmod.yazi/main.lua#L3-L12
---@type fun(): Url[]
local selected_or_hovered = ya.sync(function()
  local tab, urls = cx.active, {}
  for i, f in pairs(tab.selected) do
    urls[i] = f.url
  end
  if #urls == 0 and tab.current.hovered then
    urls[1] = tab.current.hovered.url
  end
  return urls
end)

function M:entry(job)
  -- ya.dbg("args: ", job.args)

  ---@type string?
  local cmd = job.args[1]

  if not cmd then
    ya.emit("cd", { RECENT_URL_ROOT })
    return
  end

  if cmd == "modify" then
    local update_state = false
    for _, url in pairs(selected_or_hovered()) do
      ---@type Url?
      local local_url = nil
      if url.spec.is_regular then
        local c = fs.cha(url)
        if c and not (c.is_dir or c.is_dir or c.is_block or c.is_char or c.is_sock or c.is_fifo) then -- no .is_file()
          local_url = url
        end
      elseif url.spec.scheme == "recents" then
        local record = get_record_for_recents(url)
        local_url = record and record.uri
      end

      if local_url then
        local err = add_recent(local_url)
        if err then
          return ya.err(err)
        end
        update_state = true
      end
    end

    -- update state
    if update_state then
      set_state_records_init(false)
    end

    return
  end

  return fail("unexpected cmd: %s", cmd)
end

-- previewer and preloader borrowed from trash plugin (https://github.com/sxyazi/yazi/blob/5f901b886b14de1f17460b6e52e9de5d67f8aba9/yazi-plugin/preset/plugins/trash.lua)

local function match(job, rules)
  local mime = job.mime:match("^recents/(.+)")
  if not mime then
    return
  end
  for _, rule in pairs(rules:match { file = job.file, mime = mime }) do
    return rule, mime
  end
end

function M:peek(job)
  local rule, mime = match(job, rt.plugin.previewers)
  if not rule then
    return
  end

  job.mime, job.args = mime, rule.args
  ya.async(function()
    local chunk, err = ya.chunk(rule.name)
    if not chunk then
      ya.err(err)
    elseif chunk.sync_peek then
      ya.emit("plugin", { rule.name, job, method = "peek", scope = rt.scope() })
    else
      ya.async_blocking(function(cx) require(cx.name):peek(cx.job) end, { name = rule.name, job = job }):wait()
    end
  end)
end

function M:seek(job)
  local rule, mime = match(job, rt.plugin.previewers)
  if not rule then
    return
  end

  job.mime, job.args = mime, rule.args
  ya.emit("plugin", { rule.name, job, method = "seek", scope = rt.scope() })
end

function M:preload(job)
  local rule, mime = match(job, rt.plugin.preloaders)
  if not rule then
    return true
  end

  job.mime, job.args = mime, rule.args
  return require(rule.name):preload(job)
end

-- fetcher borrowed from mime-trash
-- see https://github.com/sxyazi/yazi/blob/5f901b886b14de1f17460b6e52e9de5d67f8aba9/yazi-plugin/preset/plugins/mime-trash.lua#L3-L29
function M:fetch(job)
  return ya.co(function()
    local updates = {}
    local flush = ya.throttle(0.3, function()
      if next(updates) then
        ya.emit("update_mimes", { updates = updates })
        updates = {}
      end
    end)

    local next = require("mime.local"):fetch(job)
    local file, result = next()
    while file do
      local mime = type(result[1]) == "string" and "recents/" .. result[1]
      if mime then
        result[1] = mime
      end

      if coroutine.yield(file, result) and not file.cha.is_dummy then
        updates[file.url] = mime
        flush()
      end
      file, result = next()
    end
    flush(true)
  end)
end

return M
