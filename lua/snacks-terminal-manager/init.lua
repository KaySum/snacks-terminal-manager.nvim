local M = {}

-- Default winbar for split terminal windows: snacks' "<id>: <title>", with a
-- "[name]" prefix once the terminal has been renamed. b:snacks_terminal is read
-- through exists() so a window without it never throws E121.
local DEFAULT_WINBAR = table.concat({
  "%{exists('b:snacks_terminal') ? b:snacks_terminal.id : ''}: ",
  "%{empty(get(b:,'terminal_name','')) ? '' : '[' . get(b:,'terminal_name','') . '] '}",
  "%{get(b:,'term_title','')}",
})

-- Exposed so configs can reuse/extend the default winbar (winbar.format).
M.winbar = DEFAULT_WINBAR

---@class SnacksTerminalManager.WinbarConfig
---@field enabled? boolean Register the winbar (default true).
---@field format? string Statusline-format string used on split terminals.
---@field floating? boolean Also show the winbar on floating terminals (default false: strip it).

---@class SnacksTerminalManager.Item
---@field buf integer Terminal buffer number.
---@field id integer|nil snacks terminal id (the <count>).
---@field name string|nil User-assigned name, if any.
---@field process string|nil Foreground process name, if resolved.
---@field cwd string|nil Terminal working directory, if enabled.
---@field active boolean Whether this is the most-recently-used terminal.

---@class SnacksTerminalManager.PickerConfig
---@field prompt? string Prompt for the focus picker.
---@field marker? string Marker shown next to the MRU terminal.
---@field process? boolean Show the foreground process name (uses `ps`; Unix only).
---@field cwd? boolean Show the terminal's cwd.
---@field empty? string Notification shown when no terminals are open.
---@field format? fun(item: SnacksTerminalManager.Item): string Full label override.

---@class SnacksTerminalManager.RenameConfig
---@field select_prompt? string Prompt when choosing which terminal to rename.
---@field input_prompt? string Prompt for the new terminal name.

---@class SnacksTerminalManager.CloseConfig
---@field select_prompt? string Prompt when choosing which terminal to close.

---@class SnacksTerminalManager.CommandsConfig
---@field enabled? boolean Create user commands (default true).
---@field prefix? string Command name prefix (default "SnacksTerminal").

---@class SnacksTerminalManager.Config
---@field root? fun():string Working directory for terminals opened by the plugin.
---@field terminal? table|fun(count: integer): table Extra opts merged into Snacks.terminal.focus.
---@field winbar? boolean|SnacksTerminalManager.WinbarConfig
---@field picker? SnacksTerminalManager.PickerConfig
---@field rename? SnacksTerminalManager.RenameConfig
---@field close? SnacksTerminalManager.CloseConfig
---@field commands? boolean|SnacksTerminalManager.CommandsConfig

---@type SnacksTerminalManager.Config
local defaults = {
  root = function()
    return Snacks.git.get_root() or vim.fn.getcwd()
  end,
  terminal = {},
  winbar = {
    enabled = true,
    format = DEFAULT_WINBAR,
    floating = false,
  },
  picker = {
    prompt = "Terminals",
    marker = "●",
    process = true,
    cwd = true,
    empty = "No active terminals",
    format = nil,
  },
  rename = {
    select_prompt = "Rename terminal",
    input_prompt = "Terminal name: ",
  },
  close = {
    select_prompt = "Close terminal",
  },
  commands = {
    enabled = true,
    prefix = "SnacksTerminal",
  },
}

---@type SnacksTerminalManager.Config
local config -- resolved in M.setup()

local function term_meta(buf)
  return vim.b[buf].snacks_terminal or {}
end

-- Opts passed to Snacks.terminal.focus. User `terminal` opts are merged in, but
-- cwd (from `root`) and count are always managed by the plugin.
local function terminal_opts(count)
  local extra = config.terminal
  if type(extra) == "function" then
    extra = extra(count)
  end
  return vim.tbl_extend("force", extra or {}, { cwd = config.root(), count = count })
end

local function focus_terminal(count)
  Snacks.terminal.focus(nil, terminal_opts(count))
end

-- Recently focused terminal buffers, most-recent first. Updated on BufEnter and
-- filtered against live terminals, so killed ones are skipped over. Keyed by
-- buffer number rather than snacks' terminal id, which is only the <count> and
-- is shared by terminals that differ only in cwd/env.
local mru_bufs = {}

local function remember_terminal(buf)
  for i, existing in ipairs(mru_bufs) do
    if existing == buf then
      table.remove(mru_bufs, i)
      break
    end
  end
  table.insert(mru_bufs, 1, buf)
end

-- Most recently focused terminal that is still open, if any. Callers with the
-- terminal list already in hand can pass it to avoid a second lookup.
local function mru_terminal(terms)
  local by_buf = {}
  for _, t in ipairs(terms or Snacks.terminal.list()) do
    by_buf[t.buf] = t
  end
  for _, buf in ipairs(mru_bufs) do
    if by_buf[buf] then
      return by_buf[buf]
    end
  end
end

-- Focus a terminal window, hiding it again if it is already the current buffer
-- (mirrors Snacks.terminal.focus's toggle behaviour for a known window).
local function focus_win(win)
  if vim.api.nvim_get_current_buf() == win.buf then
    win:hide()
  else
    win:show():focus()
  end
end

-- The managed terminal for the current buffer, if we are inside one.
local function current_terminal()
  local buf = vim.api.nvim_get_current_buf()
  for _, t in ipairs(Snacks.terminal.list()) do
    if t.buf == buf then
      return t
    end
  end
end

-- Live terminals sorted by id (the <count>), for stable cycling/listing.
local function sorted_terms()
  local terms = Snacks.terminal.list()
  table.sort(terms, function(a, b)
    return (term_meta(a.buf).id or 0) < (term_meta(b.buf).id or 0)
  end)
  return terms
end

local function process_tree()
  local ok, out = pcall(vim.fn.system, { "ps", "-Ao", "pid=,ppid=,comm=" })
  if not ok or vim.v.shell_error ~= 0 then
    return nil
  end
  local comm, children = {}, {}
  for line in out:gmatch("[^\n]+") do
    local pid_s, ppid_s, name = line:match("^%s*(%d+)%s+(%d+)%s+(.+)$")
    local pid, ppid = tonumber(pid_s), tonumber(ppid_s)
    if pid and ppid then
      comm[pid] = name
      children[ppid] = children[ppid] or {}
      table.insert(children[ppid], pid)
    end
  end
  return { comm = comm, children = children }
end

local function foreground_process(tree, pid)
  if not (tree and pid) then
    return nil
  end
  local deepest, max_depth = pid, 0
  local function walk(p, depth)
    if depth > max_depth then
      deepest, max_depth = p, depth
    end
    for _, child in ipairs(tree.children[p] or {}) do
      walk(child, depth + 1)
    end
  end
  walk(pid, 0)
  local name = tree.comm[deepest]
  return name and vim.fn.fnamemodify(name, ":t") or nil
end

local function term_cwd(buf)
  -- terminal buffers are named "term://{cwd}//{pid}:{cmd}"
  local title = vim.b[buf].term_title or ""
  return vim.fn.fnamemodify(title:match("^term://(.-)//") or "", ":~")
end

local function terminal_label(t, tree, mru_buf)
  local p = config.picker
  local id = term_meta(t.buf).id
  local name = vim.b[t.buf].terminal_name
  local process = tree and foreground_process(tree, vim.b[t.buf].terminal_job_pid) or nil
  local cwd = p.cwd and term_cwd(t.buf) or nil
  local active = t.buf == mru_buf

  if p.format then
    return p.format({ buf = t.buf, id = id, name = name, process = process, cwd = cwd, active = active })
  end

  -- pad the inactive marker to the marker's display width so columns line up
  local marker = active and p.marker or (" "):rep(vim.fn.strdisplaywidth(p.marker))
  local label = name and ("[" .. name .. "] ") or ""
  local desc = vim.trim((process or "") .. "  " .. (cwd or ""))
  return ("%s (%s)  %s%s"):format(marker, id or "?", label, desc)
end

local function pick_terminal(prompt, on_choice)
  local terms = sorted_terms()
  if #terms == 0 then
    return vim.notify(config.picker.empty, vim.log.levels.INFO)
  end
  local tree = config.picker.process and process_tree() or nil
  local mru = mru_terminal(terms)
  local mru_buf = mru and mru.buf
  vim.ui.select(terms, {
    prompt = prompt,
    format_item = function(t)
      return terminal_label(t, tree, mru_buf)
    end,
  }, function(t)
    if t then
      on_choice(t)
    end
  end)
end

--- Focus terminal number `n`, or the most-recently-used terminal when `n` is
--- falsy/0. Toggles the terminal closed when it is already the current buffer.
--- Pair with `vim.v.count` in a keymap for count-prefixed access (e.g. `3<C-/>`).
---@param n? integer
function M.toggle(n)
  n = tonumber(n) or 0
  if n > 0 then
    return focus_terminal(n)
  end
  local term = mru_terminal()
  if term then
    focus_win(term)
  else
    focus_terminal(1)
  end
end

--- Pick a terminal and focus it.
function M.pick()
  pick_terminal(config.picker.prompt, function(t)
    t:show():focus()
  end)
end

local function rename_prompt(t)
  vim.ui.input({
    prompt = config.rename.input_prompt,
    default = vim.b[t.buf].terminal_name,
    -- line up with the select picker, which centers a 0.4-high box (top ~0.3).
    win = { row = 0.3 },
  }, function(name)
    if name then
      vim.b[t.buf].terminal_name = name ~= "" and name or nil
    end
  end)
end

--- Rename a terminal (names show up in the picker and winbar). Renames the
--- current terminal directly when invoked from inside one, otherwise picks.
function M.rename()
  local cur = current_terminal()
  if cur then
    return rename_prompt(cur)
  end
  pick_terminal(config.rename.select_prompt, rename_prompt)
end

-- Kill a terminal: deleting the buffer stops the job and triggers snacks'
-- BufWipeout cleanup (removing it from the registry and closing its window).
local function close_terminal(t)
  if vim.api.nvim_buf_is_valid(t.buf) then
    vim.api.nvim_buf_delete(t.buf, { force = true })
  end
end

--- Close (kill) a terminal. Closes the current terminal directly when invoked
--- from inside one, otherwise picks.
function M.close()
  local cur = current_terminal()
  if cur then
    return close_terminal(cur)
  end
  pick_terminal(config.close.select_prompt, close_terminal)
end

-- Focus the terminal `delta` steps from the current one (by id, wrapping). When
-- not inside a terminal, jump to the first (next) or last (prev).
local function cycle(delta)
  local terms = sorted_terms()
  if #terms == 0 then
    return focus_terminal(1)
  end
  local cur, idx = current_terminal(), 0
  if cur then
    for i, t in ipairs(terms) do
      if t.buf == cur.buf then
        idx = i
        break
      end
    end
  end
  local target = idx == 0 and (delta > 0 and 1 or #terms) or ((idx - 1 + delta) % #terms) + 1
  terms[target]:show():focus()
end

--- Focus the next terminal by id (wraps around).
function M.next()
  cycle(1)
end

--- Focus the previous terminal by id (wraps around).
function M.prev()
  cycle(-1)
end

-- Terminals (including lazygit) share the "terminal" style, so its winbar would
-- land on floats too. A winbar that merely renders empty still reserves a row,
-- so clear the option outright for floating terminals unless winbar.floating is
-- enabled.
---@param self snacks.win
function M.on_win(self)
  local floating = config and config.winbar and config.winbar.floating
  if not floating and self:is_floating() then
    vim.wo[self.win].winbar = ""
  end
end

local function create_commands()
  local prefix = config.commands.prefix

  -- args.count carries a count given to the command (`:3.Toggle`); fall back to
  -- v:count so a `<cmd>.Toggle<cr>` keymap still honours a typed count (`3<C-/>`).
  vim.api.nvim_create_user_command(prefix .. "Toggle", function(args)
    M.toggle(args.count > 0 and args.count or vim.v.count)
  end, { count = 0, desc = "Focus the MRU terminal, or terminal [count]" })

  vim.api.nvim_create_user_command(prefix .. "Pick", function()
    M.pick()
  end, { desc = "Pick a terminal to focus" })

  vim.api.nvim_create_user_command(prefix .. "Rename", function()
    M.rename()
  end, { desc = "Rename a terminal (the current one, or pick)" })

  vim.api.nvim_create_user_command(prefix .. "Close", function()
    M.close()
  end, { desc = "Close a terminal (the current one, or pick)" })

  vim.api.nvim_create_user_command(prefix .. "Next", function()
    M.next()
  end, { desc = "Focus the next terminal" })

  vim.api.nvim_create_user_command(prefix .. "Prev", function()
    M.prev()
  end, { desc = "Focus the previous terminal" })
end

-- Accept `winbar`/`commands` as booleans as well as tables.
local function normalize(opts)
  opts = vim.deepcopy(opts or {})
  for _, key in ipairs({ "winbar", "commands" }) do
    if type(opts[key]) == "boolean" then
      opts[key] = { enabled = opts[key] }
    end
  end
  return opts
end

--- Configure the plugin. Registers MRU tracking, the winbar, and user commands.
--- Keymaps are intentionally left to the user — bind the commands or the API
--- (`toggle`/`pick`/`rename`/`close`/`next`/`prev`) in your own config.
---@param opts? SnacksTerminalManager.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), normalize(opts))

  if not (rawget(_G, "Snacks") and Snacks.terminal) then
    vim.notify(
      "[snacks-terminal-manager] requires folke/snacks.nvim with the terminal module enabled",
      vim.log.levels.ERROR
    )
    return
  end

  -- Track most-recently-used terminals by buffer number.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("snacks_terminal_manager_mru", { clear = true }),
    callback = function(ev)
      if term_meta(ev.buf).id then
        remember_terminal(ev.buf)
      end
    end,
  })

  -- Merge the winbar + float-stripping into snacks' "terminal" style. Existing
  -- user config wins (Snacks.config.style merges our values underneath).
  if config.winbar.enabled ~= false then
    Snacks.config.style("terminal", {
      wo = { winbar = config.winbar.format or DEFAULT_WINBAR },
      on_win = M.on_win,
    })
  end

  if config.commands.enabled ~= false then
    create_commands()
  end
end

return M
