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

Optional: drop the caches after a checkout or rebase.

```lua
vim.keymap.set("n", "<leader>fS", function()
  require("stratify").forget()
  require("neo-tree.sources.manager").refresh("filesystem")
end, { desc = "Stratify: re-read module order" })
```

## Cost

Every lookup is cached per directory against the file's mtime. The tree
re-sorts on each keystroke in filter mode, so re-reading a `mod.rs` each time
would be felt; reading it once per change is not.

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
