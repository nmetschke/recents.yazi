--- @sync peek
--- @since 26.8.15

local M = {}

-- root of recents vfs
local RECENT_URL_ROOT = Url("recents:///")

local XDG_DATA_HOME = os.getenv("XDG_DATA_HOME")
local DATA_HOME = XDG_DATA_HOME and Path.os(XDG_DATA_HOME) or Path.os(os.getenv("HOME")):join(".local/share")

-- path to recently-used.xbel (~/.local/share/recently-used.xbel by default)
local RECENTLY_USED = Url(DATA_HOME:join("recently-used.xbel"))

---parse (subset of) iso 8601 datetime
---@param datetime string
---@return number?
function parse_iso8601(datetime)
  local year, month, day, hour, minute, seconds, subsecond = datetime:match(
    "(%d+)%-(%d+)%-(%d+)T(%d+)%:(%d+)%:(%d+)%.?(%d*)Z?")
  if not year or not month or not day or not hour or not minute or not seconds then
    return nil
  end
  local timestamp = os.time { year = year, month = month,
    day = day, hour = hour, min = minute, sec = seconds }
  local subsec = subsecond and tonumber(subsecond) or 0.0
  return timestamp + 1. / subsec
end

---get record key for local url
---@param url Url
---@return string
local function record_key(url)
  return ya.hash(tostring(url.path))
end

---get record key from recents url
---@param recents_url Url
---@return string?
local function recents_record_key(recents_url)
  return recents_url.parent and recents_url.parent.name
end

-- convert local file url to recents url of the form "recents:///<path hash>/<file name>"
---@param url Url
---@return Url?
local function fs_to_recents_url(url)
  ya.dbg("url is", url)

  if not url.spec.is_regular then
    ya.err(url, "is not regular")
    return nil
  end

  local name = url.name
  if not name then
    ya.err("no name for", url)
    return nil
  end

  return RECENT_URL_ROOT:join(record_key(url)):join(name)
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
    mode = tonumber("100400", 8),
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
  for k, v in pairs(state.records) do
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
  if not key then
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
  return state.records_init
end)
---@type fun(init: boolean)
local set_state_records_init = ya.sync(function(state, init)
  state.records_init = init
end)

---@type fun(): integer
local get_state_recently_used_mtime = ya.sync(function(state)
  return state.recently_used_mtime
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
---@param ... any
---@return string?, Error?
local function run_cmd(cmd, ...)
  local cmd_builder = Command(cmd):arg(...)
  local output, err = cmd_builder:output()

  local fmt_cmd = function(cmd, ...)
    local s = { "`", cmd, " " }
    for _, arg in pairs(...) do
      s[#s + 1] = ya.quote(arg == "\0" and "\\0" or arg)
      s[#s + 1] = " "
    end
    s[#s + 1] = "`"
    return table.concat(s)
  end

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
  return output.stdout, nil
end

---Run xmlstarlet
---@param ... any
---@return string?, Error?
local function xmlstarlet(...)
  return run_cmd("xmlstarlet", ...)
end

---@return Error?
local function init_records()
  if get_state_records_init() then
    -- use cached
    return nil
  end
  set_state_records_init(true)

  --- check if recently-used file exists
  local ok, err = fs.access():read(true):open(RECENTLY_USED)
  if not ok then
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
    records[record_key(record.uri)] = record
  end
  set_state_records(records)

  return nil
end

-- convert recents url to local url
---@param recents_url Url
---@return Url?
local function recents_to_local(recents_url)
  if recents_url.spec.scheme ~= "recents" then
    ya.err(recents_url, "is not recents", recents_url.spec.scheme)
    return nil
  end

  -- find record
  local record = get_record_for_recents(Url(recents_url)) -- need to clone here
  if not record then
    ya.dbg("no record for", recents_url)
    return nil
  end

  -- in case some other file is requested (e.g., recents///<path hash>/.git)
  if recents_url.path.name ~= record.uri.name then
    ya.dbg("record does not match filename", recents_url.path.name, record.uri.name)
    return nil
  end

  return record.uri
end
-- VFS

-- never called?
-- function M:Capabilities() return { symlink = false, hard_link = false, trash = false, copy_progressive = false }, nil end

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

function M:SymlinkMetadata(_) return Cha { mode = tonumber("100400", 8) } end

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

  init_records()

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

  -- check if root of fs
  if job.file.url.name then
    return nil, fail("unexpected Revalidate url %s", job.file.url)
  end

  return File {
    cha = Cha { mode = tonumber("40700", 8) },
    url = job.file.url,
  }
end

function M:RemoveFile(job)
  local local_url = recents_to_local(job.url)
  if not local_url then
    return nil
  end
  local href = ("%s://%s"):format(LOCAL_URI_SCHEME, tostring(local_url.path))
  -- ya.dbg("removing", ya.quote(href))

  -- remove from recently-used file
  local _, err = xmlstarlet {
    "ed",
    "--inplace",
    "--delete",
    ("/xbel/bookmark[@href=%s]"):format(ya.quote(href)), -- TODO: proper xpath safe quoting
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

function M:setup(state, opts)
  state.records = {}
  state.records_init = false
  state.recently_used_mtime = 0
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
