-- nvim --headless --clean --cmd 'set rtp^=.' -l tests/spec.lua
-- The pure parts: the layout made from the person's, and a list line read
-- back from its extmarks. Leaves Neovim with an error on failure.
local failures = {}
local function check(ok, what)
  if not ok then
    table.insert(failures, what)
  end
end

local M = require 'snacks-ui'
local custom_default = {
  layout = {
    box = 'vertical', width = 0.8, height = 0.9, border = 'none',
    { win = 'input', height = 1, border = 'solid' },
    { box = 'horizontal', { win = 'list', border = 'solid' }, { win = 'preview', width = 0.45, border = 'solid' } },
  },
}
local l = M.layout(custom_default)
check(l and l.layout.width == 0.8 and l.layout.height == 0.9, 'the person\'s size kept')
check(l and l.layout[1].win == 'input' and l.layout[1].hide and l.layout[1].height == 2, 'the input hidden, two rows')
local body = l and l.layout[2]
check(body and body[1].win == 'list' and body[1].hide, 'the list hidden')
check(body and body[2].win == 'preview' and body[2].width == 0.45 and body[2].border == 'none', 'the preview\'s share kept')
check(body and body[2].height({ opts = { max_height = 40 } }) == 38, 'the preview leaves a title row and a hint row')
check(M.layout { preview = 'main', layout = { box = 'vertical', { win = 'list' } } } == nil, 'a preview in the main window: snacks\'')
check(M.layout { layout = { position = 'left', box = 'vertical', { win = 'list' } } } == nil, 'a split: snacks\'')
check(M.layout { hidden = { 'list' }, layout = { box = 'vertical', { win = 'list' } } } == nil, 'no list: snacks\'')

-- runs: groups over each piece, inline virtual text in its place
local rows = require 'snacks-ui.rows'
local buf = vim.api.nvim_create_buf(false, true)
local ns = vim.api.nvim_create_namespace 'snacks.picker.list'
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ' config.ts src' })
vim.api.nvim_buf_set_extmark(buf, ns, 0, 1, { virt_text = { { 'T ', 'MiniIconsBlue' } }, virt_text_pos = 'inline' })
vim.api.nvim_buf_set_extmark(buf, ns, 0, 1, { end_col = 10, hl_group = 'SnacksPickerFile' })
vim.api.nvim_buf_set_extmark(buf, ns, 0, 1, { end_col = 5, hl_group = 'SnacksPickerMatch', priority = 5000 })
vim.api.nvim_buf_set_extmark(buf, ns, 0, 11, { end_col = 14, hl_group = 'SnacksPickerDir' })
local runs = rows.runs(buf, 1, ' config.ts src')
local texts = vim.tbl_map(function(r)
  return r.text
end, runs)
check(vim.deep_equal(texts, { ' ', 'T ', 'conf', 'ig.ts', ' ', 'src' }), 'runs: ' .. vim.inspect(texts))
check(runs[3] and vim.deep_equal(runs[3].groups, { 'SnacksPickerFile', 'SnacksPickerMatch' }), 'a match over the name')
check(runs[2] and runs[2].virtual, 'the icon is virtual')

if #failures > 0 then
  io.stderr:write('FAIL\n  ' .. table.concat(failures, '\n  ') .. '\n')
  os.exit(1)
end
print 'snacks-ui: ok'
