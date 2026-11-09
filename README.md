# vim-calltree

English | [中文](README.zh-CN.md)

Call hierarchy tree for Vim. Shows who calls the function under the cursor and
what it calls, as a lazily expanded tree with a source preview, backed by
[vim-lsp](https://github.com/prabirshrestha/vim-lsp) and the LSP 3.16 call
hierarchy protocol.

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
| `<CR>`, `e` | `(calltree-open)` | Open the file at its definition in the window `:CallTree` was run from |
| `g<CR>` | `(calltree-jump)` | Show the definition in the preview window |
| `gs` | `(calltree-jump-site)` | Show the call site in the preview window |
| `o` | `(calltree-toggle)` | Expand or collapse the node under the cursor |
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
| `g:calltree_default_maps` | `1` | Install the default keys. `0` provides only `<Plug>` |

## Limitations

- The graph is static. Reflection, generated code, and calls through `any` are
  not resolved.
- Every expansion is a separate request. Press `r` after changing code.
- Callers and callees are limited to `g:calltree_max_children` per node; the
  remainder is reported as `…+N`.

## Tests

```sh
# Tree model, renderer and quickfix export; no language server required
vim -Nu NONE -es -S test/smoke.vim && cat test/smoke.log

# End to end against gopls
test/integration.sh
```
