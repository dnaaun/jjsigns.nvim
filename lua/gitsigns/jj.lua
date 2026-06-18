local async = require('gitsigns.async')
local log = require('gitsigns.debug.log')
local util = require('gitsigns.util')

local asystem = async.wrap(3, require('gitsigns.system').system)

--- Low-level helpers for working with Jujutsu (jj) repositories.
---
--- jj colocates with git by default, keeping the git HEAD and index pinned to the
--- working-copy parent (`@-`). For those repositories gitsigns' existing git
--- backend already produces correct signs/diff/blame, and this module only adds
--- the jj-awareness on top: detecting jj repositories and rendering a
--- jj-flavoured "head" for the statusline.
---
--- For non-colocated workspaces (`--no-colocate`), where git is unavailable, the
--- functions here additionally drive a native backend (see `gitsigns.jj.repo`,
--- `gitsigns.jj.obj`, `gitsigns.jj.blame`) built entirely on `jj` commands.
---
--- The "staging" concept does not exist in jj, so staging actions are disabled
--- for jj repositories (see `Gitsigns.GitObj:supports_staging`).
---
--- All commands run with `--ignore-working-copy` so gitsigns never snapshots or
--- locks the user's working copy; we only ever read metadata.
local M = {}

--- Template used to render the "head" shown in the statusline for jj
--- repositories. Prefers local bookmarks pointing at the working-copy commit,
--- otherwise falls back to the (shortest unique, minimum 8 character) change id.
local HEAD_TEMPLATE =
  'if(local_bookmarks, local_bookmarks.map(|b| b.name()).join(","), change_id.shortest(8))'

--- @async
--- Run a jj command rooted at `toplevel`.
---
--- `--ignore-working-copy` is always passed so that gitsigns never snapshots or
--- locks the user's working copy; we only ever read metadata.
--- @param toplevel string
--- @param args string[]
--- @param spec? Gitsigns.Git.JobSpec
--- @return string[] stdout, string? stderr, integer code
function M.command(toplevel, args, spec)
  spec = spec or {}
  -- Run from the workspace root so jj resolves file path arguments relative to
  -- it (jj resolves paths against the cwd, not `--repository`).
  spec.cwd = util.cygpath(spec.cwd or toplevel)

  local cmd = {
    'jj',
    '--no-pager',
    '--color=never',
    '--ignore-working-copy',
    '--repository',
    toplevel,
  }
  vim.list_extend(cmd, args)

  if spec.text == nil then
    spec.text = true
  end

  -- Force a stable locale so output parsing is not affected by translations.
  spec.env = vim.tbl_extend('force', spec.env or {}, {
    LC_ALL = 'C',
    LANGUAGE = 'C',
  })

  -- jj may not be installed; system() can throw synchronously (ENOENT).
  local ok, obj = pcall(asystem, cmd, spec)
  async.schedule()

  if not ok then
    log.dprintf('jj command failed to run: %s', tostring(obj))
    return {}, tostring(obj), -1
  end
  --- @cast obj vim.SystemCompleted

  local stdout_lines = vim.split(obj.stdout or '', '\n')
  if spec.text and stdout_lines[#stdout_lines] == '' then
    stdout_lines[#stdout_lines] = nil
  end

  local stderr = obj.stderr ~= '' and obj.stderr or nil
  return stdout_lines, stderr, obj.code
end

--- Is `dir` the root of a (colocated) jj workspace?
--- This is a cheap filesystem check (no subprocess).
--- @param dir? string
--- @return boolean
function M.is_jj_root(dir)
  if not dir then
    return false
  end
  return util.Path.is_dir(util.Path.join(dir, '.jj'))
end

--- Walk up from `path` to find the enclosing jj workspace root (the directory
--- containing `.jj`). Cheap filesystem walk, no subprocess.
--- @param path? string
--- @return string? root
function M.find_root(path)
  if not path then
    return
  end
  local found = vim.fs.find('.jj', { path = path, upward = true, type = 'directory' })[1]
  if found then
    return vim.fs.normalize(vim.fs.dirname(found))
  end
end

--- Whether the native jj backend should handle a file at `cwd` whose nearest
--- enclosing jj workspace is `root`.
---
--- It should only when the nearest enclosing repository is a non-colocated jj
--- workspace. That means `root` has no `.git` of its own (colocated repos reuse
--- the git backend), and there is no nested git repository between `cwd` and
--- `root` that should take precedence (e.g. a vendored git repo inside a jj
--- workspace, or — in the test suite — a jj workspace created inside an outer
--- git checkout).
--- @param root string jj workspace root (the directory containing `.jj`)
--- @param cwd string
--- @return boolean
function M.prefers_native(root, cwd)
  -- Colocated: the git backend handles everything.
  if util.Path.is_dir(util.Path.join(root, '.git')) then
    return false
  end

  -- A `.git` at or below the jj root (closer to the file) is a nested git repo
  -- and wins. A `.git` above the jj root is an outer checkout that the (nearer)
  -- jj workspace shadows.
  local gitfound = vim.fs.find('.git', { path = cwd, upward = true })[1]
  if gitfound then
    local gitroot = vim.fs.normalize(vim.fs.dirname(gitfound))
    if gitroot == root or vim.startswith(gitroot, root .. '/') then
      return false
    end
  end

  return true
end

--- @async
--- Resolve a revset to a full git commit id.
--- @param root string
--- @param revset string
--- @return string? commit_id
function M.commit_id(root, revset)
  local out, _, code =
    M.command(root, { 'log', '--no-graph', '--revisions', revset, '--template', 'commit_id' })
  if code ~= 0 then
    return
  end
  local id = out[1]
  return id ~= nil and id ~= '' and id or nil
end

--- @async
--- @param root string
--- @return string? name
function M.username(root)
  local out = M.command(root, { 'config', 'get', 'user.name' }, { ignore_error = true })
  return out[1]
end

--- Build an exact repo-relative fileset expression for `jj file show`. The
--- `root:` prefix + quoted string literal makes it independent of cwd and safe
--- for paths containing spaces or fileset metacharacters. Backslashes and quotes
--- are escaped for the jj fileset string literal.
---
--- Note: `jj file annotate` takes a plain filesystem PATH (resolved against the
--- cwd, which we set to the workspace root), not a fileset, so it must NOT be
--- wrapped with this.
--- @param relpath string
--- @return string
local function fileset(relpath)
  local escaped = relpath:gsub('\\', '\\\\'):gsub('"', '\\"')
  return 'root:"' .. escaped .. '"'
end

--- @param encoding string
--- @return boolean
local function iconv_supported(encoding)
  if vim.startswith(encoding, 'utf-16') or vim.startswith(encoding, 'utf-32') then
    return false
  end
  return true
end

--- @async
--- Read the content of `relpath` at `revset` (e.g. `@-`). Mirrors the line/EOF
--- handling of `git show <blob>` (text = false) so the diff engine behaves
--- identically to the git backend.
--- @param root string
--- @param revset string
--- @param relpath string
--- @param encoding? string
--- @return string[] stdout, string? stderr, integer code
function M.file_show(root, revset, relpath, encoding)
  local stdout, stderr, code = M.command(
    root,
    { 'file', 'show', '--revision', revset, fileset(relpath) },
    { text = false, ignore_error = true }
  )

  if code ~= 0 then
    return {}, stderr, code
  end

  if encoding and encoding ~= 'utf-8' and iconv_supported(encoding) then
    for i, l in ipairs(stdout) do
      stdout[i] = vim.iconv(l, encoding, 'utf-8')
    end
  end

  return stdout, stderr, code
end

--- @async
--- Whether `relpath` exists in `revset` (e.g. tracked in the base `@-`).
--- @param root string
--- @param revset string
--- @param relpath string
--- @return boolean
function M.path_exists_at(root, revset, relpath)
  local _, _, code = M.command(
    root,
    { 'file', 'show', '--revision', revset, fileset(relpath) },
    { ignore_error = true }
  )
  return code == 0
end

--- @async
--- Files changed between `base` (default `@-`) and the working copy.
--- @param root string
--- @param base? string
--- @return {path:string, deleted?:boolean}[]
function M.files_changed(root, base)
  local args = { 'diff', '--summary' }
  if base then
    vim.list_extend(args, { '--from', base })
  end
  local out, _, code = M.command(root, args, { ignore_error = true })
  local ret = {} --- @type {path:string, deleted?:boolean}[]
  if code ~= 0 then
    return ret
  end
  for _, line in ipairs(out) do
    -- Lines look like "M path", "A path", "D path".
    local status, path = line:match('^(%a)%s+(.*)$')
    if status and path then
      ret[#ret + 1] = { path = path, deleted = status == 'D' or nil }
    end
  end
  return ret
end

local SEP = '\x1f'

local ANNOTATE_TEMPLATE = table.concat({
  'commit.commit_id()',
  'if(commit.current_working_copy(), "1", "0")',
  'commit.author().name()',
  'commit.author().email()',
  'commit.author().timestamp().format("%s")',
  'commit.author().timestamp().format("%z")',
  'commit.description().first_line()',
}, ' ++ "' .. SEP .. '" ++ ') .. ' ++ "\\n"'

--- @class Gitsigns.JJ.AnnotateLine
--- @field commit_id string
--- @field working_copy boolean
--- @field author string
--- @field email string
--- @field time integer
--- @field tz string
--- @field summary string

--- @async
--- Annotate (blame) `relpath` at `revset` (default `@`). Returns one entry per
--- final line, in order.
--- @param root string
--- @param revset string
--- @param relpath string
--- @return Gitsigns.JJ.AnnotateLine[]? lines, string? err
function M.annotate(root, revset, relpath)
  local out, stderr, code = M.command(root, {
    'file',
    'annotate',
    '--revision',
    revset,
    '--template',
    ANNOTATE_TEMPLATE,
    -- `jj file annotate` takes a plain PATH (resolved against cwd = root), not a
    -- fileset, so `relpath` is passed as-is (do NOT wrap it with `fileset()`).
    relpath,
  }, { ignore_error = true })

  if code ~= 0 then
    return nil, stderr or ('jj file annotate exited with ' .. code)
  end

  local lines = {} --- @type Gitsigns.JJ.AnnotateLine[]
  for _, line in ipairs(out) do
    local parts = vim.split(line, SEP, { plain = true })
    if #parts >= 7 then
      --- @type Gitsigns.JJ.AnnotateLine
      local entry = {
        commit_id = parts[1],
        working_copy = parts[2] == '1',
        author = parts[3],
        email = parts[4],
        time = math.floor(tonumber(parts[5]) or 0),
        tz = parts[6],
        summary = parts[7],
      }
      lines[#lines + 1] = entry
    else
      log.dprintf('jj annotate: skipping malformed line (%d fields): %s', #parts, line)
    end
  end

  return lines
end

--- @async
--- Render the jj "head" for the statusline: the bookmark(s) on the working-copy
--- commit, or its change id. Returns nil if jj is unavailable or errors.
--- @param toplevel string
--- @param template? string
--- @return string? head
function M.head(toplevel, template)
  local stdout, stderr, code = M.command(toplevel, {
    'log',
    '--no-graph',
    '--revisions',
    '@',
    '--template',
    template or HEAD_TEMPLATE,
  })

  if code ~= 0 then
    log.dprintf('jj head failed: %s', stderr or tostring(code))
    return
  end

  local head = stdout[1]
  if head == nil or head == '' then
    return
  end
  return head
end

return M
