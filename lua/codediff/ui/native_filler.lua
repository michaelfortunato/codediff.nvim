-- Native diff filler: flicker-free filler lines via Neovim's built-in diff mode.
--
-- Self-contained module that replaces virt_lines fillers with native diff fillers.
-- Converts our C algorithm's change mappings into ed-style diff hunks, feeds them
-- to Neovim via a custom diffexpr, and neutralizes all diff side effects except
-- filler lines and scrollbind.
--
-- Usage: require("codediff.ui.native_filler").setup(orig_win, mod_win, changes, orig_lines, mod_lines)

local M = {}

local _temp_file = nil
local _saved_diffexpr = nil
local _saved_diffopt = nil
local _active = false

-- ============================================================================
-- Ed-Style Converter (from filler_bridge)
-- ============================================================================

local function format_range(start_line, end_line)
  if start_line == end_line then return tostring(start_line) end
  return string.format("%d,%d", start_line, end_line)
end

local function emit_change(result, orig_start, orig_end, mod_start, mod_end, original_lines, modified_lines)
  table.insert(result, string.format("%sc%s", format_range(orig_start, orig_end), format_range(mod_start, mod_end)))
  for i = orig_start, orig_end do table.insert(result, "< " .. (original_lines[i] or "")) end
  table.insert(result, "---")
  for i = mod_start, mod_end do table.insert(result, "> " .. (modified_lines[i] or "")) end
end

local function emit_delete(result, orig_start, orig_end, mod_after, original_lines)
  table.insert(result, string.format("%sd%d", format_range(orig_start, orig_end), mod_after))
  for i = orig_start, orig_end do table.insert(result, "< " .. (original_lines[i] or "")) end
end

local function emit_add(result, orig_after, mod_start, mod_end, modified_lines)
  table.insert(result, string.format("%da%s", orig_after, format_range(mod_start, mod_end)))
  for i = mod_start, mod_end do table.insert(result, "> " .. (modified_lines[i] or "")) end
end

local function emit_block_hunks(result, orig_start, orig_end, mod_start, mod_end, original_lines, modified_lines)
  local orig_len = orig_end - orig_start
  local mod_len = mod_end - mod_start
  if orig_len == 0 and mod_len == 0 then return end

  if orig_len == 0 then
    emit_add(result, orig_start - 1, mod_start, mod_end - 1, modified_lines)
  elseif mod_len == 0 then
    emit_delete(result, orig_start, orig_end - 1, mod_start - 1, original_lines)
  elseif orig_len == mod_len then
    emit_change(result, orig_start, orig_end - 1, mod_start, mod_end - 1, original_lines, modified_lines)
  elseif orig_len > mod_len then
    emit_change(result, orig_start, orig_start + mod_len - 1, mod_start, mod_end - 1, original_lines, modified_lines)
    emit_delete(result, orig_start + mod_len, orig_end - 1, mod_end - 1, original_lines)
  else
    emit_change(result, orig_start, orig_end - 1, mod_start, mod_start + orig_len - 1, original_lines, modified_lines)
    emit_add(result, orig_end - 1, mod_start + orig_len, mod_end - 1, modified_lines)
  end
end

local function compute_alignments(mapping, original_lines)
  local alignments = {}
  local last_orig = mapping.original.start_line
  local last_mod = mapping.modified.start_line
  local first = true

  local function emit(orig_exc, mod_exc)
    if orig_exc < last_orig or mod_exc < last_mod then return end
    if first then
      first = false
    elseif orig_exc == last_orig or mod_exc == last_mod then
      return
    end
    if (orig_exc - last_orig) > 0 or (mod_exc - last_mod) > 0 then
      table.insert(alignments, { orig_start = last_orig, orig_end = orig_exc, mod_start = last_mod, mod_end = mod_exc })
    end
    last_orig = orig_exc
    last_mod = mod_exc
  end

  for _, inner in ipairs(mapping.inner_changes) do
    if inner.original.start_col > 1 and inner.modified.start_col > 1 then
      emit(inner.original.start_line, inner.modified.start_line)
    end
    local len = original_lines[inner.original.end_line] and #original_lines[inner.original.end_line] or 0
    if inner.original.end_col <= len then
      emit(inner.original.end_line, inner.modified.end_line)
    end
  end
  emit(mapping.original.end_line, mapping.modified.end_line)
  return alignments
end

local function changes_to_ed_style(changes, original_lines, modified_lines)
  local result = {}
  if #changes == 0 then
    if #original_lines == 0 and #modified_lines > 0 then
      emit_add(result, 0, 1, #modified_lines, modified_lines)
    elseif #original_lines > 0 and #modified_lines == 0 then
      emit_delete(result, 1, #original_lines, 0, original_lines)
    end
    return result
  end
  for _, mapping in ipairs(changes) do
    if not mapping.inner_changes or #mapping.inner_changes == 0 then
      emit_block_hunks(result, mapping.original.start_line, mapping.original.end_line,
        mapping.modified.start_line, mapping.modified.end_line, original_lines, modified_lines)
    else
      for _, align in ipairs(compute_alignments(mapping, original_lines)) do
        emit_block_hunks(result, align.orig_start, align.orig_end,
          align.mod_start, align.mod_end, original_lines, modified_lines)
      end
    end
  end
  return result
end

-- ============================================================================
-- Diffexpr Mechanism
-- ============================================================================

local function get_temp_file()
  if not _temp_file then
    _temp_file = vim.fn.tempname() .. "_codediff_ed.diff"
  end
  return _temp_file
end

local function install_diffexpr()
  local tf = get_temp_file()
  _saved_diffexpr = vim.o.diffexpr
  _saved_diffopt = vim.o.diffopt
  local cp_cmd = vim.fn.has("win32") == 1 and "copy" or "cp"

  -- Remove 'internal' from diffopt so Neovim uses our diffexpr
  -- instead of its built-in xdiff algorithm.
  local diffopt = vim.o.diffopt
  diffopt = diffopt:gsub(",?internal,?", ","):gsub("^,", ""):gsub(",$", "")
  vim.o.diffopt = diffopt

  vim.cmd(string.format([[
    function! CodeDiffExpr() abort
      let l:in_lines = readfile(v:fname_in)
      let l:new_lines = readfile(v:fname_new)
      if len(l:in_lines) == 1 && l:in_lines[0] ==# 'line1'
            \ && len(l:new_lines) == 1 && l:new_lines[0] ==# 'line2'
        silent execute '!echo 1c1 > ' .. shellescape(v:fname_out)
      else
        silent execute '!%s ' .. shellescape('%s') .. ' ' .. shellescape(v:fname_out)
      endif
    endfunction
  ]], cp_cmd, tf))
  vim.o.diffexpr = "CodeDiffExpr()"
end

local function uninstall_diffexpr()
  vim.o.diffexpr = _saved_diffexpr or ""
  if _saved_diffopt then vim.o.diffopt = _saved_diffopt end
  _saved_diffexpr = nil
  _saved_diffopt = nil
  pcall(vim.cmd, "silent! delfunction CodeDiffExpr")
end

-- ============================================================================
-- Diff Mode Side Effects
-- ============================================================================

local function neutralize_side_effects(orig_win, mod_win)
  -- Disable Neovim's inline char-level diff highlighting
  local diffopt = vim.o.diffopt
  if not diffopt:find("inline:none") then
    local new_opt = diffopt:gsub("inline:%w+", "inline:none")
    if not new_opt:find("inline:none") then new_opt = new_opt .. ",inline:none" end
    vim.o.diffopt = new_opt
  end

  -- Map diff highlights to empty group so our extmarks show through
  vim.api.nvim_set_hl(0, "CodeDiffNone", {})
  for _, win in ipairs({ orig_win, mod_win }) do
    vim.api.nvim_set_option_value("winhighlight",
      "DiffAdd:CodeDiffNone,DiffChange:CodeDiffNone,DiffDelete:CodeDiffFiller,DiffText:CodeDiffNone",
      { win = win })
    vim.api.nvim_set_option_value("foldmethod", "manual", { win = win })
    vim.api.nvim_set_option_value("foldenable", false, { win = win })
    vim.api.nvim_set_option_value("foldcolumn", "0", { win = win })
    vim.api.nvim_set_option_value("cursorbind", false, { win = win })
    vim.api.nvim_set_option_value("cursorline", false, { win = win })
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Set up native diff filler lines on two windows.
--- Converts changes to ed-style, enables diff mode, neutralizes side effects.
--- Call AFTER extmark highlights have been applied by core.render_diff.
--- @param orig_win number
--- @param mod_win number
--- @param changes table[] diff changes from lines_diff.changes
--- @param original_lines string[]
--- @param modified_lines string[]
function M.setup(orig_win, mod_win, changes, original_lines, modified_lines)
  local ed_lines = changes_to_ed_style(changes, original_lines, modified_lines)
  vim.fn.writefile(ed_lines, get_temp_file())
  install_diffexpr()

  for _, win in ipairs({ orig_win, mod_win }) do
    vim.api.nvim_win_call(win, function() vim.cmd("diffthis") end)
  end
  neutralize_side_effects(orig_win, mod_win)
  _active = true
end

--- Disable native diff mode and clean up.
--- @param orig_win number
--- @param mod_win number
function M.disable(orig_win, mod_win)
  for _, win in ipairs({ orig_win, mod_win }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
    end
  end
  uninstall_diffexpr()
  local tf = get_temp_file()
  if vim.fn.filereadable(tf) == 1 then vim.fn.delete(tf) end
  _temp_file = nil
  _active = false
end

--- Update diff after buffer content changes.
--- @param changes table[]
--- @param original_lines string[]
--- @param modified_lines string[]
function M.update(changes, original_lines, modified_lines)
  local ed_lines = changes_to_ed_style(changes, original_lines, modified_lines)
  vim.fn.writefile(ed_lines, get_temp_file())
  if _active then vim.cmd("diffupdate") end
end

--- @return boolean
function M.is_active()
  return _active
end

return M
