local async = require('jjsigns.async')
local config = require('jjsigns.config').config
local debounce_trailing = require('jjsigns.debounce').debounce_trailing
local jj = require('jjsigns.jj')
local log = require('jjsigns.debug.log')
local util = require('jjsigns.util')
local Path = util.Path

local uv = vim.uv or vim.loop ---@diagnostic disable-line: deprecated

--- Repository abstraction for native (non-colocated) jj workspaces, where git is
--- not available. Mirrors the parts of `Jjsigns.Repo` that jjsigns consumes,
--- backed entirely by `jj` commands.
---
--- @class Jjsigns.JJRepo
--- @field toplevel string Workspace root (contains `.jj`)
--- @field gitdir string `<toplevel>/.jj` — used as the cache key / watch root
--- @field commondir string Same as gitdir
--- @field detached boolean Always false
--- @field vcs 'jj'
--- @field abbrev_head string jj working-copy change (bookmark or change id)
--- @field username? string
--- @field head_oid? string Commit id of `@-` (the diff base)
--- @field private _lock Jjsigns.async.Semaphore
--- @field private _refs integer
--- @field private _update_callbacks fun()[]
--- @field private _watcher? uv.uv_fs_event_t
--- @field private _notify? fun()
local M = {}

--- @type table<string, Jjsigns.JJRepo?>
local repo_cache = setmetatable({}, { __mode = 'v' })

--- @param revision? string
--- @return boolean
function M.from_tree(revision)
  return revision ~= nil and not vim.startswith(revision, ':')
end

--- @async
--- @private
function M:_refresh_head()
  self.head_oid = jj.commit_id(self.toplevel, '@-')
  self.abbrev_head = jj.head(self.toplevel) or self.abbrev_head
end

--- @private
function M:_start_watcher()
  if not config.watch_gitdir.enable then
    return
  end

  -- Every jj operation (new/squash/abandon/edit/rebase/describe/snapshot)
  -- writes a fresh head into `.jj/repo/op_heads/heads`, so watching that
  -- directory catches all working-copy/parent moves. Our own reads use
  -- `--ignore-working-copy`, so they never create operations (no feedback loop).
  local op_heads = Path.join(self.gitdir, 'repo', 'op_heads', 'heads')
  if not Path.is_dir(op_heads) then
    log.dprintf('jj op heads dir not found: %s', op_heads)
    return
  end

  local handle, err = uv.new_fs_event()
  if not handle then
    log.eprintf('failed to create jj fs_event: %s', err or '?')
    return
  end
  self._watcher = handle

  local weak_self = util.weak_ref(self)

  self._notify = debounce_trailing(200, function()
    local self0 = weak_self.ref
    if not self0 then
      return
    end
    async
      .run(function()
        self0:_refresh_head()
        async.schedule()
        for _, cb in ipairs(self0._update_callbacks) do
          local ok, cberr = pcall(cb)
          if not ok then
            log.eprintf('jj repo watcher callback error: %s', cberr)
          end
        end
      end)
      :raise_on_error()
  end)

  handle:start(op_heads, {}, function(fs_err)
    local self0 = weak_self.ref
    if not self0 or not self0._notify then
      return
    end
    if fs_err then
      log.dprintf('jj op heads watch error: %s', fs_err)
      return
    end
    self0._notify()
  end)
  log.dprintf('Watching jj op heads %s', op_heads)
end

--- @async
--- @param toplevel string
--- @return Jjsigns.JJRepo
function M._new(toplevel)
  --- @type Jjsigns.JJRepo
  local self = setmetatable({}, { __index = M })
  self.toplevel = toplevel
  self.gitdir = Path.join(toplevel, '.jj')
  self.commondir = self.gitdir
  self.detached = false
  self.vcs = 'jj'
  self._lock = async.semaphore(1)
  self._refs = 0
  self._update_callbacks = {}

  self.username = jj.username(toplevel)
  self.head_oid = jj.commit_id(toplevel, '@-')
  self.abbrev_head = jj.head(toplevel) or ''

  self:_start_watcher()

  return self
end

--- @async
--- @param toplevel string
--- @return Jjsigns.JJRepo
function M.get(toplevel)
  -- Resolve symlinks so the root matches realpath-resolved buffer paths (e.g.
  -- macOS /var -> /private/var); relpath comparison depends on this.
  toplevel = vim.fs.normalize(uv.fs_realpath(toplevel) or toplevel)
  local repo = repo_cache[toplevel]
  if not repo then
    repo = M._new(toplevel)
    repo_cache[toplevel] = repo
  end
  repo:ref()
  return repo
end

function M:ref()
  self._refs = self._refs + 1
  return self
end

--- @private
function M:_close()
  repo_cache[self.toplevel] = nil
  self._notify = nil
  if self._watcher then
    if not self._watcher:is_closing() then
      self._watcher:stop()
      self._watcher:close()
    end
    self._watcher = nil
  end
end

function M:unref()
  if self._refs == 0 then
    return
  end
  self._refs = self._refs - 1
  if self._refs == 0 then
    self:_close()
  end
end

function M:has_watcher()
  return self._watcher ~= nil
end

--- @param callback fun()
--- @return fun() deregister
function M:on_update(callback)
  table.insert(self._update_callbacks, callback)
  return function()
    for i, cb in ipairs(self._update_callbacks) do
      if cb == callback then
        table.remove(self._update_callbacks, i)
        break
      end
    end
  end
end

--- @async
--- @generic R
--- @param fn async fun(): R...
--- @return R...
function M:lock(fn)
  return self._lock:with(fn)
end

--- `file` is always an absolute path here (resolved by the Obj constructor).
--- @param file string
--- @return string? relpath
function M:relpath(file)
  local nf = vim.fs.normalize(file)
  if nf == self.toplevel then
    return
  end
  if vim.startswith(nf, self.toplevel .. '/') then
    return nf:sub(#self.toplevel + 2)
  end
  -- Fall back to a symlink-resolved comparison (e.g. macOS /var vs /private/var)
  -- for paths that were not realpath-resolved upstream.
  local rf = uv.fs_realpath(file)
  if rf then
    rf = vim.fs.normalize(rf)
    if vim.startswith(rf, self.toplevel .. '/') then
      return rf:sub(#self.toplevel + 2)
    end
  end
end

--- @async
--- @param file string
--- @param revision? string
--- @return Jjsigns.Repo.LsFiles.Result? info
--- @return string? err
function M:file_info(file, revision)
  local relpath = self:relpath(file)
  if not relpath then
    return nil, ('%s is outside jj workspace %s'):format(file, self.toplevel)
  end

  -- The diff base is `@-` by default, or the requested revision.
  local base = M.from_tree(revision) and assert(revision) or '@-'

  --- @type Jjsigns.Repo.LsFiles.Result
  local result = {
    relpath = relpath,
    mode_bits = '100644',
    i_crlf = false,
    w_crlf = false,
  }

  -- A file present in the base is "tracked". `object_name` only needs to be a
  -- stable, base-dependent token: it gates untracked handling and per-buffer
  -- invalidation (which also keys off `head_oid`).
  if jj.path_exists_at(self.toplevel, base, relpath) then
    result.object_name = jj.commit_id(self.toplevel, base) or self.head_oid
  end

  return result
end

--- @async
--- Read file content for an object of the form `<rev>:<relpath>` (the form used
--- by the blame popup). The native backend never stores bare blob object names,
--- so anything without a `:` cannot be resolved and yields no content.
--- @param object string
--- @param encoding? string
--- @return string[] stdout, string? stderr
function M:get_show_text(object, encoding)
  local rev, relpath = object:match('^(.-):(.*)$')
  if not rev or not relpath or rev == '' then
    log.dprintf('jj get_show_text: cannot resolve object %s', object)
    return {}, nil
  end
  local stdout, stderr = jj.file_show(self.toplevel, rev, relpath, encoding)
  return stdout, stderr
end

--- @async
--- @param revision string
--- @param relpath string
--- @param encoding? string
--- @return string[] stdout, string? stderr
function M:get_show_text_at_revision(revision, relpath, encoding)
  local stdout, stderr = jj.file_show(self.toplevel, revision, relpath, encoding)
  return stdout, stderr
end

--- @async
--- @param base? string
--- @param include_untracked? boolean
--- @return {path:string, oldpath?:string, deleted?:boolean}[]
function M:files_changed(base, include_untracked)
  -- `base` of `:0`/index has no meaning in jj; treat it as the default (`@-`).
  local from = base ~= nil and base ~= ':0' and base or nil
  return jj.files_changed(self.toplevel, from)
end

--- jj has no gitattributes; report everything as unspecified.
--- @param _attr string
--- @param files string[]
--- @return table<string,'set'|'unset'|'unspecified'|string>
function M:check_attr(_attr, files)
  local ret = {} --- @type table<string,string>
  for _, f in ipairs(files) do
    ret[f] = 'unspecified'
  end
  return ret
end

--- Rename following is not implemented for the native jj backend.
--- @return table<string,string>
function M:diff_rename_status()
  return {}
end

--- Generic git command execution is unavailable in non-colocated jj
--- workspaces. Returns empty so dependent features degrade rather than error.
--- @param args string[]
--- @return string[] stdout, string? stderr, integer code
function M:command(args)
  log.dprintf('jj repo:command unsupported: %s', table.concat(args, ' '))
  return {}, nil, 0
end

return M
