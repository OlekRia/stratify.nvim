# stratify.nvim

**Sort the file tree the way the code declares itself, not the way the alphabet does.**

A `mod.rs` lists its modules in an order somebody chose. A `Cargo.toml` lists
its workspace members in an order somebody chose. For a stratified codebase
that order *is* the architecture — the floor first, whatever sees everything
last — and a file explorer sorted A–Z throws it away every time it draws.

```
alphabetical                    stratify.nvim
────────────                    ─────────────
engine/                         engine/     ← pub mod engine;
http/                           sql/        ← pub mod sql;
runtime/                        http/       ← pub mod http;
sql/                            runtime/    ← pub mod runtime;
lib.rs                          lib.rs
```

## Four scales, tried in order

| a directory containing | is ordered by |
|---|---|
| `mod.rs` / `lib.rs` | its `mod X;` declarations, **files and folders alike** |
| `Cargo.toml` with `members` | that list; a folder takes the rank of the earliest member inside it |
| sibling crates, each with a `Cargo.toml` | dependency order — for `members` globs, which name a folder and say nothing about what is in it |
| none of the above | neo-tree's own rule, untouched |

A folder is a module when it holds a `mod.rs`, so `mod browse;` ranks
`browse/` exactly as it ranks `paths.rs`. Entries nothing declares keep their
usual place, after the declared ones — a directory reads as its module list,
then `Cargo.toml`, `README.md` and the rest.

Reading stops at `#[cfg(test)]`: a test module declares things that are not
children of the directory at all.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "OlekRia/stratify.nvim", lazy = true }
```

Then hand the comparison to it. **Where** depends on how your neo-tree is set
up, and getting this wrong is silent — the tree simply stays alphabetical.

If your spec uses `opts`:

```lua
{
  "nvim-neo-tree/neo-tree.nvim",
  opts = function(_, opts)
    opts.sort_function = require("stratify").sort
    return opts
  end,
}
```

If your spec has a `config = function()` that calls `require("neo-tree").setup({...})`
itself — as LazyVim's default config often does — then `opts` is **never
consulted**, and the line has to go inside that table:

```lua
require("neo-tree").setup({
  sort_function = require("stratify").sort,
  -- ...
})
```

### Check that it took

Getting the placement wrong produces no error — the tree simply stays
alphabetical, which looks exactly like the problem you installed this to fix.

```
:checkhealth stratify
```

It reports whether neo-tree is holding stratify's comparison, and whether that
comparison survives neo-tree's own validity probe — a `sort_function` that
throws is dropped for the alphabet without a word to the user.

Optional: drop the caches after a checkout or rebase.

```lua
vim.keymap.set("n", "<leader>fS", function()
  require("stratify").forget()
  require("neo-tree.sources.manager").refresh("filesystem")
end, { desc = "Stratify: re-read module order" })
```

## Cost

A comparison function is called O(n log n) times per redraw, and the tree
re-sorts on every keystroke in filter mode. So there are two questions, not
one, and they get different answers: *has this file changed* is an mtime, and
*is it worth asking* is the event loop's clock, which does not move while a
single sort runs. Work is therefore done once per **redraw**, not once per
comparison — including the answer "there is nothing here to order", which is
what most directories in most trees have to say.

For a folder of thirty crates, ten redraws:

| | manifests read | stats |
|---|---|---|
| before | 36,601 | 41,480 |
| after | 31 | 35 |

A file edited mid-sort is picked up on the next redraw rather than the current
one — which is also what keeps a sort self-consistent, since a comparator that
changes its mind halfway through is how `table.sort` raises *invalid order
function*.

Parsing is line-based on purpose. `mod X;` sits at column zero and is one
pattern deep; anything cleverer would need a parser to answer a question that
does not have one.

## Checking a codebase, not just looking at it

The same two rules are enforceable, and where they are enforced they belong in
CI rather than in an editor: [stratify](https://github.com/OlekRia/zed-stratify)
is the Rust implementation — a library, a language server that publishes the
violations as diagnostics, and `--check` / `--fix` for a build. This plugin is
the view; that one is the gate.

## Licence

MIT.
