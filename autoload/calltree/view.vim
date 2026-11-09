" autoload/calltree/view.vim
"
" Rendering is deliberately dumb: walk the visible part of the tree, rebuild
" every line, rebuild the line -> node index.  Expansion state lives in the
" nodes rather than in folds, so an async response arriving while the user is
" in another window can never desynchronise the buffer.

let s:highlights = {
      \ 'calltree_marker':  'CallTreeMarker',
      \ 'calltree_root':    'CallTreeRoot',
      \ 'calltree_caller':  'CallTreeCaller',
      \ 'calltree_callee':  'CallTreeCallee',
      \ 'calltree_dir_in':  'CallTreeDirIn',
      \ 'calltree_dir_out': 'CallTreeDirOut',
      \ 'calltree_cycle':   'CallTreeCycle',
      \ 'calltree_stdlib':   'CallTreeStdlib',
      \ 'calltree_external': 'CallTreeExternal',
      \ 'calltree_loading': 'CallTreeLoading',
      \ 'calltree_count':   'CallTreeCount',
      \ 'calltree_loc':     'CallTreeLocation',
      \ 'calltree_lnum':    'CallTreeLine',
      \ 'calltree_err':     'CallTreeError',
      \ }

" Direction carries the meaning: upstream (who calls me) is green, downstream
" (what I call) is blue.  The palette is readable in 8-colour terminals and
" picks lighter shades on dark backgrounds.  `default` keeps any group the
" user defined in their vimrc, and it is re-applied on ColorScheme changes.
function! calltree#view#InitHighlights() abort
  let l:dark = &background ==# 'dark'

  let l:root   = l:dark ? ['#ffd75f', 221] : ['#af5f00', 130]
  let l:caller = l:dark ? ['#87d787', 114] : ['#2e7d32', 28]
  let l:callee = l:dark ? ['#82aaff', 111] : ['#1565c0', 25]
  let l:cycle  = l:dark ? ['#ffaf5f', 215] : ['#d75f00', 166]
  let l:dim    = l:dark ? ['#8a8a8a', 245] : ['#808080', 244]
  let l:count  = l:dark ? ['#d787d7', 176] : ['#9c27b0', 127]
  let l:std    = l:dark ? ['#7fb0b0', 109] : ['#00695c', 30]
  let l:ext    = l:dark ? ['#c9a26b', 180] : ['#8d6e00', 136]

  execute 'highlight default CallTreeRoot guifg=' . l:root[0] . ' ctermfg=' . l:root[1] . ' gui=bold cterm=bold'
  execute 'highlight default CallTreeCaller guifg=' . l:caller[0] . ' ctermfg=' . l:caller[1]
  execute 'highlight default CallTreeCallee guifg=' . l:callee[0] . ' ctermfg=' . l:callee[1]
  execute 'highlight default CallTreeDirIn guifg=' . l:caller[0] . ' ctermfg=' . l:caller[1] . ' gui=bold cterm=bold'
  execute 'highlight default CallTreeDirOut guifg=' . l:callee[0] . ' ctermfg=' . l:callee[1] . ' gui=bold cterm=bold'
  execute 'highlight default CallTreeCycle guifg=' . l:cycle[0] . ' ctermfg=' . l:cycle[1] . ' gui=bold cterm=bold'
  execute 'highlight default CallTreeLoading guifg=' . l:dim[0] . ' ctermfg=' . l:dim[1] . ' gui=italic cterm=italic'
  execute 'highlight default CallTreeCount guifg=' . l:count[0] . ' ctermfg=' . l:count[1]
  execute 'highlight default CallTreeStdlib guifg=' . l:std[0] . ' ctermfg=' . l:std[1] . ' gui=italic cterm=italic'
  execute 'highlight default CallTreeExternal guifg=' . l:ext[0] . ' ctermfg=' . l:ext[1]
  execute 'highlight default CallTreeLocation guifg=' . l:dim[0] . ' ctermfg=' . l:dim[1]
  highlight default link CallTreeMarker NonText
  highlight default link CallTreeLine   LineNr
  highlight default link CallTreeError  ErrorMsg
endfunction

function! s:init_props(bufnr) abort
  " prop_type_add refuses groups that do not exist yet, and Render must work
  " even when plugin/calltree.vim has not been sourced (tests, lazy loaders).
  call calltree#view#InitHighlights()
  for [l:type, l:group] in items(s:highlights)
    if empty(prop_type_get(l:type, {'bufnr': a:bufnr}))
      call prop_type_add(l:type, {'bufnr': a:bufnr, 'highlight': l:group})
    endif
  endfor
endfunction

" Mappings are installed from here rather than only from ftplugin/: setting
" 'filetype' is not guaranteed to source ftplugin when the plugin was added to
" 'runtimepath' late, and a tree buffer without a working `q` is a trap.
function! calltree#view#InitMaps() abort
  if exists('b:calltree_maps')
    return
  endif
  let b:calltree_maps = 1

  nnoremap <buffer> <silent> <Plug>(calltree-jump)      :<C-u>call calltree#action#jump(0)<CR>
  nnoremap <buffer> <silent> <Plug>(calltree-open)      :<C-u>call calltree#action#open()<CR>
  nnoremap <buffer> <silent> <Plug>(calltree-jump-site) :<C-u>call calltree#action#jump(1)<CR>
  nnoremap <buffer> <silent> <Plug>(calltree-float)     :<C-u>call calltree#action#float()<CR>
  nnoremap <buffer> <silent> <Plug>(calltree-toggle)    :<C-u>call calltree#action#toggle()<CR>
  nnoremap <buffer> <silent> <Plug>(calltree-expand-level) :<C-u>call calltree#action#expand_level()<CR>
  nnoremap <buffer> <silent> <Plug>(calltree-parent)    :<C-u>call calltree#action#parent()<CR>
  nnoremap <buffer> <silent> <Plug>(calltree-close)     :<C-u>call calltree#action#close()<CR>
  nnoremap <buffer> <silent> <Plug>(calltree-refresh)   :<C-u>call calltree#refresh()<CR>
  nnoremap <buffer> <silent> <Plug>(calltree-next-site) :<C-u>call calltree#action#cycle_site(1)<CR>
  nnoremap <buffer> <silent> <Plug>(calltree-prev-site) :<C-u>call calltree#action#cycle_site(-1)<CR>
  nnoremap <buffer> <silent> <Plug>(calltree-quickfix)  :<C-u>call calltree#action#quickfix()<CR>

  if !get(g:, 'calltree_default_maps', 1)
    return
  endif
  " <CR> is the key you press without thinking, so it deepens the tree like
  " `o` does; leaving the tree stays on `e` and `g<CR>`.
  nmap <buffer> <CR>   <Plug>(calltree-toggle)
  nmap <buffer> o      <Plug>(calltree-toggle)
  nmap <buffer> e      <Plug>(calltree-open)
  nmap <buffer> g<CR>  <Plug>(calltree-jump)
  nmap <buffer> gs     <Plug>(calltree-jump-site)
  nmap <buffer> K      <Plug>(calltree-float)
  nmap <buffer> L      <Plug>(calltree-expand-level)
  nmap <buffer> <BS>   <Plug>(calltree-parent)
  nmap <buffer> q      <Plug>(calltree-close)
  nmap <buffer> r      <Plug>(calltree-refresh)
  nmap <buffer> ]c     <Plug>(calltree-next-site)
  nmap <buffer> [c     <Plug>(calltree-prev-site)
  nmap <buffer> Q      <Plug>(calltree-quickfix)

  augroup calltree_preview
    autocmd! * <buffer>
    autocmd CursorMoved <buffer> call calltree#action#preview_schedule()
  augroup END
endfunction

" Prefer a tree in the current tab, but reuse one from another tab so that
" :CallTree always brings you back to the same tree tab.
function! calltree#view#FindWindow() abort
  let l:fallback = 0
  for l:info in getwininfo()
    if !getwinvar(l:info['winid'], 'calltree')
      continue
    endif
    if l:info['tabnr'] == tabpagenr()
      return l:info['winid']
    endif
    if l:fallback == 0
      let l:fallback = l:info['winid']
    endif
  endfor
  return l:fallback
endfunction

" The window that shows source in the tree tab.  It carries 'previewwindow', so
" :pclose and <C-w>P behave as usual.
function! calltree#view#ViewerWindow() abort
  for l:info in getwininfo()
    if l:info['tabnr'] == tabpagenr() && getwinvar(l:info['winid'], 'calltree_viewer')
      return l:info['winid']
    endif
  endfor
  return 0
endfunction

" Opens (or reuses) the tree layout and returns
"   {'tree': winid, 'viewer': winid, 'own_tab': 0|1}
" With g:calltree_tab a dedicated tab is created: tree on the left and a
" preview window on the right that follows the cursor.  Your editing layout in
" the original tab stays untouched.
"
" `preview` is {} or {'path', 'lnum', 'col'} used to seed the viewer.
function! calltree#view#OpenWindow(preview) abort
  let l:win = calltree#view#FindWindow()
  if l:win
    call win_gotoid(l:win)
    call calltree#view#Resize()
    return {
          \ 'tree': l:win,
          \ 'viewer': calltree#view#ViewerWindow(),
          \ 'own_tab': getwinvar(l:win, 'calltree_own_tab', 0),
          \ }
  endif

  let l:own_tab = 0
  let l:viewer = 0
  if calltree#cfg('tab', 1)
    tabnew
    let l:viewer = win_getid()
    let l:own_tab = 1
  endif

  vertical topleft new
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal nonumber norelativenumber nolist nowrap cursorline
  setlocal winfixwidth
  setlocal filetype=calltree
  let w:calltree = 1
  let w:calltree_own_tab = l:own_tab
  call calltree#view#InitMaps()
  call calltree#view#Resize()

  if l:viewer
    " Marked after the split on purpose: :split copies window-local options,
    " and 'previewwindow' must not end up on the tree window.
    call setwinvar(l:viewer, 'calltree_viewer', 1)
    call win_execute(l:viewer, 'setlocal previewwindow')
    if !empty(a:preview)
      call win_execute(l:viewer, printf('call calltree#action#_preview(%s, %d, %d)',
            \ string(a:preview['path']), a:preview['lnum'], a:preview['col']))
    endif
  endif

  return {'tree': win_getid(), 'viewer': l:viewer, 'own_tab': l:own_tab}
endfunction

" Width is a percentage of &columns so the tree keeps the same visual share
" when the terminal or GUI window is resized.
function! calltree#view#Resize() abort
  let l:win = calltree#view#FindWindow()
  if !l:win
    return
  endif
  let l:width = max([20, (&columns * calltree#cfg('width', 50)) / 100])
  call win_execute(l:win, 'vertical resize ' . l:width)
endfunction

function! calltree#view#Render(bufnr) abort
  if !bufexists(a:bufnr) || !bufloaded(a:bufnr)
    return
  endif
  let l:ctx = getbufvar(a:bufnr, 'calltree', {})
  if empty(l:ctx)
    return
  endif

  call s:init_props(a:bufnr)

  let l:acc = {
        \ 'lines': [], 'index': {}, 'spans': {},
        \ 'root_dir': get(l:ctx, 'root_dir', ''),
        \ }
  if empty(l:ctx['root'])
    call add(l:acc['lines'], '  Resolving call hierarchy…')
  else
    call s:walk(l:ctx['root'], 0, l:acc)
  endif

  " deletebufline()/setbufline() drop the cursor to line 1, which is very
  " noticeable when expanding with `o`.  Remember which *node* each window was
  " on (not which line number: expanding shifts everything below) and put the
  " cursor back on it afterwards.
  let l:anchors = s:capture_anchors(a:bufnr)

  call setbufvar(a:bufnr, 'calltree_index', l:acc['index'])
  call setbufvar(a:bufnr, '&modifiable', 1)
  call deletebufline(a:bufnr, 1, '$')
  call setbufline(a:bufnr, 1, l:acc['lines'])
  call setbufvar(a:bufnr, '&modified', 0)
  call setbufvar(a:bufnr, '&modifiable', 0)

  call prop_clear(1, len(l:acc['lines']), {'bufnr': a:bufnr})
  for l:lnum in keys(l:acc['spans'])
    for [l:type, l:col, l:len] in l:acc['spans'][l:lnum]
      if l:len > 0
        call prop_add(str2nr(l:lnum), l:col,
              \ {'type': l:type, 'length': l:len, 'bufnr': a:bufnr})
      endif
    endfor
  endfor

  call s:restore_anchors(l:anchors, l:acc['index'], len(l:acc['lines']))
endfunction

function! s:capture_anchors(bufnr) abort
  let l:index = getbufvar(a:bufnr, 'calltree_index', {})
  let l:anchors = []
  for l:win in win_findbuf(a:bufnr)
    let l:lnum = getcurpos(l:win)[1]
    call add(l:anchors, [l:win, l:lnum, get(l:index, l:lnum, {})])
  endfor
  return l:anchors
endfunction

function! s:restore_anchors(anchors, index, line_count) abort
  for [l:win, l:lnum, l:node] in a:anchors
    if win_id2win(l:win) == 0
      continue
    endif
    let l:target = 0
    if !empty(l:node)
      for [l:candidate_lnum, l:candidate] in items(a:index)
        if l:candidate is l:node
          let l:target = str2nr(l:candidate_lnum)
          break
        endif
      endfor
    endif
    if l:target == 0
      " The node is gone (refresh, or its parent collapsed): stay as close as
      " possible instead of jumping to the top.
      let l:target = min([l:lnum, max([1, a:line_count])])
    endif
    call win_execute(l:win, 'call cursor(' . l:target . ', 1)')
  endfor
endfunction

function! s:walk(node, depth, acc) abort
  let [l:text, l:spans] = s:line(a:node, a:depth, a:acc['root_dir'])
  call add(a:acc['lines'], l:text)
  let l:lnum = len(a:acc['lines'])
  let a:acc['index'][l:lnum] = a:node
  let a:acc['spans'][l:lnum] = l:spans

  if !a:node['expanded']
    return
  endif
  for l:child in a:node['children']
    call s:walk(l:child, a:depth + 1, a:acc)
  endfor
endfunction

function! s:line(node, depth, root_dir) abort
  let l:pieces = [['', repeat('  ', a:depth)]]
  call add(l:pieces, ['calltree_marker', s:marker(a:node) . ' '])

  if a:node['group']
    call add(l:pieces, [a:node['dir'] ==# 'in' ? 'calltree_dir_in' : 'calltree_dir_out',
          \ (a:node['dir'] ==# 'in' ? '▲ ' : '▼ ') . a:node['name']])
    if a:node['loaded']
      call add(l:pieces, ['calltree_count', ' (' . len(a:node['children']) . ')'])
    endif
  elseif get(a:node, 'message', 0)
    call add(l:pieces, ['calltree_err', a:node['name']])
  else
    call add(l:pieces, [s:name_group(a:node), a:node['name']])
    if len(a:node['sites']) > 1
      call add(l:pieces, ['calltree_count', ' ×' . len(a:node['sites'])])
    endif
    if a:node['truncated']
      call add(l:pieces, ['calltree_count', ' …+' . a:node['hidden']])
    endif
    call add(l:pieces, ['', '  '])
    call add(l:pieces, ['calltree_loc', s:location(a:node, a:root_dir)])
    call add(l:pieces, ['calltree_lnum', ':' . (a:node['sel']['start']['line'] + 1)])
  endif

  if !empty(a:node['error']) && !get(a:node, 'message', 0)
    call add(l:pieces, ['calltree_err', '  ' . a:node['error']])
  endif

  return s:compose(l:pieces)
endfunction

" One colour per role: root, upstream, downstream, and the transient states
" (loading, cycle) that should stand out from the rest of the tree.  Standard
" library and third-party code win over the direction colours: in a deep tree
" you mostly want to see where your own code is.
function! s:name_group(node) abort
  if a:node['loading']
    return 'calltree_loading'
  endif
  if a:node['cycle']
    return 'calltree_cycle'
  endif
  if a:node['dir'] ==# 'root'
    return 'calltree_root'
  endif

  let l:kind = calltree#classify#kind(a:node['uri'])
  if l:kind ==# 'stdlib'
    return 'calltree_stdlib'
  elseif l:kind ==# 'dependency' || l:kind ==# 'vendor'
    return 'calltree_external'
  elseif a:node['dir'] ==# 'in'
    return 'calltree_caller'
  endif
  return 'calltree_callee'
endfunction

function! s:marker(node) abort
  if a:node['loading']
    return '…'
  endif
  if !empty(a:node['error'])
    return '!'
  endif
  if a:node['cycle']
    return '↻'
  endif
  if a:node['dir'] ==# 'root'
    return '●'
  endif
  if a:node['loaded'] && empty(a:node['children'])
    return '·'
  endif
  return a:node['expanded'] ? '▾' : '▸'
endfunction

function! s:location(node, root_dir) abort
  if empty(a:node['uri'])
    return ''
  endif
  let l:path = lsp#utils#uri_to_path(a:node['uri'])
  let l:shown = s:relative_to_root(l:path, a:root_dir)
  if empty(l:shown)
    let l:shown = fnamemodify(l:path, ':~:.')
  endif
  return l:shown
endfunction

" The workspace root from vim-lsp and the item URIs from gopls can disagree
" about symlinks (/tmp vs /private/tmp on macOS, /var vs /private/var), so
" compare canonical paths instead of raw strings.
function! s:relative_to_root(path, root_dir) abort
  let l:root = substitute(a:root_dir, '/\+$', '', '')
  if empty(l:root)
    return ''
  endif
  let l:root = resolve(l:root) . '/'
  let l:path = resolve(a:path)
  if stridx(l:path, l:root) == 0
    return strpart(l:path, strlen(l:root))
  endif
  return ''
endfunction

" Turn [highlight-group, text] pairs into a line plus byte-accurate spans.
function! s:compose(pieces) abort
  let l:text = ''
  let l:spans = []
  for [l:group, l:str] in a:pieces
    if !empty(l:group) && !empty(l:str)
      call add(l:spans, [l:group, strlen(l:text) + 1, strlen(l:str)])
    endif
    let l:text .= l:str
  endfor
  return [l:text, l:spans]
endfunction
