-- snacks-ui.devhub: snacks.nvim's picker, drawn as DevHub's native picker.
--
-- snacks keeps everything it does: sources, matching, sorting, actions,
-- history, resume and the person's keys (its windows' buffer-local maps).
-- Only the drawing changes. Each picker gets a layout of the same size as
-- the person's own (width, height, the preview's share), whose input and
-- list windows are hidden (`hide = true`): they stay real buffers — the
-- query in Insert mode, the list one line per row — and DevHub draws them
-- as a framed `gui.view` of the list's buffer (devhub.nvim, picker-agnostic).
-- The preview stays a Neovim window, drawn as cells inside the frame.
--
-- A DevHub extension: it needs DevHub's GUI and devhub.nvim, and is loaded
-- only there. With a layout that is not one group of floats (sidebar, ivy's
-- split, a preview in the main window), or when snacks' internals are not
-- what it expects (another snacks version), snacks draws itself.

local M = {}

---@class snacks_ui.Config
local defaults = {
  -- false: snacks draws itself, as without this plugin. vim.g.snacks_ui_devhub
  -- (true / false) overrides it while Neovim runs.
  enabled = true,
  -- The words on the hint row and the buffer flags.
  labels = {
    confirm = '開く',
    edit_vsplit = '縦に分割',
    edit_split = '横に分割',
    select_and_next = '選ぶ',
    list_down = '移動',
    toggle_focus = '一覧へ',
    bufdelete = 'バッファを削除',
    send_to_rg = 'rg へ送る',
    qflist = 'quickfix へ',
    cancel = '閉じる',
    current = '現在',
    alternate = '直前',
    line = '行目',
    search = '検索',
    -- The chips beside the picker's name, for the toggles that are on.
    toggles = {
      live = 'Live',
      hidden = '隠しファイル',
      ignored = '除外も',
      follow = 'リンク先',
      modified = '変更のみ',
      regex = '文字どおり',
    },
  },
  -- The actions shown on the hint row, in this order, when a key does them.
  hints = {
    'confirm',
    'edit_vsplit',
    'edit_split',
    'select_and_next',
    'list_down',
    'bufdelete',
    'send_to_rg',
    'cancel',
  },
}

M.config = vim.deepcopy(defaults)

local installed = false

--- Whether pickers are drawn by DevHub now (DevHub's GUI is this plugin's
--- engine: load it only there).
function M.active()
  local g = vim.g.snacks_ui_devhub
  if g ~= nil then
    return g ~= false
  end
  return M.config.enabled ~= false
end

-- The person's layout, as snacks resolves it, and its float's sizes.
local function find(box, name)
  for _, child in ipairs(box) do
    if child.win == name then
      return child
    end
    if child.box then
      local found = find(child, name)
      if found then
        return found
      end
    end
  end
end

--- A layout of the person's size in which DevHub draws the picker. No window
--- has a border (DevHub draws the lines): the input (two rows: the
--- header) and the list are hidden, and the preview leaves a row free above
--- it (its title) and below it (the hints). nil when the person's layout is
--- not one group of floats.
function M.layout(resolved)
  local root = resolved and resolved.layout
  if type(root) ~= 'table' or resolved.preview == 'main' then
    return nil
  end
  if root.position and root.position ~= 'float' then
    return nil
  end
  local hidden = resolved.hidden or {}
  if vim.tbl_contains(hidden, 'list') or vim.tbl_contains(hidden, 'input') or not find(root, 'list') then
    return nil
  end
  local preview = find(root, 'preview')
  local preview_width = preview and preview.width or 0.5
  if preview_width == 0 then
    preview_width = 0.5
  end
  return {
    hidden = vim.deepcopy(hidden),
    cycle = resolved.cycle,
    auto_hide = resolved.auto_hide,
    layout = {
      box = 'vertical',
      backdrop = false,
      width = root.width or 0.8,
      min_width = root.min_width,
      max_width = root.max_width,
      height = root.height or 0.8,
      min_height = root.min_height,
      max_height = root.max_height,
      row = root.row,
      col = root.col,
      border = 'none',
      { win = 'input', height = 2, border = 'none', hide = true },
      {
        box = 'horizontal',
        { win = 'list', border = 'none', hide = true },
        {
          win = 'preview',
          width = preview_width,
          border = 'none',
          -- the column's height (snacks sets max_height to it) less the
          -- title row and the hint row; frame.lua moves it a row down
          height = function(win)
            return math.max(1, (win.opts.max_height or 3) - 2)
          end,
        },
      },
    },
  }
end

local ours = setmetatable({}, { __mode = 'k' })

-- snacks' config hook: the merged options of one picker, adapted.
local function adapt(opts)
  if opts._snacks_ui or not M.active() then
    return opts
  end
  local ok, layout = pcall(function()
    return M.layout(Snacks.picker.config.layout(opts))
  end)
  if not ok or not layout then
    return opts
  end
  opts.layout = layout
  opts._snacks_ui = true
  -- File names first and their directory after: the picker's reading order.
  opts.formatters = opts.formatters or {}
  opts.formatters.file = opts.formatters.file or {}
  opts.formatters.file.filename_first = true
  local on_show, on_close = opts.on_show, opts.on_close
  opts.on_show = function(picker)
    if on_show then
      on_show(picker)
    end
    local attached, err = pcall(require('snacks-ui.frame').attach, picker, M.config)
    if not attached then
      require('snacks-ui.frame').detach(picker, true)
      vim.notify('snacks-ui.devhub: ' .. tostring(err), vim.log.levels.WARN)
    end
  end
  opts.on_close = function(picker)
    pcall(require('snacks-ui.frame').detach, picker)
    if on_close then
      on_close(picker)
    end
  end
  return opts
end
ours[adapt] = true

--- Install the hook into snacks' picker (Snacks.picker.pick and everything
--- that goes through it: files, grep, buffers, resume, LSP pickers).
function M.install()
  if installed then
    return
  end
  local ok, Picker = pcall(require, 'snacks.picker.core.picker')
  if not ok or type(Picker.new) ~= 'function' then
    return
  end
  installed = true
  local new = Picker.new
  Picker.new = function(opts)
    opts = opts or {}
    local config = opts.config
    if not ours[config] then
      local chained = function(o)
        if config then
          o = config(o) or o
        end
        return adapt(o)
      end
      ours[chained] = true
      opts.config = chained
    end
    return new(opts)
  end
end

---@param opts? snacks_ui.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  if package.loaded['snacks.picker.core.picker'] or pcall(require, 'snacks') then
    M.install()
  end
end

return M
