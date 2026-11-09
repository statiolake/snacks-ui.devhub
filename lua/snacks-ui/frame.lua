-- One snacks picker on DevHub's gui.picker (devhub.nvim): the root box
-- window is the frame, the hidden input is the query, a gui.view of the
-- hidden list's buffer is the list, the preview is the preview.

local rows = require 'snacks-ui.rows'

local M = {}

-- picker -> { handle (gui.picker), view (gui.view), sent, rows }
local attached = setmetatable({}, { __mode = 'k' })

local function valid(win)
  return win and win.win and vim.api.nvim_win_is_valid(win.win)
end

-- "<C-v>" -> "^v", "<CR>" -> "↩".
local KEYS = { ['<cr>'] = '↩', ['<tab>'] = '⇥', ['<s-tab>'] = '⇤', ['<esc>'] = 'esc', ['<down>'] = '↓', ['<up>'] = '↑' }
local function pretty(lhs)
  local lower = lhs:lower()
  if KEYS[lower] then
    return KEYS[lower]
  end
  local ctrl = lower:match '^<c%-(.)>$'
  if ctrl then
    return '^' .. ctrl
  end
  local alt = lower:match '^<[am]%-(.)>$'
  if alt then
    return '⌥' .. alt
  end
  return lhs
end

-- The hint row: for each action the config names, the keys of the input
-- window (Insert mode first: that is where the person is) that do it.
function M.hints(picker, config)
  local by_action = {}
  for _, key in pairs(picker.input.win.keys or {}) do
    local action = key[2]
    if type(action) == 'table' then
      action = action[#action]
    end
    if type(action) == 'string' then
      local modes = type(key.mode) == 'table' and key.mode or { key.mode or 'n' }
      local insert = vim.tbl_contains(modes, 'i')
      by_action[action] = by_action[action] or {}
      table.insert(by_action[action], { lhs = key[1], insert = insert })
    end
  end
  local out = {}
  for _, action in ipairs(config.hints) do
    local keys = by_action[action]
    if keys then
      table.sort(keys, function(a, b)
        if a.insert ~= b.insert then
          return a.insert
        end
        if #a.lhs ~= #b.lhs then
          return #a.lhs < #b.lhs
        end
        return a.lhs < b.lhs
      end)
      local shown = { pretty(keys[1].lhs) }
      if action == 'list_down' then
        -- moving is a pair: down and up
        local up = by_action.list_up
        if up then
          table.sort(up, function(a, b)
            return a.insert and not b.insert or (a.insert == b.insert and #a.lhs < #b.lhs)
          end)
          -- the up key that pairs with the down one (<C-j> with <C-k>)
          local want = keys[1].lhs:lower():gsub('j>$', 'k>'):gsub('n>$', 'p>')
          local pick = up[1].lhs
          for _, k in ipairs(up) do
            if k.lhs:lower() == want then
              pick = k.lhs
            end
          end
          shown[1] = shown[1] .. ' ' .. pretty(pick)
        end
      end
      table.insert(out, { shown[1], config.labels[action] or action })
    end
  end
  return out
end

local function status(picker, config)
  local children = {}
  for name, toggle in pairs(picker.opts.toggles or {}) do
    if toggle then
      local want = type(toggle) == 'table' and toggle.value
      if want == nil then
        want = true
      end
      local enabled = not (type(toggle) == 'table' and toggle.enabled == false)
      if enabled and picker.opts[name] == want then
        table.insert(children, {
          type = 'badge',
          text = name:gsub('_', '-'),
          hl = 'Comment',
          on_click = function()
            picker:action('toggle_' .. name)
          end,
        })
      end
    end
  end
  table.sort(children, function(a, b)
    return a.text < b.text
  end)
  if picker.opts.live then
    table.insert(children, 1, { type = 'badge', text = 'live', hl = 'Function' })
  end
  local count = ('%d / %d'):format(picker.list:count(), #picker.finder.items)
  if picker:is_active() then
    count = '… ' .. count
  end
  table.insert(children, { type = 'spacer', size = 4 })
  table.insert(children, { type = 'text', runs = { { text = count, hl = 'Comment' } }, size = 'sm' })
  local _ = config
  return { type = 'hstack', gap = 6, align = 'center', children = children }
end

local function preview_title(picker, config)
  local item = picker:current { resolve = false }
  if not item then
    return nil
  end
  local path = item.file and Snacks.picker.util.path(item) or nil
  local runs = {}
  if path then
    local rel = vim.fn.fnamemodify(path, ':~:.')
    local parts = vim.split(rel, '/', { plain = true })
    for i, part in ipairs(parts) do
      if i > 1 then
        table.insert(runs, { text = ' › ', hl = 'Comment' })
      end
      table.insert(runs, { text = part, hl = i == #parts and nil or 'Comment' })
    end
  elseif picker.preview and picker.preview.title then
    table.insert(runs, { text = vim.trim(picker.preview.title) })
  else
    return nil
  end
  local children = { { type = 'text', runs = runs, grow = true } }
  if item.pos and item.pos[1] and item.pos[1] > 0 then
    table.insert(children, {
      type = 'text',
      runs = { { text = ('%d %s'):format(item.pos[1], config.labels.line), hl = 'Comment' } },
    })
  end
  return { type = 'hstack', gap = 8, align = 'center', children = children }
end

local function title(picker, config)
  local text = picker.title or picker.opts.source or config.labels.search
  return { type = 'badge', text = text, hl = 'Function' }
end

-- The page: as many items as DevHub's rows fit. snacks renders one page of
-- state.height items; the hidden window keeps its size (the frame is laid
-- out by it, and snacks reads its width to cut paths), so the height is set
-- on the list itself, and again after snacks reads it back from the window.
local function set_rows(picker, n)
  local a = attached[picker]
  local list = picker.list
  if not a or n < 1 then
    return
  end
  a.rows = n
  if list.state.height ~= n then
    list.state.height = n
    list.dirty = true
    list:update()
  end
end

-- After each render: the parts that changed, and the cursor.
local function refresh(picker, config)
  local a = attached[picker]
  if not a or picker.closed or not a.handle.is_open() then
    return
  end
  local changes = {}
  local st = status(picker, config)
  local pt = preview_title(picker, config) or { type = 'text', text = '' }
  local key = vim.inspect { st, pt }
  if key ~= a.sent then
    a.sent = key
    changes.status = st
    changes.preview_title = pt
    a.handle:update(changes)
  end
  -- The picker's windows: snacks' unhide() (pick_win) shows them again.
  for _, win in ipairs { picker.input.win, picker.list.win } do
    if valid(win) and not vim.api.nvim_win_get_config(win.win).hide then
      pcall(vim.api.nvim_win_set_config, win.win, { hide = true })
    end
  end
  a.handle:redraw()
end

function M.attach(picker, config)
  if attached[picker] then
    return
  end
  local gui = require('devhub').gui
  local layout = picker.layout
  if not (layout and layout.root and valid(layout.root) and valid(picker.list.win) and valid(picker.input.win)) then
    error 'the picker has no windows'
  end
  local list = picker.list
  local view = gui.view {
    buf = list.win.buf,
    items = function(lnum, line)
      return rows.item(picker, lnum, line)
    end,
    on_click = function(lnum, clicks)
      if picker.closed then
        return
      end
      list:_move(list:row2idx(lnum), true)
      if clicks and clicks >= 2 then
        -- As if <CR> were pressed where the keys are: an action that
        -- leaves Insert mode first (confirm) waits for a key to do so.
        local current = vim.api.nvim_get_current_win()
        if current == picker.input.win.win or current == list.win.win then
          vim.api.nvim_input '<CR>'
        else
          picker:action 'confirm'
        end
      end
    end,
    on_scroll = function(n)
      if not picker.closed then
        list:scroll(n)
      end
    end,
    on_rows = function(n)
      if not picker.closed then
        set_rows(picker, n)
      end
    end,
  }
  local handle = gui.picker {
    win = layout.root.win,
    query = { win = picker.input.win.win, placeholder = config.labels.search },
    list = { view = view, win = list.win.win },
    preview = { win = valid(picker.preview.win) and picker.preview.win.win or nil, title = preview_title(picker, config) },
    title = title(picker, config),
    status = status(picker, config),
    keys = M.hints(picker, config),
  }
  if not handle then
    pcall(view.close, view)
    error 'DevHub has no picker'
  end
  local a = { handle = handle, view = view }
  attached[picker] = a
  -- Every change of the list goes through render(): the rows (an edit of
  -- the list buffer DevHub sees itself), the cursor and the counts.
  local render = list.render
  list.render = function(self, ...)
    if a.rows and self.state.height ~= a.rows then
      self.state.height = a.rows
      self.dirty = true
    end
    local r = render(self, ...)
    refresh(picker, config)
    return r
  end
  -- snacks puts a box's windows at the box's top: the preview goes a row
  -- down, under its title (M.layout left the row), at every layout.
  local function lower_preview()
    local pw = picker.preview and picker.preview.win
    if valid(pw) and pw.opts.relative == 'win' then
      pw.opts.row = (pw.opts.row or 0) + 1
      pw:update()
    end
  end
  local update = layout.update
  layout.update = function(self, ...)
    local r = update(self, ...)
    if attached[picker] then
      lower_preview()
    end
    return r
  end
  lower_preview()
  -- The preview window comes and goes (toggle_preview); its title follows
  -- the item.
  layout.root:on('WinResized', function()
    vim.schedule(function()
      if attached[picker] and not picker.closed then
        handle:update { preview_win = valid(picker.preview.win) and picker.preview.win.win or false }
      end
    end)
  end)
  local show_preview = picker._show_preview
  picker._show_preview = function(self, ...)
    local r = show_preview(self, ...)
    refresh(picker, config)
    return r
  end
  refresh(picker, config)
end

--- Undo attach: the frame goes; with unhide, snacks' windows are shown
--- again (an error while attaching leaves the picker usable as cells).
function M.detach(picker, unhide)
  local a = attached[picker]
  attached[picker] = nil
  if a then
    pcall(a.handle.close)
    pcall(a.view.close, a.view)
  end
  if unhide then
    for _, win in ipairs { picker.input.win, picker.list.win } do
      if valid(win) then
        pcall(vim.api.nvim_win_set_config, win.win, { hide = false })
      end
    end
  end
end

return M
