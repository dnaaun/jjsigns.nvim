local helpers = require('test.gs_helpers')

local check = helpers.check
local clear = helpers.clear
local command = helpers.api.nvim_command
local command_wait_jjsigns_update = helpers.command_wait_jjsigns_update
local edit = helpers.edit
local eq = helpers.eq
local expectf = helpers.expectf
local exec_lua = helpers.exec_lua
local feed = helpers.feed
local matches = helpers.matches
local setup_jjsigns = helpers.setup_jjsigns
local setup_jj_repo = helpers.setup_jj_repo
local test_config = helpers.test_config
local wait_for_attach = helpers.wait_for_attach
local write_to_file = helpers.write_to_file

local config --- @type table
local test_file --- @type string

helpers.env()

--- @return boolean skipped
local function skip_without_jj()
  if not helpers.has_jj() then
    helpers.pending('requires jj')
    return true
  end
  return false
end

--- @return boolean
local function supports_staging()
  return exec_lua(function()
    local cache = require('jjsigns.cache').cache
    local bcache = cache[vim.api.nvim_get_current_buf()]
    return bcache.git_obj:supports_staging()
  end)
end

--- @return string
local function buf_head()
  return exec_lua('return vim.b.jjsigns_status_dict.head')
end

describe('jj', function()
  before_each(function()
    clear()
    test_file = helpers.test_file
    config = vim.deepcopy(test_config)
    helpers.chdir_tmp()
  end)

  it('detects a colocated jj repo and shows signs for the working-copy change', function()
    if skip_without_jj() then
      return
    end
    setup_jjsigns(config)
    setup_jj_repo()
    edit(test_file)
    wait_for_attach()

    -- Working copy matches its parent: no signs.
    check({ signs = {} })

    eq(
      'jj',
      exec_lua(function()
        local cache = require('jjsigns.cache').cache
        return cache[vim.api.nvim_get_current_buf()].git_obj.repo.vcs
      end)
    )

    -- Edit line 4: a single changed hunk, diffed against `@-` via the colocated
    -- git backend.
    feed('jjjccEDIT<esc>')
    check({ signs = { changed = 1 } })
  end)

  it('reports the jj change id as the head, not a git sha', function()
    if skip_without_jj() then
      return
    end
    setup_jjsigns(config)
    setup_jj_repo()
    edit(test_file)
    wait_for_attach()

    local head = buf_head()
    -- jj change ids use the alphabet [k-z]; a git short sha is hex ([0-9a-f]),
    -- so this pattern can only match a jj change id.
    matches('^[k-z]+$', head)
    eq(true, #head >= 8)
  end)

  it('shows jj change ids in colocated current-line blame', function()
    if skip_without_jj() then
      return
    end

    config.current_line_blame = true
    config.current_line_blame_formatter = '<abbrev_sha>'
    config.current_line_blame_opts = { delay = 1 }

    setup_jjsigns(config)
    setup_jj_repo()
    edit(test_file)
    wait_for_attach()

    exec_lua(function()
      require('jjsigns.current_line_blame').refresh()
    end)

    expectf(function()
      local line = exec_lua('return vim.b.jjsigns_blame_line')
      local blame_line = exec_lua('return vim.b.jjsigns_blame_line_dict')
      return type(line) == 'string'
        and line:match('^[k-z]+$')
        and #line >= 8
        and type(blame_line) == 'table'
        and blame_line.abbrev_sha == line
    end)

    local blame_line = exec_lua('return vim.b.jjsigns_blame_line_dict')
    matches('^[k-z]+$', blame_line.abbrev_sha)
    eq(blame_line.abbrev_sha, blame_line.change_id)
    eq(blame_line.abbrev_sha, blame_line.abbrev_change_id)
    eq(blame_line.sha, blame_line.commit_sha)
    eq(false, blame_line.sha == blame_line.abbrev_sha)
  end)

  it('disables staging (no index/staging area in jj)', function()
    if skip_without_jj() then
      return
    end
    setup_jjsigns(config)
    setup_jj_repo()
    edit(test_file)
    wait_for_attach()

    feed('jjjccEDIT<esc>')
    check({ signs = { changed = 1 } })

    eq(false, supports_staging())

    -- Staging is refused and must be a no-op: the hunk (and its sign) remain.
    -- (In a git repo this would clear the sign.)
    command('Jjsigns stage_hunk')
    command('Jjsigns stage_buffer')
    check({ signs = { changed = 1 } })

    -- Staging actions are not advertised for jj buffers.
    eq(
      false,
      exec_lua(function()
        local actions = require('jjsigns').get_actions() or {}
        return actions.stage_hunk ~= nil
      end)
    )
  end)

  it('still supports reset_hunk (which does not touch the index)', function()
    if skip_without_jj() then
      return
    end
    setup_jjsigns(config)
    setup_jj_repo()
    edit(test_file)
    wait_for_attach()

    feed('jjjccEDIT<esc>')
    check({ signs = { changed = 1 } })

    command_wait_jjsigns_update('Jjsigns reset_hunk')
    check({ signs = {} })
  end)

  it('refreshes signs after a jj operation moves the working-copy parent', function()
    if skip_without_jj() then
      return
    end
    config.watch_gitdir.enable = true
    setup_jjsigns(config)
    setup_jj_repo()
    edit(test_file)
    wait_for_attach()

    feed('jjjccEDIT<esc>')
    command('write')
    check({ signs = { changed = 1 } })

    -- Fold the working-copy change into its parent. The diff base (`@-`) now
    -- contains the edit, so the sign should clear once the gitdir watcher fires.
    helpers.jj('squash')
    check({ signs = {} })
  end)
end)

--- @return string
local function buf_gitdir()
  return exec_lua(function()
    local cache = require('jjsigns.cache').cache
    return cache[vim.api.nvim_get_current_buf()].git_obj.repo.gitdir
  end)
end

--- @return string
local function buf_vcs()
  return exec_lua(function()
    local cache = require('jjsigns.cache').cache
    return cache[vim.api.nvim_get_current_buf()].git_obj.repo.vcs
  end)
end

-- A non-colocated jj workspace has no `.git`, so git is genuinely unavailable
-- and jjsigns must use the native jj backend for everything.
describe('jj (non-colocated, no git)', function()
  before_each(function()
    clear()
    test_file = helpers.test_file
    config = vim.deepcopy(test_config)
    helpers.chdir_tmp()
  end)

  it('attaches via the native jj backend and shows signs (no .git)', function()
    if skip_without_jj() then
      return
    end
    setup_jjsigns(config)
    setup_jj_repo({ colocate = false })

    -- Sanity: there really is no usable git repository here.
    eq(0, helpers.fn.isdirectory(helpers.scratch .. '/.git'))

    edit(test_file)
    wait_for_attach()

    check({ signs = {} })
    eq('jj', buf_vcs())
    -- The repo is backed by `.jj`, not a `.git` dir.
    matches('%.jj$', buf_gitdir())

    feed('jjjccEDIT<esc>')
    check({ signs = { changed = 1 } })
  end)

  it('treats a file not in the base as untracked/all-added', function()
    if skip_without_jj() then
      return
    end
    setup_jjsigns(config)
    setup_jj_repo({ colocate = false })

    -- A brand new file: not present in `@-`.
    write_to_file(helpers.newfile, { 'one', 'two', 'three' })
    edit(helpers.newfile)
    wait_for_attach()

    -- Not in the base -> untracked (no object_name) and the whole file is added.
    eq(
      true,
      exec_lua(function()
        local cache = require('jjsigns.cache').cache
        return cache[vim.api.nvim_get_current_buf()].git_obj.object_name == nil
      end)
    )

    local added = exec_lua(function()
      local hunks = require('jjsigns').get_hunks() or {}
      local total = 0
      for _, h in ipairs(hunks) do
        total = total + (h.added and h.added.count or 0)
      end
      return total
    end)
    eq(3, added)
  end)

  it('disables staging', function()
    if skip_without_jj() then
      return
    end
    setup_jjsigns(config)
    setup_jj_repo({ colocate = false })
    edit(test_file)
    wait_for_attach()

    feed('jjjccEDIT<esc>')
    check({ signs = { changed = 1 } })

    eq(false, supports_staging())

    command('Jjsigns stage_hunk')
    command('Jjsigns stage_buffer')
    check({ signs = { changed = 1 } })
  end)

  it('blames committed lines natively', function()
    if skip_without_jj() then
      return
    end
    setup_jjsigns(config)
    setup_jj_repo({ colocate = false })
    edit(test_file)
    wait_for_attach()

    local result = exec_lua(function()
      local async = require('jjsigns.async')
      local cache = require('jjsigns.cache').cache
      local bcache = cache[vim.api.nvim_get_current_buf()]
      return async
        .run(function()
          local info = bcache:get_blame(1, {})
          return info
              and info.commit
              and {
                author = info.commit.author,
                sha = info.commit.sha,
                change_id = info.commit.change_id,
                abbrev_change_id = info.commit.abbrev_change_id,
                abbrev_sha = info.commit.abbrev_sha,
              }
            or nil
        end)
        :wait(5000)
    end)

    eq('tester', result.author)
    eq(false, result.sha == result.abbrev_sha)
    eq(result.abbrev_sha, result.change_id)
    eq(result.abbrev_sha, result.abbrev_change_id)
    matches('^[k-z]+$', result.abbrev_sha)
    eq(true, #result.abbrev_sha >= 8)
  end)

  it('reports the jj change id as the head', function()
    if skip_without_jj() then
      return
    end
    setup_jjsigns(config)
    setup_jj_repo({ colocate = false })
    edit(test_file)
    wait_for_attach()

    local head = buf_head()
    matches('^[k-z]+$', head)
    eq(true, #head >= 8)
  end)

  it('refreshes signs after a jj operation (op-log watcher)', function()
    if skip_without_jj() then
      return
    end
    config.watch_gitdir.enable = true
    setup_jjsigns(config)
    setup_jj_repo({ colocate = false })
    edit(test_file)
    wait_for_attach()

    feed('jjjccEDIT<esc>')
    command('write')
    check({ signs = { changed = 1 } })

    helpers.jj('squash')
    check({ signs = {} })
  end)

  it('handles file names with spaces (fileset + annotate quoting)', function()
    if skip_without_jj() then
      return
    end
    setup_jjsigns(config)
    setup_jj_repo({ colocate = false })

    -- Commit a file whose name contains a space into `@-`.
    local spaced = helpers.scratch .. '/with space.txt'
    write_to_file(spaced, { 'one', 'two', 'three' })
    helpers.jj('describe', '-m', 'add spaced', '--reset-author')
    helpers.jj('new')

    edit(spaced)
    wait_for_attach()
    check({ signs = {} })

    -- Signs (base content via `jj file show` fileset) work despite the space.
    feed('jccEDIT<esc>')
    check({ signs = { changed = 1 } })

    -- Blame (via `jj file annotate`, which takes a plain path) also resolves it.
    local author = exec_lua(function()
      local async = require('jjsigns.async')
      local cache = require('jjsigns.cache').cache
      local bcache = cache[vim.api.nvim_get_current_buf()]
      return async
        .run(function()
          local info = bcache:get_blame(1, {})
          return info and info.commit and info.commit.author
        end)
        :wait(5000)
    end)
    eq('tester', author)
  end)

  it('degrades show_commit gracefully instead of crashing', function()
    if skip_without_jj() then
      return
    end
    setup_jjsigns(config)
    setup_jj_repo({ colocate = false })
    edit(test_file)
    wait_for_attach()

    -- `git show` is unavailable in the native backend; show_commit must warn and
    -- return rather than erroring.
    local ok = exec_lua(function()
      local async = require('jjsigns.async')
      local show_commit = require('jjsigns.actions.show_commit')
      return async
        .run(function()
          show_commit('@-', 'vsplit', vim.api.nvim_get_current_buf())
        end)
        :pwait(5000)
    end)
    eq(true, ok)
  end)
end)
