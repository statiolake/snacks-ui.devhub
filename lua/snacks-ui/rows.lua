-- A snacks list line as a DevHub row: the text and extmarks list:format()
-- wrote (highlight groups that name each part's role, SnacksPickerMatch on
-- every matched character, the icon as inline virtual text) read back as
-- runs, then laid out by role — a file's name in the UI face with its
-- directory after it, matches in bold, grep's hits under a heading per
-- file, a buffer's flags as words.

local M = {}

local ns = vim.api.nvim_create_namespace 'snacks.picker.list'

-- Groups whose text is code or a position: drawn in the grid's face.
local MONO = {
  SnacksPickerRow = true,
  SnacksPickerCol = true,
  SnacksPickerBufNr = true,
  SnacksPickerDelim = true,
}

local MATCH = 'SnacksPickerMatch'

--- The line's runs: { text, groups = { ... }, virtual = bool }, in order;
--- a run's groups are every highlight over it, innermost (latest) last.
function M.runs(buf, lnum, line)
  local row = lnum - 1
  local spans, inserts = {}, {}
  local cuts = { [0] = true, [#line] = true }
  local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, ns, { row, 0 }, { row, -1 }, { details = true })
  for _, m in ipairs(ok and marks or {}) do
    local col, d = m[3], m[4] or {}
    if d.virt_text and (d.virt_text_pos == 'inline' or d.virt_text_pos == 'overlay') then
      table.insert(inserts, { col = col, chunks = d.virt_text })
    end
    if d.hl_group then
      local to = math.min(d.end_col or #line, #line)
      if (d.end_row == nil or d.end_row == row) and to > col then
        table.insert(spans, { from = col, to = to, group = d.hl_group, priority = d.priority or 4096 })
        cuts[col], cuts[to] = true, true
      end
    end
  end
  table.sort(spans, function(a, b)
    return a.priority < b.priority
  end)
  local points = vim.tbl_keys(cuts)
  table.sort(points)
  table.sort(inserts, function(a, b)
    return a.col < b.col
  end)
  local out = {}
  local next_insert = 1
  local function flush_inserts(upto)
    while inserts[next_insert] and inserts[next_insert].col <= upto do
      for _, chunk in ipairs(inserts[next_insert].chunks) do
        local group = chunk[2]
        if type(group) == 'table' then
          group = group[#group]
        end
        table.insert(out, { text = chunk[1], groups = { group }, virtual = true })
      end
      next_insert = next_insert + 1
    end
  end
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    flush_inserts(a)
    local groups = {}
    for _, sp in ipairs(spans) do
      if sp.from <= a and sp.to >= b then
        table.insert(groups, sp.group)
      end
    end
    local text = line:sub(a + 1, b)
    if text ~= '' then
      table.insert(out, { text = text, groups = groups })
    end
  end
  flush_inserts(math.huge)
  return out
end

local function has(run, group)
  return vim.tbl_contains(run.groups, group)
end

-- The run's own role: its last group that is not the match.
local function role(run)
  for i = #run.groups, 1, -1 do
    if run.groups[i] ~= MATCH then
      return run.groups[i]
    end
  end
end

-- Runs as component runs: matches bold in the match's colour, code and
-- positions in the grid's face, the icon in its colour.
local function component_runs(list, opts)
  opts = opts or {}
  local out = {}
  for _, r in ipairs(list) do
    local group = role(r)
    local match = has(r, MATCH)
    local run = { text = r.text, hl = group }
    if match then
      run.bold = true
      run.hl = MATCH
    end
    if r.virtual or opts.mono or (group and MONO[group]) or (group and group:match '^@') then
      run.mono = true
    end
    if group == 'SnacksPickerDir' or group == 'SnacksPickerDelim' then
      run.hl = match and MATCH or 'Comment'
    end
    table.insert(out, run)
  end
  return out
end

local function trim(list)
  while list[1] and not list[1].virtual and list[1].text:match '^%s*$' do
    table.remove(list, 1)
  end
  while list[#list] and list[#list].text:match '^%s*$' do
    table.remove(list)
  end
  if list[1] and not list[1].virtual then
    list[1] = vim.tbl_extend('force', list[1], { text = list[1].text:gsub('^%s+', '') })
  end
  return list
end

local function text_node(runs, extra)
  return vim.tbl_extend('force', { type = 'text', runs = runs }, extra or {})
end

local function icon_and_rest(list)
  local icon, rest = {}, {}
  for i, r in ipairs(list) do
    if r.virtual and #rest == 0 and not has(r, 'SnacksPickerSelected') and not has(r, 'SnacksPickerUnselected') then
      table.insert(icon, r)
    else
      rest = vim.list_slice(list, i)
      break
    end
  end
  return icon, rest
end

-- A file row: [selected] icon name dir …
local function file_row(list)
  local selected = {}
  while list[1] and (has(list[1], 'SnacksPickerSelected') or has(list[1], 'SnacksPickerUnselected')) do
    table.insert(selected, table.remove(list, 1))
  end
  list = trim(list)
  local icon, rest = icon_and_rest(list)
  local children = {}
  if #selected > 0 then
    table.insert(children, text_node(component_runs(trim(selected)), { mono = true }))
  end
  if #icon > 0 then
    local runs = component_runs(trim(icon))
    table.insert(children, text_node(runs, { mono = true }))
  end
  table.insert(children, text_node(component_runs(rest), { grow = true }))
  return { type = 'hstack', gap = 8, align = 'center', children = children }
end

-- The item a list line shows.
local function item_at(picker, lnum)
  local list = picker.list
  local ok, item = pcall(function()
    return list:get(list:row2idx(lnum))
  end)
  return ok and item or nil
end

local function is_grep(picker, item)
  return item and item.file and item.pos and item.line ~= nil and picker.opts.format == 'file'
end

-- grep: a heading over each file's run of hits, and the hit as its line
-- number and its text.
local function grep_row(picker, lnum, list, item)
  -- the part after the position (file:row:col) is the line's text
  local last_pos
  for i, r in ipairs(list) do
    local g = role(r)
    if g == 'SnacksPickerRow' or g == 'SnacksPickerCol' then
      last_pos = i
    end
  end
  local text = last_pos and vim.list_slice(list, last_pos + 1) or list
  text = trim(text)
  local selected = {}
  for _, r in ipairs(list) do
    if has(r, 'SnacksPickerSelected') then
      table.insert(selected, r)
    end
  end
  local children = {}
  if #selected > 0 then
    table.insert(children, text_node(component_runs(selected), { mono = true }))
  end
  table.insert(children, text_node({ { text = ('%4d'):format(item.pos[1]), hl = 'Comment', mono = true } }, { mono = true }))
  table.insert(children, text_node(component_runs(text, { mono = true }), { mono = true, grow = true }))
  local row = { type = 'hstack', gap = 10, align = 'center', children = children }

  local prev = lnum > 1 and item_at(picker, lnum - 1) or nil
  if prev and prev.file == item.file then
    return row
  end
  -- The heading: the file's icon, name and directory, and how many of its
  -- hits are on this page.
  local count = 0
  for l = lnum, lnum + 500 do
    local it = item_at(picker, l)
    if not it or it.file ~= item.file then
      break
    end
    count = count + 1
  end
  local path = vim.fn.fnamemodify(Snacks.picker.util.path(item) or item.file, ':~:.')
  local name, dir = vim.fn.fnamemodify(path, ':t'), vim.fn.fnamemodify(path, ':h')
  local icon, icon_hl = Snacks.util.icon(name, 'file', { fallback = picker.opts.icons.files })
  local heading = {
    type = 'hstack',
    gap = 8,
    align = 'center',
    children = {
      text_node({ { text = vim.trim(icon), hl = icon_hl, mono = true } }, { mono = true }),
      text_node({ { text = name, bold = true }, { text = dir ~= '.' and ('  ' .. dir) or '', hl = 'Comment' } }, { grow = true }),
      { type = 'badge', text = tostring(count), hl = 'Comment', pill = true },
    },
  }
  return { node = row, heading = heading }
end

-- buffers: "  3 %a  name dir" — the number, the name, the flags as words
-- and a dot for a modified buffer.
local function buffer_row(picker, list, item, config)
  local flags = item.flags or ''
  local rest = {}
  local number
  for _, r in ipairs(list) do
    local g = role(r)
    if g == 'SnacksPickerBufNr' then
      number = vim.trim(r.text)
    elseif g ~= 'SnacksPickerBufFlags' and g ~= 'SnacksPickerRow' and g ~= 'SnacksPickerCol' and g ~= 'SnacksPickerDelim' then
      table.insert(rest, r)
    end
  end
  local row = file_row(rest)
  table.insert(row.children, 1, text_node({ { text = ('%3s'):format(number or tostring(item.buf)), hl = 'Comment', mono = true } }, { mono = true }))
  local words = {}
  if flags:find('%', 1, true) then
    table.insert(words, { type = 'badge', text = config.labels.current, hl = 'Function' })
  elseif flags:find('#', 1, true) then
    table.insert(words, { type = 'badge', text = config.labels.alternate, hl = 'Comment' })
  end
  if flags:find('+', 1, true) or (item.buf and vim.api.nvim_buf_is_valid(item.buf) and vim.bo[item.buf].modified) then
    table.insert(words, text_node({ { text = '●', hl = 'DiagnosticWarn' } }))
  end
  vim.list_extend(row.children, words)
  local _ = picker
  return row
end

--- The row for list line lnum: a component, { node, heading }, or nil
--- (a blank line: no row).
function M.item(picker, lnum, line)
  if line == '' or picker.closed then
    return nil
  end
  local config = require('snacks-ui').config
  local list = M.runs(picker.list.win.buf, lnum, line)
  local item = item_at(picker, lnum)
  if item and picker.opts.format == 'buffer' then
    return buffer_row(picker, list, item, config)
  end
  if is_grep(picker, item) then
    return grep_row(picker, lnum, list, item)
  end
  return file_row(list)
end

return M
