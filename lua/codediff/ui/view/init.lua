-- Diff view router — dispatches to the appropriate view engine
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local side_by_side = require("codediff.ui.view.side_by_side")

-- Once-guard: register lifecycle autocmds on first view creation
local lifecycle_initialized = false

---@class SessionConfig
---@field mode "standalone"|"explorer"|"history"
---@field git_root string?
---@field original_path string
---@field modified_path string
---@field original_revision string?
---@field modified_revision string?
---@field conflict boolean? For merge conflict mode: render both sides against base
---@field explorer_data table? For explorer mode: { status_result }
---@field history_data table? For history mode: { commits, range, file_path, line_range }
---@field line_range table? For history line-range mode: { start_line, end_line }

---@param session_config SessionConfig Session configuration
---@param filetype? string Optional filetype for syntax highlighting
---@param on_ready? function Optional callback when view is fully ready (for sync callers)
---@return table|nil Result containing diff metadata, or nil if deferred
function M.create(session_config, filetype, on_ready)
  -- Initialize lifecycle autocmds on first use
  if not lifecycle_initialized then
    lifecycle.setup()
    lifecycle_initialized = true
  end

  -- All modes currently use side-by-side engine
  return side_by_side.create(session_config, filetype, on_ready)
end

---Update existing diff view with new files/revisions
---@param tabpage number Tabpage ID of the diff session
---@param session_config SessionConfig New session configuration (updates both sides)
---@param auto_scroll_to_first_hunk boolean? Whether to auto-scroll to first hunk (default: false)
---@return boolean success Whether update succeeded
function M.update(tabpage, session_config, auto_scroll_to_first_hunk)
  -- All modes currently use side-by-side engine
  return side_by_side.update(tabpage, session_config, auto_scroll_to_first_hunk)
end

return M
