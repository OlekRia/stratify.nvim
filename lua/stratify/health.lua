--- `:checkhealth stratify`.
---
--- The failure this plugin actually has is silence. Hand `sort_function` to a
--- table neo-tree never reads, or hand it a function neo-tree quietly rejects,
--- and the tree just stays alphabetical — nothing is printed, nothing errors,
--- and the only symptom is a sort order that looks like the one you were trying
--- to replace. Every check below is a way of being wrong that looks exactly
--- like being right.

local M = {}

--- Neo-tree's own gate, reproduced.
---
--- Before using a `sort_function` it calls it with two nodes and drops it — for
--- the alphabet, without a word to the user — if the call throws or returns
--- anything but a boolean. A check that only asked "is it installed?" would
--- pass in precisely the case worth catching.
---@param fn function
---@return boolean, string?
local function probe(fn)
  local ok, result = pcall(fn, { type = "dir", path = "foo" }, { type = "dir", path = "baz" })
  if not ok then
    return false, tostring(result)
  end
  if type(result) ~= "boolean" then
    return false, ("returned a %s, not a boolean"):format(type(result))
  end
  return true
end

function M.check()
  vim.health.start("stratify.nvim")

  local ok, neotree = pcall(require, "neo-tree")
  if not ok then
    vim.health.error("neo-tree could not be loaded", {
      "stratify orders neo-tree's tree; without it there is nothing to order.",
    })
    return
  end

  -- `setup()` only STASHES the user's table; the merge with the defaults is
  -- deferred to `ensure_config()`, which nothing calls until the tree is first
  -- opened. Reading `.config` here would therefore report "not set up" to a
  -- perfectly configured user who simply has not pressed the key yet. Asking
  -- for the merge is what opening the tree would have done, and it is what
  -- neo-tree itself will read at sort time.
  local merged, config = pcall(neotree.ensure_config)
  if not merged then
    config = neotree.config
  end
  if not config then
    vim.health.warn("neo-tree's config could not be read", {
      "Open the tree once, then run :checkhealth stratify again.",
    })
    return
  end
  vim.health.ok("neo-tree is installed")

  local sort = config.sort_function
  if sort == nil then
    vim.health.error("neo-tree's `sort_function` is unset — the tree is alphabetical", {
      "If your plugin spec uses `opts`:",
      "",
      "    opts.sort_function = require('stratify').sort",
      "",
      "If it has a `config = function()` that calls `require('neo-tree').setup({...})`",
      "itself — as LazyVim's default config often does — then `opts` is never",
      "consulted, and the line has to go inside that table instead.",
    })
    return
  end

  if sort ~= require("stratify").sort then
    vim.health.warn("`sort_function` is set, but not to stratify's", {
      "Something else owns the comparison and stratify is loaded but idle.",
      "This is fine if you meant it.",
    })
  else
    vim.health.ok("`sort_function` is stratify's")
  end

  local clean, why = probe(sort)
  if clean then
    vim.health.ok("it passes neo-tree's validity probe")
  else
    vim.health.error("it fails neo-tree's validity probe: " .. why, {
      "Neo-tree drops a sort function that throws or returns a non-boolean and",
      "falls back to alphabetical without saying so — which is what you would",
      "be looking at right now.",
    })
  end

  -- Scope, not correctness: everything above can pass in a tree stratify has
  -- nothing to say about, and the resulting "it does nothing" is easy to read
  -- as a bug.
  local cwd = vim.uv.cwd()
  if cwd and vim.uv.fs_stat(cwd .. "/Cargo.toml") then
    vim.health.ok("the working directory is a Rust project")
  else
    vim.health.info(
      "no `Cargo.toml` in the working directory. stratify reads `mod X;` and Cargo "
        .. "`members`, so outside a Rust tree it has nothing to order and neo-tree's "
        .. "own rule stands — an unchanged tree here is the plugin working, not failing."
    )
  end
end

return M
