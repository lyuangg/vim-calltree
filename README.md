# vim-calltree

English | [中文](README.zh-CN.md)

Call hierarchy tree for Vim. Shows who calls the function under the cursor and
what it calls, as a lazily expanded tree with a source preview. LSP languages
use [vim-lsp](https://github.com/prabirshrestha/vim-lsp) and the LSP 3.16 call
hierarchy protocol; PHP uses the server's `definition`/`references` where
available and falls back to static search.

```
● mid  main.go:7
  ▾ ▲ Callers (1)
    ▾ top  main.go:9
      ▸ main  main.go:11
  ▾ ▼ Callees (1)
    ▸ leaf  main.go:5
```

## Requirements

- Vim 8.2 or newer (jobs, text properties, shared dicts). Tested on Vim 9.2 with
  `g:lsp_use_native_client = 1`.
- vim-lsp.
- A language server implementing `callHierarchyProvider`. Verified with gopls.
- For PHP: ripgrep (`rg`) or `ag` on `$PATH`; a PHP language server is
  optional.

## Installation

```vim
Plug 'prabirshrestha/vim-lsp'
Plug 'lyuangg/vim-calltree'
```

## Usage

Place the cursor on a function name and run `:CallTree`. The position must be on
the identifier, as required by `textDocument/prepareCallHierarchy`.

The tree opens in a new tab: tree on the left, source preview on the right. The
original tab is not modified.

### PHP

PHP language servers generally do not implement call hierarchy. The plugin uses
`textDocument/definition` and `textDocument/references` when a server is
available, enumerates callees from the source, and falls back to `rg`/`ag`
search when the server cannot answer.

`g:calltree_php_provider` selects the backend:

| Value | Behaviour |
| --- | --- |
| `'auto'` | Server first, search fallback (default) |
| `'lsp'` | Server only, no search fallback |
| `'search'` | Search only, no server required |

In search mode, callers are matched by class and visibility rather than by
name alone. The workspace root is the nearest ancestor containing `.git` or
`composer.json`.

### Commands

| Command | Description |
| --- | --- |
| `:CallTree` | Open the tree for the current function, callers and callees, one level each |
| `:CallTreeCallers` | Same, callers only |
| `:CallTreeCallees` | Same, callees only |
| `:CallTreeExpand` | Expand the visible tree by one more level |
| `:CallTreeQF` | Export the visible nodes to the quickfix list |
| `:CallTreeRefresh` | Re-resolve from the position the tree was opened at |
| `:CallTreeClose` | Close the tree tab |

### Keys

All mappings are buffer-local to the tree and available as `<Plug>`.

| Key | `<Plug>` | Action |
| --- | --- | --- |
| `<CR>`, `o` | `(calltree-toggle)` | Expand or collapse the node under the cursor |
| `e` | `(calltree-open)` | Open the file at its definition in the window `:CallTree` was run from |
| `g<CR>` | `(calltree-jump)` | Show the definition in the preview window |
| `gs` | `(calltree-jump-site)` | Show the call site in the preview window |
| `K` | `(calltree-float)` | Show the definition in a floating window |
| `L` | `(calltree-expand-level)` | Expand the visible tree by one level |
| `]c` / `[c` | `(calltree-next-site)` / `(calltree-prev-site)` | Next / previous call site of the node |
| `<BS>` | `(calltree-parent)` | Move to the parent node |
| `Q` | `(calltree-quickfix)` | Export to the quickfix list |
| `r` | `(calltree-refresh)` | Re-resolve |
| `q` | `(calltree-close)` | Close the tree tab |

### Preview

Moving in the tree with `j`, `k`, `gg`, `G` or a search updates the preview
window. The preview is a scratch buffer (`calltree://<path>`, `buftype=nofile`),
not the file itself: no buffer is added to the buffer list and no `didOpen` is
sent. Content is taken from an already loaded buffer when one exists, so unsaved
changes are visible, and read from disk otherwise. The filetype is set from the
extension, so syntax highlighting is preserved.

By default the preview shows the call site. Set `g:calltree_preview_site = 0`
to show the definition instead.

### Ordering

Siblings are ordered by source position, not by the order returned by the
server:

- Callees: the order of the calls in the function body.
- Callers: by file, then by the caller's definition position.
- Multiple call sites of one function: ascending line order, matching `]c`/`[c`.

### Markers

| Marker | Meaning |
| --- | --- |
| `●` | Root node |
| `▾` / `▸` | Expanded / collapsed |
| `·` | Leaf (no results) |
| `…` | Request in flight |
| `↻` | Cycle, ancestor already contains this function |
| `×N` | Called from N places |
| `…+N` | N distinct symbols omitted by `g:calltree_max_children` |
| `…+?` | PHP search cap reached; the number of omitted symbols is unknown |

### Highlight groups

| Group | Element | Default |
| --- | --- | --- |
| `CallTreeRoot` | Root node | bold, yellow (dark) / brown (light) |
| `CallTreeCaller` | Caller node | green |
| `CallTreeCallee` | Callee node | blue |
| `CallTreeStdlib` | Standard library (under `GOROOT/src`) | italic teal |
| `CallTreeExternal` | Third-party code (module cache, `vendor/`) | amber |
| `CallTreeCycle` | Cycle marker | bold orange |
| `CallTreeLoading` | Pending request | italic grey |
| `CallTreeUnresolved` | PHP symbol with no definition in the search root | italic grey |
| `CallTreeCount` | `×N`, `…+N` | purple |
| `CallTreeLocation` | File path | grey |
| `CallTreeLine` | Line number | links to `LineNr` |
| `CallTreeMarker` | `●▾▸·↻` | links to `NonText` |
| `CallTreeError` | Error text | links to `ErrorMsg` |

All groups are defined with `highlight default`, so they can be overridden in a
vimrc. They are reapplied on `ColorScheme` and on `:set background`.

## Configuration

| Option | Default | Description |
| --- | --- | --- |
| `g:calltree_tab` | `1` | Open in a new tab. `0` splits the current tab instead |
| `g:calltree_width` | `50` | Tree width as a percentage of `&columns` |
| `g:calltree_max_children` | `50` | Maximum children listed per node |
| `g:calltree_auto_expand` | `1` | Levels expanded when the tree opens |
| `g:calltree_expand_limit` | `30` | Maximum concurrent requests per `:CallTreeExpand` |
| `g:calltree_preview` | `1` | Follow the cursor with the preview window |
| `g:calltree_preview_site` | `1` | Preview the call site instead of the definition |
| `g:calltree_preview_delay` | `60` | Preview debounce in milliseconds |
| `g:calltree_preview_max_bytes` | `2097152` | Files larger than this are not previewed |
| `g:calltree_float_height` | `20` | Maximum height of the `K` popup in lines; longer bodies page with `<C-d>`/`<C-u>` |
| `g:calltree_float_width` | `100` | Maximum width of the `K` popup in cells |
| `g:calltree_default_maps` | `1` | Install the default keys. `0` provides only `<Plug>` |
| `g:calltree_php_provider` | `'auto'` | `'auto'` (server + search fallback), `'lsp'` (server only), `'search'` |
| `g:calltree_php_references_fallback` | `1` | In `'auto'` mode, fall back to search when `references` returns nothing (server still indexing) |
| `g:calltree_php_callee_definition` | `1` | Resolve each callee call site with `textDocument/definition` |
| `g:calltree_php_engine` | `'auto'` | `'rg'`, `'ag'`, or `'auto'` |
| `g:calltree_php_max_results` | `300` | Maximum raw matches read per search |
| `g:calltree_php_timeout` | `15000` | Search timeout in milliseconds |
| `g:calltree_php_max_bytes` | `2097152` | Files larger than this are not parsed |
| `g:calltree_php_ignore` | `['vendor', 'node_modules']` | Directories skipped by call-site searches |
| `g:calltree_php_globs` | `['*.php', '*.phtml']` | File globs searched for PHP call sites |

## Limitations

- The graph is static. Reflection, generated code, and calls through `any` are
  not resolved.
- Every expansion is a separate request. Press `r` after changing code.
- Callers and callees are limited to `g:calltree_max_children` per node; the
  remainder is reported as `…+N`.
- PHP callers use `textDocument/references` when a server is available. Search
  mode matches by class and visibility; aliased class names and calls through
  variables remain approximate.
- PHP callees are enumerated from the source and resolved by definition when
  available, otherwise by name.
- PHP dynamic calls, trait methods without a same-file definition, and
  `use function` aliases are not resolved. Search reads files from disk and is
  capped by `g:calltree_php_max_results` (`…+?`).

## Tests

```sh
# Tree model, renderer and quickfix export; no language server required
vim -Nu NONE -es -S test/smoke.vim && cat test/smoke.log

# End to end against gopls
test/integration.sh

# PHP search backend: parser checks and a fixture project (needs rg or ag)
test/php.sh

# PHP + intelephense: definition/references path (skips when not installed)
test/php_lsp.sh
```
