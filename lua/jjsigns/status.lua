local api = vim.api

--- @class (exact) Jjsigns.StatusObj
--- @field added? integer
--- @field removed? integer
--- @field changed? integer
--- @field head? string
--- @field root? string
--- @field gitdir? string

local M = {}

--- @param bufnr integer
local function autocmd_update(bufnr)
  api.nvim_exec_autocmds('User', {
    pattern = 'JjSignsUpdate',
    modeline = false,
    data = { buffer = bufnr },
  })
end

--- @param bufnr integer
--- @param status Jjsigns.StatusObj
function M.update(bufnr, status)
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local bstatus = vim.b[bufnr].jjsigns_status_dict
  if bstatus then
    status = vim.tbl_extend('force', bstatus, status)
  end

  if vim.deep_equal(bstatus, status) then
    return
  end

  vim.b[bufnr].jjsigns_head = status.head or ''
  vim.b[bufnr].jjsigns_status_dict = status

  local config = require('jjsigns.config').config

  vim.b[bufnr].jjsigns_status = config.status_formatter(status)

  autocmd_update(bufnr)
end

do -- Module-level activation
  local manager = require('jjsigns.manager')

  manager.on_update(function(ctx)
    local summary = require('jjsigns.hunks').get_summary(ctx.bcache.hunks or {})
    summary.head = ctx.bcache.git_obj.repo.abbrev_head
    M.update(ctx.bufnr, summary)
  end)

  manager.on_detach(function(bufnr)
    if not api.nvim_buf_is_loaded(bufnr) then
      return
    end

    local b = vim.b[bufnr]

    if b.jjsigns_head == nil and b.jjsigns_status_dict == nil and b.jjsigns_status == nil then
      return
    end

    b.jjsigns_head = nil
    b.jjsigns_status_dict = nil
    b.jjsigns_status = nil
    autocmd_update(bufnr)
  end)
end

return M
