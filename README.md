# snacks-ui.devhub

[snacks.nvim](https://github.com/folke/snacks.nvim)'s picker, drawn as
[DevHub](https://github.com/statiolake/devhub)'s native picker: rows in
DevHub's type (a file's name first, its directory after, matches in bold),
grep's hits under a heading per file, buffers' flags as words, a real query
field — round a preview that stays a Neovim window.

A DevHub extension (named `.devhub`, as Neovim plugins are `.nvim`): DevHub's
GUI is its engine, so it needs DevHub and devhub.nvim and is meant to be
loaded only there (the `cond` below); a terminal Neovim keeps plain snacks by
not loading it.

## What stays snacks'

Everything but the drawing. Sources, matching, sorting, actions, history,
`resume`, your `layouts` and your keys: the query is snacks' prompt buffer in
Insert mode, and your `win.input.keys` / `win.list.keys` are its buffer-local
maps as always (a `<C-q>` that runs your own action keeps doing so).

Each picker gets a layout of your layout's size (its width, height and the
preview's share) in which snacks' input and list windows are hidden and
borderless, and snacks' list buffer becomes a framed `gui.view` (devhub.nvim,
picker-agnostic): DevHub draws its frame where those windows stand. A layout
that is not one group of floats (`sidebar`, `ivy`'s split, a preview in the
main window) is left to snacks, as is any picker when snacks' internals are
not what this plugin expects (another snacks version).

## Install

Needs snacks.nvim and [devhub.nvim](https://github.com/statiolake/devhub.nvim).

```lua
{
  'statiolake/snacks-ui.devhub',
  cond = vim.env.DEVHUB_NEOVIM_GUI == '1',   -- only in DevHub's GUI
  dependencies = { 'folke/snacks.nvim', 'statiolake/devhub.nvim' },
  event = 'VeryLazy',
  main = 'snacks-ui',
  opts = { enabled = true },
}
```

## Options

```lua
require('snacks-ui').setup {
  enabled = true,          -- false: snacks draws itself
  labels = { … },          -- the hint row's words and the buffer flags (Japanese by default)
  hints = { 'confirm', 'edit_vsplit', 'edit_split', 'select_and_next', 'list_down',
            'bufdelete', 'send_to_rg', 'cancel' },   -- actions shown on the hint row, in order
}
```

`vim.g.snacks_ui_devhub = true | false` turns it on or off while Neovim runs.

## Tests

```sh
nvim --headless --clean --cmd 'set rtp^=.' -l tests/spec.lua
```
