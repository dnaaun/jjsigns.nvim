local jj = require('jjsigns.jj')
local log = require('jjsigns.debug.log')
local error_once = require('jjsigns.message').error_once

--- Blame for native (non-colocated) jj repositories, built on `jj file
--- annotate`. Produces the same shape as `jjsigns.git.blame.run_blame` so the
--- blame UI is agnostic to the backend.
local M = {}

local change_id_cache = {} --- @type table<string,string>

--- @async
--- @param repo Jjsigns.Repo
--- @param info Jjsigns.CommitInfo|Jjsigns.BlameInfoPublic
--- @return Jjsigns.CommitInfo|Jjsigns.BlameInfoPublic
function M.use_display_change_id(repo, info)
  if repo.vcs ~= 'jj' or not info.sha or info.sha:match('^0+$') then
    return info
  end

  local change_id = info.change_id
  if not change_id then
    local commit_sha = info.commit_sha or info.sha
    local key = repo.toplevel .. '\0' .. commit_sha
    change_id = change_id_cache[key]
    if not change_id then
      change_id = jj.change_id(repo.toplevel, commit_sha)
      if change_id then
        change_id_cache[key] = change_id
      end
    end
  end

  if not change_id then
    return info
  end

  info = vim.deepcopy(info)
  info.commit_sha = info.commit_sha or info.sha
  info.change_id = change_id
  info.abbrev_change_id = info.abbrev_change_id or change_id
  info.abbrev_sha = change_id
  return info
end

--- @param line Jjsigns.JJ.AnnotateLine
--- @return Jjsigns.CommitInfo
local function commit_info(line)
  local mail = '<' .. line.email .. '>'
  return {
    sha = line.commit_id,
    commit_sha = line.commit_id,
    change_id = line.change_id,
    abbrev_change_id = line.change_id,
    abbrev_sha = line.change_id,
    author = line.author,
    author_mail = mail,
    author_time = line.time,
    author_tz = line.tz,
    -- jj does not distinguish author/committer in annotate output; reuse the
    -- author for both.
    committer = line.author,
    committer_mail = mail,
    committer_time = line.time,
    committer_tz = line.tz,
    summary = line.summary,
  }
end

--- @async
--- @param obj Jjsigns.JJObj
--- @param contents? string[]
--- @param _lnum? integer|[integer, integer] jj annotates the whole file
--- @param revision? string
--- @param _opts? Jjsigns.BlameOpts
--- @return table<integer, Jjsigns.BlameInfo>
--- @return table<string, Jjsigns.CommitInfo?>
function M.run_blame(obj, contents, _lnum, revision, _opts)
  local ret = {} --- @type table<integer, Jjsigns.BlameInfo>
  local commits = {} --- @type table<string, Jjsigns.CommitInfo?>

  local Blame = require('jjsigns.git.blame')

  -- Untracked / not-yet-committed files: everything is "Not Committed Yet".
  if not obj.object_name then
    assert(contents, 'contents must be provided for untracked files')
    for i in ipairs(contents) do
      ret[i] = Blame.get_blame_nc(obj.file, i)
    end
    return ret, commits
  end

  -- jj cannot blame buffer contents directly, so we annotate the working-copy
  -- revision as last snapshotted. Lines that differ from that snapshot are
  -- handled by the caller's hunk bypass (returned as "Not Committed Yet"), so
  -- the snapshot is authoritative for the unchanged lines we do attribute here.
  local lines, err = jj.annotate(obj.repo.toplevel, revision or '@', assert(obj.relpath))

  if not lines then
    local msg = 'Error running jj file annotate: ' .. (err or '?')
    error_once(msg)
    log.eprint(msg)
    return ret, commits
  end

  for i, line in ipairs(lines) do
    if line.working_copy then
      -- The working-copy commit is jj's analogue of git's uncommitted changes.
      ret[i] = Blame.get_blame_nc(assert(obj.relpath), i)
    else
      local commit = commits[line.commit_id] or commit_info(line)
      commits[line.commit_id] = commit
      ret[i] = {
        orig_lnum = i,
        final_lnum = i,
        commit = commit,
        filename = assert(obj.relpath),
      }
    end
  end

  return ret, commits
end

return M
