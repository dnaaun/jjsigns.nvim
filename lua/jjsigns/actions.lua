local async = require('jjsigns.async')
local Hunks = require('jjsigns.hunks')
local manager = require('jjsigns.manager')
local message = require('jjsigns.message')
local util = require('jjsigns.util')

local config = require('jjsigns.config').config
local mk_repeatable = require('jjsigns.repeat').mk_repeatable
local cache = require('jjsigns.cache').cache

local api = vim.api
local current_buf = api.nvim_get_current_buf

local tointeger = util.tointeger
local validate = util.validate

--- @class jjsigns.actions
local M = {}

--- @class Jjsigns.CmdParams.Smods
--- @field vertical boolean
--- @field split 'aboveleft'|'belowright'|'topleft'|'botright'

--- @class Jjsigns.CmdArgs
--- @field vertical? boolean
--- @field split? 'aboveleft'|'belowright'|'topleft'|'botright'
--- @field global? boolean
--- @field trigger? string
--- @field force? boolean
--- @field bufnr? integer
--- @field direction? ('first'|'last'|'next'|'prev')
--- @field revision? string
--- @field open? boolean|('vsplit'|'tabnew')
--- @field target? (0|integer|'attached'|'all'|'unstaged'|'staged')
--- @field nr? (0|integer)
--- @field [integer] any

--- @class Jjsigns.CmdParams : vim.api.keyset.create_user_command.command_args
--- @field smods Jjsigns.CmdParams.Smods

--- @class (exact) Jjsigns.AttachOpts
--- @inlinedoc
--- @field bufnr? integer Buffer number. Defaults to current buffer.
--- @field ctx? Jjsigns.GitContext Git context for git-object buffers.
--- @field trigger? string Attach source used for logging and manual-attach checks.
--- @field force? boolean Bypass auto-attach filters for this attach attempt.

--- @class (exact) Jjsigns.HunkOpts
--- Operate on/select all contiguous hunks. Only useful if 'diff_opts'
--- contains `linematch`. Defaults to `true`.
--- @field greedy? boolean

--- @class (exact) Jjsigns.SetqflistOpts
--- @field use_location_list? boolean Populate the location list instead of the quickfix list.
--- @field nr? integer Window number or ID when using location list. Defaults to `0`.
--- @field open? boolean Open the quickfix/location list viewer. Defaults to `true`.

--- Variations of functions from M which are used for the Jjsigns command
--- @type table<string,fun(args: Jjsigns.CmdArgs, params: Jjsigns.CmdParams)>
local C = {}

--- @class Jjsigns.CmdMeta
--- @field generated_completion? boolean

local C_meta = {} --- @type table<string, Jjsigns.CmdMeta>

--- @generic T
--- @param callback? fun(err?: string)
--- @param func async fun(...:T...) # The async function to wrap
--- @return Jjsigns.async.Task
local function async_run(callback, func, ...)
  assert(type(func) == 'function')

  local task = async.run(func, ...)

  if callback and type(callback) == 'function' then
    task:await(callback)
  else
    task:raise_on_error()
  end

  return task
end

--- Detach Jjsigns from all buffers it is attached to.
function M.detach_all()
  require('jjsigns.attach').detach_all()
end

--- Detach Jjsigns from the buffer {bufnr}. If {bufnr} is not
--- provided then the current buffer is used.
---
--- @param bufnr integer Buffer number
function M.detach(bufnr)
  require('jjsigns.attach').detach(bufnr)
end

--- @param opts_or_bufnr? Jjsigns.AttachOpts|integer
--- @param callback_or_ctx? fun(err?: string)|Jjsigns.GitContext
--- @param legacy_trigger? string?
--- @param legacy_callback? fun(err?: string)
--- @return Jjsigns.AttachOpts?
--- @return fun(err?: string)?
local function normalize_attach_call_args(
  opts_or_bufnr,
  callback_or_ctx,
  legacy_trigger,
  legacy_callback
)
  if
    type(opts_or_bufnr) == 'table'
    or type(callback_or_ctx) == 'function'
    or (opts_or_bufnr == nil and callback_or_ctx == nil)
  then
    validate('opts', opts_or_bufnr, 'table', true)
    validate('callback', callback_or_ctx, 'function', true)

    --- @cast opts_or_bufnr Jjsigns.AttachOpts?
    --- @cast callback_or_ctx fun(err?: string)?
    return opts_or_bufnr, callback_or_ctx
  else
    validate('bufnr', opts_or_bufnr, 'number', true)
    validate('ctx', callback_or_ctx, 'table', true)
    validate('trigger', legacy_trigger, 'string', true)
    validate('callback', legacy_callback, 'function', true)

    --- @type Jjsigns.AttachOpts
    local attach_opts = {
      bufnr = opts_or_bufnr,
      ctx = type(callback_or_ctx) == 'table' and callback_or_ctx or nil,
      trigger = legacy_trigger,
    }

    return attach_opts, legacy_callback
  end
end

--- Attach Jjsigns to the buffer.
---
--- Attributes:
--- - {async}
---
--- @param opts Jjsigns.AttachOpts? Attach options.
--- @param callback? fun(err?: string)
function M.attach(opts, callback, ...)
  local attach_opts, actual_callback = normalize_attach_call_args(opts, callback, ...)
  async_run(actual_callback, require('jjsigns.attach').attach, attach_opts)
end

function C.attach(args)
  M.attach({
    trigger = args.trigger or 'command',
    force = args.force,
    bufnr = tointeger(args[1]) or args.bufnr,
  })
end

--- Toggle [[jjsigns-config-signbooleancolumn]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of [[jjsigns-config-signcolumn]]
function M.toggle_signs(value)
  if value ~= nil then
    config.signcolumn = value
  else
    config.signcolumn = not config.signcolumn
  end
  return config.signcolumn
end

--- Toggle [[jjsigns-config-numhl]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
---
--- @return boolean : Current value of [[jjsigns-config-numhl]]
function M.toggle_numhl(value)
  if value ~= nil then
    config.numhl = value
  else
    config.numhl = not config.numhl
  end
  return config.numhl
end

--- Toggle [[jjsigns-config-linehl]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of [[jjsigns-config-linehl]]
M.toggle_linehl = function(value)
  if value ~= nil then
    config.linehl = value
  else
    config.linehl = not config.linehl
  end
  return config.linehl
end

--- Toggle [[jjsigns-config-word_diff]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of [[jjsigns-config-word_diff]]
function M.toggle_word_diff(value)
  if value ~= nil then
    config.word_diff = value
  else
    config.word_diff = not config.word_diff
  end
  -- Don't use refresh() to avoid flicker
  util.redraw({ buf = 0, range = { vim.fn.line('w0') - 1, vim.fn.line('w$') } })
  return config.word_diff
end

--- Toggle [[jjsigns-config-current_line_blame]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of [[jjsigns-config-current_line_blame]]
function M.toggle_current_line_blame(value)
  if value ~= nil then
    config.current_line_blame = value
  else
    config.current_line_blame = not config.current_line_blame
  end
  return config.current_line_blame
end

--- @deprecated Use [[jjsigns.preview_hunk_inline()]]
--- Toggle [[jjsigns-config-show_deleted]]
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of [[jjsigns-config-show_deleted]]
function M.toggle_deleted(value)
  if value ~= nil then
    config.show_deleted = value
  else
    config.show_deleted = not config.show_deleted
  end
  return config.show_deleted
end

--- @async
--- @param bufnr integer
local function update(bufnr)
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  manager.update(bufnr)
  if not bcache:schedule() then
    return
  end
  if vim.wo.diff then
    require('jjsigns.actions.diffthis').update(bufnr)
  end
end

--- @param params Jjsigns.CmdParams
--- @return [integer, integer]? range Range of lines to operate on.
local function get_range(params)
  local range --- @type [integer, integer]?
  if params.range > 0 then
    range = { params.line1, params.line2 }
  end
  return range
end

--- Staging has no meaning in jj repositories (there is no index/staging area),
--- and writing to the git index would actively desync jjsigns from jj's view.
--- Warn and abort when staging is requested for such a buffer.
--- @param bcache Jjsigns.CacheEntry
--- @return boolean ok
local function check_staging_supported(bcache)
  if not bcache.git_obj:supports_staging() then
    message.warn('Staging is not supported in jj repositories')
    return false
  end
  return true
end

--- Stage the hunk at the cursor position, or all lines in the
--- given range. If {range} is provided, all lines in the given
--- range are staged. This supports partial-hunks, meaning if a
--- range only includes a portion of a particular hunk, only the
--- lines within the range will be staged.
---
--- Attributes:
--- - {async}
---
--- @param range [integer, integer]? List-like table of two integers making
---   up the line range from which you want to stage the hunks.
---   If running via command line, then this is taken from the
---   command modifiers.
--- @param opts Jjsigns.HunkOpts? Additional options.
--- @param callback? fun(err?: string)
function M.stage_hunk(range, opts, callback)
  --- @cast range [integer, integer]?

  opts = opts or {}
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  if not check_staging_supported(bcache) then
    return
  end

  if not util.Path.exists(bcache.file) then
    print('Error: Cannot stage lines. Please add the file to the working tree.')
    return
  end

  async_run(callback, function()
    bcache.git_obj:lock(function()
      local hunk = bcache:get_hunk(range, opts.greedy ~= false, false)

      local invert = false
      if not hunk then
        invert = true
        hunk = bcache:get_hunk(range, opts.greedy ~= false, true)
      end

      if not hunk then
        api.nvim_echo({ { 'No hunk to stage', 'WarningMsg' } }, false, {})
        return
      end

      local err = bcache.git_obj:stage_hunks({ hunk }, invert)
      if err then
        message.error(err)
        return
      end

      if bcache.compare_text then
        bcache.compare_text = Hunks.apply_to_text(bcache.compare_text, hunk, invert)
      end

      table.insert(bcache.staged_diffs, hunk)
    end)

    bcache:invalidate()
    update(bufnr)
  end)
end

M.stage_hunk = mk_repeatable(M.stage_hunk)

C.stage_hunk = function(_, params)
  M.stage_hunk(get_range(params))
end
C_meta.stage_hunk = { generated_completion = false }

--- @param bufnr integer
--- @param hunk Jjsigns.Hunk.Hunk
local function reset_hunk(bufnr, hunk)
  local lstart, lend --- @type integer, integer
  if hunk.type == 'delete' then
    lstart = hunk.added.start
    lend = hunk.added.start
  else
    lstart = hunk.added.start - 1
    lend = hunk.added.start - 1 + hunk.added.count
  end

  if hunk.removed.no_nl_at_eof ~= hunk.added.no_nl_at_eof then
    local no_eol = hunk.added.no_nl_at_eof or false
    vim.bo[bufnr].endofline = no_eol
    vim.bo[bufnr].fixendofline = no_eol
  end

  util.set_lines(bufnr, lstart, lend, hunk.removed.lines)
end

--- Reset the lines of the hunk at the cursor position, or all
--- lines in the given range. If {range} is provided, all lines in
--- the given range are reset. This supports partial-hunks,
--- meaning if a range only includes a portion of a particular
--- hunk, only the lines within the range will be reset.
---
--- @param range [integer, integer]? List-like table of two integers making
---   up the line range from which you want to reset the hunks.
---   If running via command line, then this is taken from the
---   command modifiers.
--- @param opts Jjsigns.HunkOpts? Additional options.
--- @param callback? fun(err?: string)
function M.reset_hunk(range, opts, callback)
  --- @cast range [integer, integer]?

  async_run(callback, function()
    opts = opts or {}
    local bufnr = current_buf()
    local bcache = cache[bufnr]
    if not bcache then
      return
    end

    local hunk = bcache:get_hunk(range, opts.greedy ~= false, false)

    if not hunk then
      api.nvim_echo({ { 'No hunk to reset', 'WarningMsg' } }, false, {})
      return
    end

    reset_hunk(bufnr, hunk)
  end)
end

M.reset_hunk = mk_repeatable(M.reset_hunk)

function C.reset_hunk(_, params)
  M.reset_hunk(get_range(params))
end
C_meta.reset_hunk = { generated_completion = false }

--- Reset the lines of all hunks in the buffer.
function M.reset_buffer()
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  local hunks = bcache.hunks
  if not hunks or #hunks == 0 then
    api.nvim_echo({ { 'No unstaged changes in the buffer to reset', 'WarningMsg' } }, false, {})
    return
  end

  for i = #hunks, 1, -1 do
    reset_hunk(bufnr, hunks[i] --[[@as Jjsigns.Hunk.Hunk]])
  end
end

--- @deprecated use [[jjsigns.stage_hunk()]] on staged signs
--- Undo the last call of stage_hunk().
---
--- Note: only the calls to stage_hunk() performed in the current
--- session can be undone.
---
--- Attributes:
--- - {async}
---
--- @param callback? fun(err?: string)
function M.undo_stage_hunk(callback)
  async_run(callback, function()
    local bufnr = current_buf()
    local bcache = cache[bufnr]
    if not bcache then
      return
    end

    if not check_staging_supported(bcache) then
      return
    end

    bcache.git_obj:lock(function()
      local hunk = table.remove(bcache.staged_diffs)
      if not hunk then
        print('No hunks to undo')
        return
      end

      local err = bcache.git_obj:stage_hunks({ hunk }, true)
      if err then
        message.error(err)
        return
      end
    end)

    bcache:invalidate(true)
    update(bufnr)
  end)
end

--- Stage all hunks in current buffer.
---
--- Attributes:
--- - {async}
---
--- @param callback? fun(err?: string)
function M.stage_buffer(callback)
  async_run(callback, function()
    local bufnr = current_buf()
    local bcache = cache[bufnr]
    if not bcache then
      return
    end

    if not check_staging_supported(bcache) then
      return
    end

    bcache.git_obj:lock(function()
      -- Only process files with existing hunks
      local hunks = bcache.hunks
      if not hunks or #hunks == 0 then
        print('No unstaged changes in file to stage')
        return
      end

      if not util.Path.exists(bcache.git_obj.file) then
        print('Error: Cannot stage file. Please add it to the working tree.')
        return
      end

      local err = bcache.git_obj:stage_hunks(hunks)
      if err then
        message.error(err)
        return
      end

      for _, hunk in ipairs(hunks) do
        if bcache.compare_text then
          bcache.compare_text = Hunks.apply_to_text(bcache.compare_text, hunk)
        end
        table.insert(bcache.staged_diffs, hunk)
      end
    end)

    bcache:invalidate()
    update(bufnr)
  end)
end

--- Unstage all hunks for current buffer in the index. Note:
--- Unlike [[jjsigns.undo_stage_hunk()]] this doesn't simply undo
--- stages, this runs an `git reset` on current buffers file.
---
--- Attributes:
--- - {async}
---
--- @param callback? fun(err?: string)
function M.reset_buffer_index(callback)
  async_run(callback, function()
    local bufnr = current_buf()
    local bcache = cache[bufnr]
    if not bcache then
      return
    end

    if not check_staging_supported(bcache) then
      return
    end

    bcache.git_obj:lock(function()
      -- `bcache.staged_diffs` won't contain staged changes outside of current
      -- neovim session so signs added from this unstage won't be complete They will
      -- however be fixed by gitdir watcher and properly updated We should implement
      -- some sort of initial population from git diff, after that this function can
      -- be improved to check if any staged hunks exists and it can undo changes
      -- using git apply line by line instead of resetting whole file
      bcache.staged_diffs = {}

      bcache.git_obj:unstage_file()
    end)

    bcache:invalidate(true)
    update(bufnr)
  end)
end

--- Jump to hunk in the current buffer. If a hunk preview
--- (popup or inline) was previously opened, it will be re-opened
--- at the next hunk.
---
--- Attributes:
--- - {async}
---
--- @param direction ('first'|'last'|'next'|'prev')
--- @param opts Jjsigns.NavOpts? Configuration options.
--- @param callback? fun(err?: string)
function M.nav_hunk(direction, opts, callback)
  async_run(callback, function()
    --- @cast opts Jjsigns.NavOpts?
    require('jjsigns.actions.nav').nav_hunk(direction, opts)
  end)
end

function C.nav_hunk(args, _)
  --- @diagnostic disable-next-line: param-type-mismatch
  M.nav_hunk(args[1] or args.direction, args)
end

--- @deprecated use [[jjsigns.nav_hunk()]]
--- Jump to the next hunk in the current buffer. If a hunk preview
--- (popup or inline) was previously opened, it will be re-opened
--- at the next hunk.
---
--- See [[jjsigns.nav_hunk()]].
---
--- Attributes:
--- - {async}
--- @param opts Jjsigns.NavOpts? Configuration options.
--- @param callback? fun(err?: string)
function M.next_hunk(opts, callback)
  async_run(callback, function()
    require('jjsigns.actions.nav').nav_hunk('next', opts)
  end)
end

function C.next_hunk(args, _)
  --- @diagnostic disable-next-line: param-type-mismatch
  M.nav_hunk('next', args)
end

--- @deprecated use [[jjsigns.nav_hunk()]]
--- Jump to the previous hunk in the current buffer. If a hunk preview
--- (popup or inline) was previously opened, it will be re-opened
--- at the previous hunk.
---
--- See [[jjsigns.nav_hunk()]].
---
--- Attributes:
--- - {async}
--- @param opts Jjsigns.NavOpts? Configuration options.
--- @param callback? fun(err?: string)
function M.prev_hunk(opts, callback)
  async_run(callback, function()
    require('jjsigns.actions.nav').nav_hunk('prev', opts)
  end)
end

function C.prev_hunk(args, _)
  --- @diagnostic disable-next-line: param-type-mismatch
  M.nav_hunk('prev', args)
end

--- Preview the hunk at the cursor position in a floating
--- window. If the preview is already open, calling this
--- will cause the window to get focus.
function M.preview_hunk()
  require('jjsigns.actions.preview').preview_hunk()
end

--- Preview the hunk at the cursor position inline in the buffer.
--- @param callback? fun(err?: string)
function M.preview_hunk_inline(callback)
  async_run(callback, function()
    require('jjsigns.actions.preview').preview_hunk_inline()
  end)
end

--- Select the hunk under the cursor.
---
--- @param opts Jjsigns.HunkOpts? Additional options.
function M.select_hunk(opts)
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  opts = opts or {}

  local hunk --- @type Jjsigns.Hunk.Hunk?
  async
    .run(function()
      hunk = bcache:get_hunk(nil, opts.greedy ~= false)
    end)
    :wait()

  if not hunk then
    return
  end

  if vim.fn.mode():find('v') ~= nil then
    vim.cmd('normal! ' .. hunk.added.start .. 'GoV' .. hunk.vend .. 'G')
  else
    vim.cmd('normal! ' .. hunk.added.start .. 'GV' .. hunk.vend .. 'G')
  end
end

--- Get hunk array for specified buffer.
---
--- @param bufnr integer Buffer number, if not provided (or 0)
---             will use current buffer.
--- @return table? : Array of hunk objects.
---   Each hunk object has keys:
---   - `"type"`: String with possible values: "add", "change",
---     "delete"
---   - `"head"`: Header that appears in the unified diff
---     output.
---   - `"lines"`: Line contents of the hunks prefixed with
---     either `"-"` or `"+"`.
---   - `"removed"`: Sub-table with fields:
---     - `"start"`: Line number (1-based)
---     - `"count"`: Line count
---   - `"added"`: Sub-table with fields:
---     - `"start"`: Line number (1-based)
---     - `"count"`: Line count
M.get_hunks = function(bufnr)
  if (bufnr or 0) == 0 then
    bufnr = current_buf()
  end
  if not cache[bufnr] then
    return
  end
  local ret = {} --- @type Jjsigns.Hunk.Hunk_Public[]
  -- TODO(lewis6991): allow this to accept a greedy option
  for _, h in ipairs(cache[bufnr].hunks or {}) do
    ret[#ret + 1] = {
      head = h.head,
      lines = Hunks.patch_lines(h, vim.bo[bufnr].fileformat),
      type = h.type,
      added = h.added,
      removed = h.removed,
    }
  end
  return ret
end

--- Run git blame on the current line and show the results in a
--- floating window. If already open, calling this will cause the
--- window to get focus.
---
--- Attributes:
--- - {async}
---
--- @param opts Jjsigns.LineBlameOpts? Additional options.
--- @param callback? fun(err?: string)
function M.blame_line(opts, callback)
  --- @cast opts Jjsigns.LineBlameOpts?
  async_run(callback, require('jjsigns.actions.blame_line'), opts)
end

C.blame_line = function(args, _)
  --- @diagnostic disable-next-line: param-type-mismatch
  M.blame_line(args)
end

--- Run git-blame on the current file and open the results
--- in a scroll-bound vertical split.
---
--- Mappings:
---   <CR> is mapped to open a menu with the other mappings
---        Note: <Alt> must be held to activate the mappings whilst the menu is
---        open.
---   s   [Show commit] in a vertical split.
---   S   [Show commit] in a new tab.
---   r   [Reblame at commit]
---
--- Attributes:
--- - {async}
---
--- @param opts Jjsigns.BlameOpts? Additional options.
--- @param callback? fun(err?: string)
function M.blame(opts, callback)
  async_run(callback, require('jjsigns.actions.blame').blame, opts)
end

C.blame = function(args, _)
  --- @diagnostic disable-next-line: param-type-mismatch
  M.blame(args)
end

--- @async
--- @param bcache Jjsigns.CacheEntry
--- @param base string?
local function update_buf_base(bcache, base)
  bcache.file_mode = base == 'FILE'
  if not bcache.file_mode then
    bcache.git_obj:change_revision(base)
  end
  bcache:invalidate(true)
  update(bcache.bufnr)
end

local function change_base0(base, global)
  base = util.norm_base(base)

  if global then
    config.base = base

    for _, bcache in pairs(cache) do
      update_buf_base(bcache, base)
    end
  else
    local bufnr = current_buf()
    local bcache = cache[bufnr]
    if not bcache then
      return
    end

    update_buf_base(bcache, base)
  end
end

local function normalize_jj_revisions(revisions)
  revisions = revisions and vim.trim(tostring(revisions)) or ''
  if revisions == '' then
    return '@'
  end
  return revisions
end

local function jj_revisions_base_revset(revisions)
  return ('roots((%s))-'):format(normalize_jj_revisions(revisions))
end

local function jj_diff_base_revset(opt)
  opt = opt or {}
  if opt.revisions and opt.revisions ~= '' then
    return jj_revisions_base_revset(opt.revisions)
  end
  if opt.from and opt.from ~= '' then
    return opt.from
  end
  if opt.to and opt.to ~= '' then
    return '@'
  end
  return jj_revisions_base_revset('@')
end

local function resolve_jj_diff_base(root, opt)
  local base = jj_diff_base_revset(opt)
  if not root then
    return base
  end

  return require('jjsigns.jj').commit_id(root, base) or base
end

--- Change the base revision to diff against. If {base} is not
--- given, then the original base is used. If {global} is given
--- and true, then change the base revision of all buffers,
--- including any new buffers.
---
--- Attributes:
--- - {async}
---
--- Examples:
--- ```lua
---   -- Change base to 1 commit behind head
---   require('jjsigns').change_base('HEAD~1')
---   -- :Jjsigns change_base HEAD~1
---
---   -- Also works using the Jjsigns command
---   :Jjsigns change_base HEAD~1
---
---   -- Other variations
---   require('jjsigns').change_base('~1')
---   -- :Jjsigns change_base ~1
---   require('jjsigns').change_base('~')
---   -- :Jjsigns change_base ~
---   require('jjsigns').change_base('^')
---   -- :Jjsigns change_base ^
---
---   -- Commits work too
---   require('jjsigns').change_base('92eb3dd')
---   -- :Jjsigns change_base 92eb3dd
---
---   -- Revert to original base
---   require('jjsigns').change_base()
---   -- :Jjsigns change_base
--- ```
---
--- For a more complete list of ways to specify bases, see
--- [[jjsigns-revision]].
---
--- @param base (string|'FILE')? The object/revision to diff against.
--- @param global boolean? Change the base of all buffers.
--- @param callback? fun(err?: string)
function M.change_base(base, global, callback)
  async_run(callback, function()
    change_base0(base, global)
  end)
end

C.change_base = function(args, _)
  M.change_base(args[1], (args[2] or args.global))
end

--- Change the base to the parent side of a jj revision set.
---
--- The {revisions} argument has jj's `jj diff --revisions` meaning: it names
--- the change or contiguous set of changes to view. Jjsigns still decorates
--- live buffers, so this exactly matches that change when the live buffer is at
--- the selected revision (usually `@`).
---
--- @param revisions string? jj revset naming the changes to diff. Defaults to `@`.
--- @param global boolean? Change the base of all buffers.
--- @param callback? fun(err?: string)
function M.change_base_to_jj_revisions(revisions, global, callback)
  M.change_base_to_jj_diff({ revisions = revisions }, global, callback)
end

--- Change the base to the left side of a jj diff.
---
--- The {opt} table mirrors `jj diff`:
--- - `revisions` means `jj diff --revisions <revset>`, so the base is the
---   parent side of that revision set.
--- - `from` means `jj diff --from <revset>`, so the base is that revset.
--- - `to` is accepted for API symmetry, but Jjsigns decorates live buffers, so
---   the right side remains the current buffer contents.
---
--- @param opt {revisions?: string, from?: string, to?: string}
--- @param global boolean? Change the base of all buffers.
--- @param callback? fun(err?: string)
function M.change_base_to_jj_diff(opt, global, callback)
  async_run(callback, function()
    local base = jj_diff_base_revset(opt)

    if global then
      local default_root = require('jjsigns.jj').find_root(vim.fn.getcwd())
      config.base = resolve_jj_diff_base(default_root, opt)

      for _, bcache in pairs(cache) do
        local repo = bcache.git_obj and bcache.git_obj.repo
        update_buf_base(bcache, resolve_jj_diff_base(repo and repo.toplevel, opt))
      end
    else
      local bcache = cache[current_buf()]
      local repo = bcache and bcache.git_obj and bcache.git_obj.repo
      change_base0(resolve_jj_diff_base(repo and repo.toplevel, opt) or base, false)
    end
  end)
end

C.change_base_to_jj_diff = function(args, _)
  local positional = vim.deepcopy(args)
  for k, _ in pairs(args) do
    if type(k) ~= 'number' then
      positional[k] = nil
    end
  end

  local function named_or_pos(name, short)
    local value = args[name] or args[short]
    if value == true then
      return table.remove(positional, 1)
    end
    return value
  end

  M.change_base_to_jj_diff({
    revisions = named_or_pos('revisions', 'r') or positional[1],
    from = named_or_pos('from', 'f'),
    to = named_or_pos('to', 't'),
  }, args.global)
end

--- Reset the base revision to diff against back to the
--- index.
---
--- Alias for `change_base(nil, {global})` .
--- @param global boolean? Change the base of all buffers.
M.reset_base = function(global)
  M.change_base(nil, global)
end

C.reset_base = function(args, _)
  M.change_base(nil, (args[1] or args.global))
end

--- Perform a [[vimdiff]] on the given file with {base} if it is
--- given, or with the currently set base (index by default).
---
--- If {base} is the index, then the opened buffer is editable and
--- any written changes will update the index accordingly.
---
--- Examples:
--- ```lua
---   -- Diff against the index
---   require('jjsigns').diffthis()
---   -- :Jjsigns diffthis
---
---   -- Diff against the last commit
---   require('jjsigns').diffthis('~1')
---   -- :Jjsigns diffthis ~1
--- ```
---
--- For a more complete list of ways to specify bases, see
--- [[jjsigns-revision]].
---
--- Attributes:
--- - {async}
---
--- @param base (string|'FILE')? Revision to diff against. Defaults to index.
--- @param opts Jjsigns.DiffthisOpts? Additional options.
--- @param callback? fun(err?: string)
function M.diffthis(base, opts, callback)
  --- @cast opts Jjsigns.DiffthisOpts
  -- TODO(lewis6991): can't pass numbers as strings from the command line
  if base ~= nil then
    base = tostring(base)
  end
  opts = opts or {}
  if opts.vertical == nil then
    opts.vertical = config.diff_opts.vertical
  end
  async_run(callback, require('jjsigns.actions.diffthis').diffthis, base, opts)
end

function C.diffthis(args, params)
  -- TODO(lewis6991): validate these
  local opts = {
    vertical = config.diff_opts.vertical,
    split = args.split,
  }

  if args.vertical ~= nil then
    opts.vertical = args.vertical
  end

  if params.smods then
    if params.smods.split ~= '' and opts.split == nil then
      opts.split = params.smods.split
    end
    if opts.vertical == nil then
      opts.vertical = params.smods.vertical
    end
  end

  M.diffthis(args[1], opts)
end

-- C.test = function(pos_args: {any}, named_args: {string:any}, params: api.UserCmdParams)
--    print('POS ARGS:', vim.inspect(pos_args))
--    print('NAMED ARGS:', vim.inspect(named_args))
--    print('PARAMS:', vim.inspect(params))
-- end

--- Show revision {base} of the current file, if it is given, or
--- with the currently set base (index by default).
---
--- If {base} is the index, then the opened buffer is editable and
--- any written changes will update the index accordingly.
---
--- Examples:
--- ```lua
---   -- View the index version of the file
---   require('jjsigns').show()
---   -- :Jjsigns show
---
---   -- View revision of file in the last commit
---   require('jjsigns').show('~1')
---   -- :Jjsigns show ~1
--- ```
---
--- For a more complete list of ways to specify bases, see
--- [[jjsigns-revision]].
---
--- Attributes:
--- - {async}
---
--- @param revision (string|'FILE')?
--- @param callback? fun(err?: string)
function M.show(revision, callback)
  async_run(callback, require('jjsigns.actions.diffthis').show, nil, revision)
end

function C.show(args)
  local revision = args[1]
  if revision ~= nil then
    revision = tostring(revision)
  end
  M.show(revision)
end

--- Show revision {base} commit in split or tab
---
--- @param revision string? (default: 'HEAD')
--- @param open ('vsplit'|'tabnew')?
--- @param callback? fun(err?: string)
function M.show_commit(revision, open, callback)
  async_run(callback, require('jjsigns.actions.show_commit'), revision, open)
end

function C.show_commit(args)
  local revision, open = args[1], args[2]
  M.show_commit(revision, open)
end

--- Populate the quickfix list with hunks. Automatically opens the
--- quickfix window.
---
--- Attributes:
--- - {async}
---
--- @param target (0|integer|'attached'|'all')? #
--- Specifies which files hunks are collected from.
---   Possible values.
---   - [integer]: The buffer with the matching buffer
---     number. `0` for current buffer (default).
---   - `"attached"`: All attached buffers.
---   - `"all"`: All modified files for each git
---     directory of all attached buffers in addition
---     to the current working directory. When
---     `attach_to_untracked` is enabled, untracked
---     files are also included.
--- @param opts Jjsigns.SetqflistOpts? Additional options.
--- @param callback? fun(err?: string)
function M.setqflist(target, opts, callback)
  async_run(callback, require('jjsigns.actions.qflist').setqflist, target, opts)
end

function C.setqflist(args)
  local target = tointeger(args[1]) or args[1]
  --- @diagnostic disable-next-line: param-type-mismatch
  M.setqflist(target, args)
end

--- Populate the location list with hunks. Automatically opens the
--- location list window.
---
--- Alias for: `setqflist({target}, { use_location_list = true, nr = {nr} }`
---
--- Attributes:
--- - {async}
---
--- @param nr (0|integer)? Window number or the [[window-ID]].
---     `0` for the current window (default).
--- @param target (integer|'attached'|'all')? See [[jjsigns.setqflist()]].
function M.setloclist(nr, target)
  M.setqflist(target, {
    nr = nr,
    use_location_list = true,
  })
end

function C.setloclist(args)
  local target = tointeger(args[2]) or args[2]
  M.setloclist(tointeger(args[1]), target)
end

--- Get all the available line specific actions for the current
--- buffer at the cursor position.
---
--- @return table|nil : Dictionary of action name to function which when called
---     performs action.
M.get_actions = function()
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end
  local hunk = bcache:get_cursor_hunk()

  -- Staging is not available in jj repositories.
  local can_stage = bcache.git_obj:supports_staging()

  --- @type string[]
  local actions_l = {}

  if hunk then
    if can_stage then
      actions_l[#actions_l + 1] = 'stage_hunk'
    end
    vim.list_extend(actions_l, {
      'reset_hunk',
      'preview_hunk',
      'select_hunk',
    })
  else
    actions_l[#actions_l + 1] = 'blame_line'
  end

  if can_stage and not vim.tbl_isempty(bcache.staged_diffs) then
    actions_l[#actions_l + 1] = 'undo_stage_hunk'
  end

  local actions = {} --- @type table<string,function>
  for _, a in ipairs(actions_l) do
    actions[a] = M[a] --[[@as function]]
  end

  return actions
end

for name, f in
  pairs(M --[[@as table<string,function>]])
do
  if vim.startswith(name, 'toggle') then
    C[name] = function(args)
      f(args[1])
    end
  end
end

--- Refresh all buffers.
---
--- Attributes:
--- - {async}
---
--- @param callback? fun(err?: string)
function M.refresh(callback)
  require('jjsigns.sign_renderer').reset()
  require('jjsigns.highlight').setup_highlights()
  require('jjsigns.current_line_blame').refresh()
  async_run(callback, function()
    for k, v in pairs(cache) do
      v:invalidate(true)
      manager.update(k)
    end
  end)
end

--- @param name string
--- @return fun(args: table, params: Jjsigns.CmdParams)
function M._get_cmd_func(name)
  return C[name]
end

--- @param name string
--- @return (fun(arglead: string, line: string): string[])?
function M._get_cmp_func(name)
  if not M._supports_generated_cmp(name) then
    return
  end

  return require('jjsigns.cli.completion').for_action(name)
end

--- @param name string
--- @return boolean
function M._supports_generated_cmp(name)
  local cmd = C[name]
  local meta = C_meta[name]
  return cmd ~= nil and (meta == nil or meta.generated_completion ~= false)
end

return M
