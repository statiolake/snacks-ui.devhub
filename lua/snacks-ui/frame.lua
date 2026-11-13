-- One snacks picker as a framed gui.view (devhub.nvim): the view is the
-- hidden list's buffer, its frame the root box window, the hidden input its
-- query and the preview its preview.

local rows = require 'snacks-ui.rows'

local M = {}

-- picker -> { view (a framed gui.view), sent, rows }
local attached = setmetatable({}, { __mode = 'k' })

local function valid(win)
  return win and win.win and vim.api.nvim_win_is_valid(win.win)
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
      -- The keys go as Vim writes them (<C-v>, <CR>): DevHub writes every
      -- hint's keys in its one notation, a Mac's (⌃V, ↩, ⎋, ⇥; a modified
      -- letter a capital), as its own hints and tmux's, so none is spelled
      -- here — one notation, written in one place.
      local shown = { keys[1].lhs }
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
          shown[1] = shown[1] .. ' ' .. pick
        end
      end
      table.insert(out, { shown[1], config.labels[action] or action })
    end
  end
  return out
end

-- The toggles that are on, as snacks' own title shows them ({flags}: a
-- toggle is on when the picker's option is its value, true unless it says
-- otherwise — regex's is false, a search for the text as written), live
-- first, then by name.
function M.toggles_on(picker)
  local on = {}
  for name, toggle in pairs(picker.opts.toggles or {}) do
    if toggle then
      local t = type(toggle) == 'table' and toggle or {}
      local want = t.value
      if want == nil then
        want = true
      end
      if t.enabled ~= false and picker.opts[name] == want then
        table.insert(on, name)
      end
    end
  end
  table.sort(on)
  if picker.opts.live then
    table.insert(on, 1, 'live')
  end
  return on
end

-- The header's left: the picker's name, then a chip for each toggle that is
-- on (a click turns it off), as the name's pill.
local function title(picker, config)
  local text = picker.title or picker.opts.source or config.labels.search
  local children = { { type = 'badge', text = text, hl = 'Function' } }
  for _, name in ipairs(M.toggles_on(picker)) do
    table.insert(children, {
      type = 'badge',
      text = (config.labels.toggles or {})[name] or (name:gsub('_', '-')),
      hl = 'Special',
      on_click = function()
        picker:action('toggle_' .. name)
      end,
    })
  end
  return { type = 'hstack', gap = 4, align = 'center', children = children }
end

-- The header's right: how many items match, of how many.
local function status(picker)
  local count = ('%d / %d'):format(picker.list:count(), #picker.finder.items)
  if picker:is_active() then
    count = '… ' .. count
  end
  return { type = 'text', runs = { { text = count, hl = 'Comment' } }, size = 'sm' }
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
  if not a or picker.closed then
    return
  end
  local changes = {}
  local ti = title(picker, config)
  local st = status(picker)
  local pt = preview_title(picker, config) or { type = 'text', text = '' }
  local key = vim.inspect { ti, st, pt }
  if key ~= a.sent then
    a.sent = key
    changes.title = ti
    changes.status = st
    changes.preview_title = pt
    a.view:frame(changes)
  end
  -- The picker's windows: snacks' unhide() (pick_win) shows them again.
  for _, win in ipairs { picker.input.win, picker.list.win } do
    if valid(win) and not vim.api.nvim_win_get_config(win.win).hide then
      pcall(vim.api.nvim_win_set_config, win.win, { hide = true })
    end
  end
  a.view:redraw()
end

function M.attach(picker, config)
  if attached[picker] then
    return
  end
  local gui = require('devhub').gui -- devhub.nvim: required
  local layout = picker.layout
  if not (layout and layout.root and valid(layout.root) and valid(picker.list.win) and valid(picker.input.win)) then
    error 'the picker has no windows'
  end
  local list = picker.list
  local view = gui.view {
    buf = list.win.buf,
    win = list.win.win,
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
    keys = M.hints(picker, config),
    frame = {
      win = layout.root.win,
      query = { win = picker.input.win.win, placeholder = config.labels.search },
      preview = { win = valid(picker.preview.win) and picker.preview.win.win or nil, title = preview_title(picker, config) },
      title = title(picker, config),
      status = status(picker),
    },
  }
  local a = { view = view }
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
        view:frame { preview_win = valid(picker.preview.win) and picker.preview.win.win or false }
      end
    end)
  end)
  -- A toggle (<C-g>'s live, hidden, ignored, …) changes no row by itself:
  -- snacks writes its title then (update_titles), and so does the header.
  local update_titles = picker.update_titles
  picker.update_titles = function(self, ...)
    local r = update_titles(self, ...)
    refresh(picker, config)
    return r
  end
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
