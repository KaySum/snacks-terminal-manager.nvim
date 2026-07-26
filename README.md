# nvim-snacks-terminal-manager

Lightweight terminal management on top of [`snacks.nvim`](https://github.com/folke/snacks.nvim)'s
terminal module. Adds MRU-aware toggling, a labelled terminal picker, per-terminal
renaming, and a winbar — without replacing snacks' terminals.

The plugin ships **commands and an API only**; you decide the keymaps in your own config.

## Features

- **MRU toggle** — focus your most-recently-used terminal, or toggle it closed when
  you're already in it. Tracked by buffer, so it never loses or confuses terminals
  that share a `<count>`. Prefix a count to jump straight to terminal N.
- **Picker** — a `vim.ui.select` list of live terminals showing id, custom name,
  foreground process (e.g. `nvim`, `lazygit`), and cwd, with the active one marked.
- **Rename / Close** — name a terminal (shown in the picker and winbar) or kill
  one. Both act on the current terminal when you're inside one, otherwise pick.
- **Cycle** — jump to the next/previous terminal by id, wrapping around.
- **Winbar** — `"<id>: [name] <title>"` on split terminals; floating terminals
  (like lazygit) stay bare — no reserved empty row.

## Requirements

- Neovim 0.9+
- [`folke/snacks.nvim`](https://github.com/folke/snacks.nvim) with the `terminal`
  module enabled
- Process/cwd labels in the picker use `ps` (macOS/Linux); they degrade to blank
  elsewhere.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "KaySum/nvim-snacks-terminal-manager",
  dependencies = { "folke/snacks.nvim" },
  opts = {},
}
```

`opts = {}` runs `require("snacks-terminal-manager").setup()` with the defaults below.

## Configuration

Everything is configurable; these are the defaults:

```lua
require("snacks-terminal-manager").setup({
  -- Working directory for terminals opened by the plugin.
  root = function()
    return Snacks.git.get_root() or vim.fn.getcwd()
  end,

  -- Extra opts merged into `Snacks.terminal.focus` for every terminal the
  -- plugin opens. A table, or a function(count) -> table. `cwd` (from `root`)
  -- and `count` are always managed by the plugin. e.g. { env = { FOO = "1" } }.
  terminal = {},

  -- Winbar shown on split terminals. `winbar = false` disables it entirely.
  winbar = {
    enabled = true,
    format = require("snacks-terminal-manager").winbar, -- statusline string
    floating = false, -- true = also show it on floating terminals (lazygit, ...)
  },

  -- The `pick`/rename selection UI (vim.ui.select).
  picker = {
    prompt = "Terminals",
    marker = "●",          -- marks the most-recently-used terminal
    process = true,        -- show foreground process (uses `ps`; Unix only)
    cwd = true,            -- show the terminal's cwd
    empty = "No active terminals",
    -- Full override: function(item) -> string, where item is
    -- { buf, id, name, process, cwd, active }.
    format = nil,
  },

  rename = {
    select_prompt = "Rename terminal",
    input_prompt = "Terminal name: ",
  },

  close = {
    select_prompt = "Close terminal",
  },

  -- User commands. `commands = false` creates none.
  commands = {
    enabled = true,
    prefix = "SnacksTerminal", -- -> SnacksTerminalToggle / ...Pick / ...Rename
  },
})
```

Both `winbar` and `commands` also accept a plain boolean (`winbar = false`,
`commands = false`).

On LazyVim, point `root` at LazyVim's project-root detection:

```lua
opts = { root = function() return LazyVim.root() end }
```

## Commands

| Command | Description |
| --- | --- |
| `:SnacksTerminalToggle` | Focus the MRU terminal, or terminal `[count]` (e.g. `:3SnacksTerminalToggle`). Toggles closed when focused. |
| `:SnacksTerminalPick` | Pick a terminal to focus. |
| `:SnacksTerminalRename` | Rename a terminal — the current one, or pick. |
| `:SnacksTerminalClose` | Close (kill) a terminal — the current one, or pick. |
| `:SnacksTerminalNext` / `:SnacksTerminalPrev` | Focus the next / previous terminal (wraps). |

## API

```lua
local term = require("snacks-terminal-manager")

term.toggle()   -- focus MRU terminal; toggle closed if current
term.toggle(3)  -- focus/toggle terminal #3
term.pick()     -- terminal picker
term.rename()   -- rename the current terminal, or pick one
term.close()    -- close (kill) the current terminal, or pick one
term.next()     -- focus the next terminal (wraps)
term.prev()     -- focus the previous terminal (wraps)
```

## Keymaps

The plugin binds nothing. Wire it up however you like — for example:

```lua
local term = function(fn)
  return function() require("snacks-terminal-manager")[fn]() end
end

-- <C-/> focuses the MRU terminal, or terminal <count> (e.g. 3<C-/>).
vim.keymap.set({ "n", "t" }, "<c-/>", function()
  require("snacks-terminal-manager").toggle(vim.v.count)
end, { desc = "Terminal" })

vim.keymap.set("n", "<leader>tt", term("pick"),   { desc = "Switch Terminal" })
vim.keymap.set("n", "<leader>tr", term("rename"), { desc = "Rename Terminal" })
for i = 1, 9 do
  vim.keymap.set("n", "<leader>t" .. i, function()
    require("snacks-terminal-manager").toggle(i)
  end, { desc = "Terminal #" .. i })
end
```

On lazy.nvim, the idiomatic spot is the plugin spec's `keys` field — co-located
with the import. Keep the plugin eager (`lazy = false`) so the winbar, commands
and MRU tracking are live before any terminal opens:

```lua
{
  "KaySum/nvim-snacks-terminal-manager",
  dependencies = { "folke/snacks.nvim" },
  lazy = false,
  opts = {},
  keys = {
    -- Toggle honours v:count, so 3<C-/> focuses terminal 3 even via <cmd>.
    { "<c-/>", "<cmd>SnacksTerminalToggle<cr>", mode = { "n", "t" }, desc = "Terminal" },
    { "<leader>tt", "<cmd>SnacksTerminalPick<cr>", desc = "Switch Terminal" },
    { "<leader>tr", "<cmd>SnacksTerminalRename<cr>", desc = "Rename Terminal" },
    { "<leader>td", "<cmd>SnacksTerminalClose<cr>", desc = "Close Terminal" },
  },
}
```

The example above binds the commands; you can bind the API directly instead
(`function() require("snacks-terminal-manager").toggle(vim.v.count) end`) — handy
if you set `commands = false`.

> On LazyVim this also overrides LazyVim's built-in `<C-/>` cleanly: declaring the
> key in a lazy `keys` spec makes LazyVim's `safe_keymap_set` defer to yours.
