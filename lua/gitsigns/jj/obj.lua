local log = require('gitsigns.debug.log')
local util = require('gitsigns.util')
local JJRepo = require('gitsigns.jj.repo')

--- File object for native (non-colocated) jj workspaces. Mirrors the parts of
--- `Gitsigns.GitObj` that gitsigns consumes, backed by `jj` commands instead of
--- git. Staging is unsupported (jj has no index).
---
--- @class Gitsigns.JJObj
--- @field file string
--- @field encoding string
--- @field i_crlf? boolean
--- @field w_crlf? boolean
--- @field mode_bits string
--- @field revision? string
--- @field object_name? string
--- @field relpath? string
--- @field orig_relpath? string
--- @field repo Gitsigns.JJRepo
--- @field has_conflicts? boolean
--- @field private _closed boolean
--- @field private _gc userdata
local Obj = {}
Obj.__index = Obj

local M = { Obj = Obj }

--- @async
--- @param revision? string
--- @return string? err
function Obj:change_revision(revision)
  self.revision = util.norm_base(revision)
  return self:refresh()
end

--- @async
--- @param fn async fun()
function Obj:lock(fn)
  return self.repo:lock(fn)
end

--- @return boolean
function Obj:supports_staging()
  return false
end

--- @async
--- @return string? err
function Obj:refresh()
  local info, err = self.repo:file_info(self.file, self.revision)
  if err then
    log.eprint(err)
  end
  if not info then
    return err
  end

  self.relpath = info.relpath
  self.object_name = info.object_name
  self.mode_bits = info.mode_bits
  self.has_conflicts = info.has_conflicts
  self.i_crlf = info.i_crlf
  self.w_crlf = info.w_crlf
end

function Obj:close()
  if self._closed then
    return
  end
  self._closed = true
  self.repo:unref()
  self.repo = nil
end

--- @return boolean
function Obj:from_tree()
  return JJRepo.from_tree(self.revision)
end

--- @async
--- Content of the file at `revision` (defaults to the current base, `@-`).
--- @param revision? string
--- @param relpath? string
--- @return string[] stdout, string? stderr
function Obj:get_show_text(revision, relpath)
  relpath = relpath or self.relpath
  if not relpath then
    log.dprint('no relpath')
    return {}
  end

  local rev = revision or self.revision or '@-'
  local stdout, stderr = self.repo:get_show_text_at_revision(rev, relpath, self.encoding)
  -- jj does not perform CRLF conversion (i_crlf/w_crlf are always false), so no
  -- end-of-line fixup is required here.
  return stdout, stderr
end

--- @async
--- @param contents? string[]
--- @param lnum? integer|[integer, integer]
--- @param revision? string
--- @param opts? Gitsigns.BlameOpts
--- @return table<integer,Gitsigns.BlameInfo?>
--- @return table<string,Gitsigns.CommitInfo?>
function Obj:run_blame(contents, lnum, revision, opts)
  return require('gitsigns.jj.blame').run_blame(self, contents, lnum, revision, opts)
end

-- Staging operations have no meaning in jj (there is no index/staging area).

--- @return string? err
function Obj:stage_hunks()
  return 'Staging is not supported in jj repositories'
end

function Obj:stage_lines()
  log.dprint('Staging is not supported in jj repositories')
end

function Obj:unstage_file()
  log.dprint('Staging is not supported in jj repositories')
end

--- @async
--- @param file string Absolute path
--- @param revision? string
--- @param encoding string
--- @param toplevel string jj workspace root
--- @return Gitsigns.JJObj?
function M.new(file, revision, encoding, toplevel)
  local repo = JJRepo.get(toplevel)

  revision = util.norm_base(revision)

  local info, err = repo:file_info(file, revision)
  if not info then
    log.dprint(err or 'no file info')
    repo:unref()
    return
  end

  if info.relpath then
    file = util.Path.join(repo.toplevel, info.relpath)
  end

  local self = setmetatable({}, Obj)
  self.repo = repo
  self._closed = false
  self._gc = util.gc_proxy(function()
    self:close()
  end)
  self.file = util.cygpath(file, 'unix')
  self.revision = revision
  self.encoding = encoding

  self.relpath = info.relpath
  self.object_name = info.object_name
  self.mode_bits = info.mode_bits
  self.has_conflicts = info.has_conflicts
  self.i_crlf = info.i_crlf
  self.w_crlf = info.w_crlf

  return self
end

return M
