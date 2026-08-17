--- Order a directory's children the way its `mod.rs` / `lib.rs` declares them.
---
--- For a stratified codebase the declaration order IS the architecture — the
--- floor first, whatever sees everything last — and an alphabetical tree throws
--- that away every time it is drawn. Neo-tree hands the comparison over, so
--- here it costs a config hook. (Zed does not: its panel sorts in compiled code
--- with no extension hook at all, which is why the same idea needs a fork of
--- the editor over there and forty lines of Lua here.)
---
--- Children the module list does not mention keep their usual place, after the
--- declared ones — so a directory reads as its module list, then Cargo.toml,
--- README.md and the rest.

local M = {}

--- The event loop's cached time, which does NOT move while a single sort runs,
--- however many comparisons that sort makes.
---
--- Two different questions are being asked of the filesystem here and they
--- deserve different answers. "Has this file changed?" is answered by an mtime.
--- "Is it worth asking?" is answered by this: a comparison function is called
--- O(n log n) times per redraw, so anything done per comparison is done a
--- hundred times for one screenful. Gating the work on the tick collapses that
--- to once per redraw, which is the rate at which the answer can actually
--- differ.
---@return integer
local function tick()
  return vim.uv.now()
end

--- Cached per directory, keyed on the module file's path and mtime: the tree
--- redraws on every keystroke in filter mode, and re-reading a `mod.rs` each
--- time would be felt. `ranks` is nil for a directory with no module list,
--- which most directories are and all of which used to re-ask.
---@type table<string, { path: string?, mtime: integer, checked: integer, ranks: table<string, integer>? }>
local cache = {}

--- The module name this line declares, if it declares one.
---
--- Line-based on purpose. A `mod X;` is the whole of what matters and it always
--- sits at column zero; anything cleverer would need a parser to answer a
--- question that is one pattern deep.
---@param line string
---@return string?
local function declared_name(line)
  return line:match("^mod%s+([%w_]+)%s*;")
    or line:match("^pub%s+mod%s+([%w_]+)%s*;")
    or line:match("^pub%s*%b()%s*mod%s+([%w_]+)%s*;")
end

--- `{ name -> position }` for a directory, or nil when it has no module list.
---@param dir string
---@return table<string, integer>?
local function ranks_for(dir)
  local hit = cache[dir]
  if hit and hit.checked == tick() then
    return hit.ranks
  end

  -- `main.rs` is a crate root exactly as much as `lib.rs` is, and a binary is
  -- where a stratified layout shows itself most — the top of the program is
  -- the one place the whole stack is named in order. Leaving it out sorted
  -- every `src/` of every binary crate alphabetically.
  local path, stat
  for _, root in ipairs({ "/mod.rs", "/lib.rs", "/main.rs" }) do
    path = dir .. root
    stat = vim.uv.fs_stat(path)
    if stat then
      break
    end
  end

  local function remember(ranks)
    cache[dir] = {
      path = stat and path or nil,
      mtime = stat and stat.mtime.sec or 0,
      checked = tick(),
      ranks = ranks,
    }
    return ranks
  end

  if not stat then
    return remember(nil)
  end
  -- The path is compared as well as the mtime because a directory can change
  -- WHICH root it has — a `mod.rs` added beside a `lib.rs` — and two files are
  -- perfectly free to share a timestamp.
  if hit and hit.path == path and hit.mtime == stat.mtime.sec then
    hit.checked = tick()
    return hit.ranks
  end

  local ranks, next_rank = {}, 1
  local ok = pcall(function()
    for line in io.lines(path) do
      -- Tests live at the end and declare modules that are not children of
      -- this directory at all.
      if line:match("^#%[cfg%(test%)%]") then
        break
      end
      local name = declared_name(line)
      if name and not ranks[name] then
        ranks[name] = next_rank
        next_rank = next_rank + 1
      end
    end
  end)
  if not ok or next_rank == 1 then
    return remember(nil)
  end
  return remember(ranks)
end

--- Cached per manifest, keyed on its mtime, like the module lists.
---@type table<string, { mtime: integer, ranks: table<string, integer> }>
local ws_cache = {}

--- `{ absolute path -> position }` for a workspace's `members = [...]`.
---
--- A member entry names a FOLDER as often as a crate — `crates/business-logic/*`
--- is one entry covering a directory of crates — so the glob is stripped rather
--- than expanded and the folder itself is what gets ranked. That is the whole
--- point at this scale: the three strata, in the order they stand on each
--- other, instead of the alphabet.
---@param manifest string
---@return table<string, integer>?
local function member_ranks(manifest)
  local stat = vim.uv.fs_stat(manifest)
  if not stat then
    return nil
  end
  local hit = ws_cache[manifest]
  if hit and hit.mtime == stat.mtime.sec then
    return hit.ranks
  end

  local dir = vim.fs.dirname(manifest)
  local ranks, next_rank, inside = {}, 1, false
  local ok = pcall(function()
    for line in io.lines(manifest) do
      local bare = line:gsub("%s", "")
      if bare:match("^#") then
        goto continue
      end
      -- `default-members` is a different list with a different job.
      if not inside then
        if bare:match("^members=%[") then
          inside = true
        else
          goto continue
        end
      end
      for entry in line:gmatch('"([^"]+)"') do
        local folder = entry:gsub("/%*$", "")
        local path = dir .. "/" .. folder
        ranks[path] = next_rank
        -- A member listed EXPLICITLY is a crate, not the folder holding it, so
        -- `crates/business-logic` would have no rank of its own and fall back
        -- to the alphabet. Give every ancestor the earliest rank beneath it:
        -- a folder takes the place of the first crate in it that anything else
        -- stands on.
        local at = vim.fs.dirname(path)
        while at and #at > #dir do
          if not ranks[at] or ranks[at] > next_rank then
            ranks[at] = next_rank
          end
          at = vim.fs.dirname(at)
        end
        next_rank = next_rank + 1
      end
      if line:find("%]") and inside and not bare:match("^members=%[$") then
        break
      end
      ::continue::
    end
  end)
  if not ok or next_rank == 1 then
    ws_cache[manifest] = nil
    return nil
  end

  ws_cache[manifest] = { mtime = stat.mtime.sec, ranks = ranks }
  return ranks
end

--- The answer `workspace_ranks` gave this directory on the current tick.
---
--- The walk itself is what is remembered, not just its result: finding the
--- manifest costs a stat per level and a directory eight deep pays it every
--- time two of its children are compared, which is most of the cost of a
--- lookup that usually ends in "no".
---@type table<string, { checked: integer, ranks: table<string, integer>? }>
local ws_lookup = {}

--- The nearest `Cargo.toml` at or above this directory that declares members.
---@param dir string
---@return table<string, integer>?
local function workspace_ranks(dir)
  local hit = ws_lookup[dir]
  if hit and hit.checked == tick() then
    return hit.ranks
  end

  local ranks
  local at = dir
  for _ = 1, 32 do
    ranks = member_ranks(at .. "/Cargo.toml")
    if ranks then
      break
    end
    local up = vim.fs.dirname(at)
    if up == at or up == "" then
      break
    end
    at = up
  end

  ws_lookup[dir] = { checked = tick(), ranks = ranks }
  return ranks
end

--- Cached per directory of crates, keyed on the newest manifest mtime, and
--- revalidated at most once per tick. `ranks` is nil for a directory that holds
--- no crates, which is a real answer worth keeping.
---@type table<string, { mtime: integer, checked: integer, ranks: table<string, integer>? }>
local crate_cache = {}

--- A crate manifest's package name and the packages it depends on.
---
--- `[dev-dependencies]` are NOT read. A test crate reaching sideways for a
--- fixture says nothing about which layer stands on which, and counting it is
--- how a layering rule starts reporting cycles that are not there.
---@param manifest string
---@return string?, table<string, true>
local function package_and_deps(manifest)
  local name, deps, section = nil, {}, ""
  local ok = pcall(function()
    for line in io.lines(manifest) do
      local trimmed = line:match("^%s*(.-)%s*$")
      if not trimmed:match("^#") then
        if trimmed:match("^%[") then
          section = (trimmed == "[package]" and "package")
            or (trimmed == "[dependencies]" and "dependencies")
            or ""
          local long = trimmed:match("^%[dependencies%.([%w_-]+)%]$")
          if long then
            deps[long] = true
          end
        elseif section == "package" then
          name = trimmed:match('^name%s*=%s*"([^"]+)"') or name
        elseif section == "dependencies" then
          -- `mcg-search-index.workspace = true` is ONE dependency whose key
          -- carries a sub-field; keeping the whole key hides every
          -- workspace-inherited edge, which is most of them here.
          local key = trimmed:match("^([%w_.-]+)%s*=")
          if key then
            deps[key:match("^([^.]+)")] = true
          end
        end
      end
    end
  end)
  if not ok then
    return nil, {}
  end
  return name, deps
end

--- `{ absolute path -> position }` for a directory of sibling CRATES, ordered
--- so a crate comes after everything it depends on.
---
--- A `members` glob like `crates/business-logic/*` covers a folder of crates
--- and says nothing about their order, so the order has to be read out of the
--- crates themselves. Independents keep their alphabetical place, so this is a
--- stable answer rather than a different one each redraw.
---@param dir string
---@return table<string, integer>?
local function crate_ranks(dir)
  local hit = crate_cache[dir]
  if hit and hit.checked == tick() then
    return hit.ranks
  end

  -- Cheap pass. Which children carry a manifest, and when was the newest of
  -- them touched — no manifest is READ here. "Has anything changed" is a stat,
  -- and on a folder of thirty crates that is the difference between thirty
  -- stats and thirty whole files, once per redraw instead of once per
  -- comparison.
  local children, newest = {}, 0
  local ok = pcall(function()
    for name, kind in vim.fs.dir(dir) do
      if kind == "directory" then
        local stat = vim.uv.fs_stat(dir .. "/" .. name .. "/Cargo.toml")
        if stat then
          table.insert(children, name)
          newest = math.max(newest, stat.mtime.sec)
        end
      end
    end
  end)
  if not ok then
    crate_cache[dir] = nil
    return nil
  end

  -- A "no" is remembered like any other answer. Every ordinary source
  -- directory falls all the way through to here, so leaving the negative
  -- uncached would rescan the whole tree on each comparison to learn nothing,
  -- which is the same waste in a cheaper suit.
  local function remember(ranks)
    crate_cache[dir] = { mtime = newest, checked = tick(), ranks = ranks }
    return ranks
  end

  if #children < 2 then
    return remember(nil)
  end
  if hit and hit.mtime == newest then
    hit.checked = tick()
    return hit.ranks
  end

  -- Expensive pass, reached only when something under this directory actually
  -- moved.
  table.sort(children)
  local names, deps_of, crates = {}, {}, {}
  for _, child in ipairs(children) do
    local pkg, deps = package_and_deps(dir .. "/" .. child .. "/Cargo.toml")
    -- A manifest with no `[package] name` is a virtual workspace, not a crate.
    if pkg then
      table.insert(crates, child)
      names[pkg] = child
      deps_of[child] = deps
    end
  end
  if #crates < 2 then
    return remember(nil)
  end
  children = crates

  -- Place, repeatedly, the first crate whose dependencies are all placed.
  -- A cycle would stall this, so anything still unplaced is appended in its
  -- original order: no arrangement satisfies a cycle, and inventing one would
  -- be worse than leaving it alone.
  local placed, ranks, rank = {}, {}, 1
  for _ = 1, #children do
    local progressed = false
    for _, child in ipairs(children) do
      if not placed[child] then
        local ready = true
        for dep in pairs(deps_of[child]) do
          local sibling = names[dep]
          if sibling and not placed[sibling] then
            ready = false
            break
          end
        end
        if ready then
          placed[child] = true
          ranks[dir .. "/" .. child] = rank
          rank = rank + 1
          progressed = true
        end
      end
    end
    if not progressed then
      break
    end
  end
  for _, child in ipairs(children) do
    if not placed[child] then
      ranks[dir .. "/" .. child] = rank
      rank = rank + 1
    end
  end

  return remember(ranks)
end

--- What a `mod X;` would call this node: a directory by its name, a file by its
--- name without `.rs`.
---@param node { path: string, type: string }
---@return string
local function module_name(node)
  local base = vim.fs.basename(node.path)
  return (base:gsub("%.rs$", ""))
end

--- Neo-tree's `sort_function`: true when `a` comes before `b`.
---
--- Falls through to neo-tree's own rule — directories first, then path — for
--- anything the module list does not rank, so a directory without a `mod.rs`
--- behaves exactly as it does today.
---@param a { path: string, type: string }
---@param b { path: string, type: string }
---@return boolean
function M.sort(a, b)
  local dir = vim.fs.dirname(a.path)
  if dir == vim.fs.dirname(b.path) then
    local ranks = ranks_for(dir)
    if ranks then
      local rank_a, rank_b = ranks[module_name(a)], ranks[module_name(b)]
      if rank_a and rank_b then
        return rank_a < rank_b
      end
      -- A declared child outranks an undeclared one, whichever is a directory.
      if rank_a then
        return true
      end
      if rank_b then
        return false
      end
    end
  end

  -- One scale up: a workspace's `members` list orders the crate FOLDERS.
  -- Only reached when the directory has no module list of its own, which is
  -- exactly the case for `crates/` and for a workspace root.
  local ranks = workspace_ranks(dir)
  if ranks then
    local rank_a, rank_b = ranks[a.path], ranks[b.path]
    if rank_a and rank_b then
      return rank_a < rank_b
    end
    if rank_a then
      return true
    end
    if rank_b then
      return false
    end
  end

  -- Widest scale: a folder of sibling crates, ordered by what depends on what.
  -- A `members` glob names the folder and stops there, so this is the only
  -- thing that can order what is inside it.
  local crates = crate_ranks(dir)
  if crates then
    local rank_a, rank_b = crates[a.path], crates[b.path]
    if rank_a and rank_b then
      return rank_a < rank_b
    end
    if rank_a then
      return true
    end
    if rank_b then
      return false
    end
  end

  if a.type == b.type then
    return a.path < b.path
  end
  return a.type < b.type
end

--- Forget everything, for when a `mod.rs` changed under us in a way mtime did
--- not catch (a checkout, a rebase).
function M.forget()
  cache = {}
  ws_cache = {}
  ws_lookup = {}
  crate_cache = {}
end

return M
