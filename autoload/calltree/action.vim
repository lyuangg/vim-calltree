" autoload/calltree/action.vim
"
" Everything here is triggered from the tree buffer, so reading b:calltree is
" safe.  Callbacks that must work from any window live in autoload/calltree.vim
" and take an explicit ctx.

function! s:err(msg) abort
  echohl ErrorMsg
  echomsg 'CallTree: ' . a:msg
  echohl None
endfunction

function! calltree#action#node() abort
  return get(get(b:, 'calltree_index', {}), line('.'), {})
endfunction

function! calltree#action#toggle() abort
  let l:node = calltree#action#node()
  if empty(l:node)
    return
  endif
  call calltree#expand(l:node, b:calltree)
endfunction

" --- expand one level -------------------------------------------------------
"
" `o` deepens a single node.  This deepens the whole visible tree by exactly
" one level, like zr does for folds: already-loaded children are revealed
" immediately, not-yet-loaded ones fire one request each.  Newly arrived
" children are *not* expanded in the same pass, so repeated calls walk down
" level by level.
function! calltree#action#expand_level() abort
  if !empty(get(b:, 'calltree', {}))
    call s:expand_level(b:calltree)
  endif
endfunction

function! s:expand_level(ctx) abort
  let l:limit = calltree#cfg('expand_limit', 30)
  let l:fired = 0
  for l:node in s:visible_nodes()
    if l:node['dir'] ==# 'root' || l:node['cycle'] || get(l:node, 'message', 0)
      continue
    endif
    if l:node['loaded']
      if !l:node['expanded'] && !empty(l:node['children'])
        let l:node['expanded'] = 1
      endif
      continue
    endif
    if l:node['loading']
      continue
    endif
    if l:fired >= l:limit
      break
    endif
    call calltree#expand(l:node, a:ctx)
    let l:fired += 1
  endfor
  call calltree#view#Render(a:ctx['bufnr'])
endfunction

function! s:visible_nodes() abort
  let l:index = get(b:, 'calltree_index', {})
  let l:nodes = []
  for l:lnum in sort(map(keys(l:index), 'str2nr(v:val)'), 'n')
    call add(l:nodes, l:index[l:lnum])
  endfor
  return l:nodes
endfunction

" Open with g:calltree_auto_expand layers.  Responses arrive asynchronously,
" so poll until nothing is in flight, then take the next step.
" Timers pass the timer id as an extra argument, hence the trailing varargs.
function! calltree#action#auto_expand(ctx, remaining, ...) abort
  let l:ctx = a:ctx
  if a:remaining <= 0 || !bufloaded(l:ctx['bufnr'])
    return
  endif
  if getbufvar(l:ctx['bufnr'], 'calltree_gen', -1) != l:ctx['gen']
    return
  endif
  if s:any_loading(l:ctx)
    call timer_start(40, function('calltree#action#auto_expand', [l:ctx, a:remaining]))
    return
  endif
  let l:wins = win_findbuf(l:ctx['bufnr'])
  if empty(l:wins)
    return
  endif
  call win_execute(l:wins[0], 'call calltree#action#expand_level()')
  call timer_start(40, function('calltree#action#auto_expand', [l:ctx, a:remaining - 1]))
endfunction

function! s:any_loading(ctx) abort
  let l:bufnr = a:ctx['bufnr']
  let l:index = getbufvar(l:bufnr, 'calltree_index', {})
  for l:node in values(l:index)
    if l:node['loading']
      return 1
    endif
  endfor
  return 0
endfunction

function! calltree#action#parent() abort
  let l:node = calltree#action#node()
  if empty(l:node) || empty(l:node['parent'])
    return
  endif
  for [l:lnum, l:candidate] in items(get(b:, 'calltree_index', {}))
    if l:candidate is l:node['parent']
      call cursor(str2nr(l:lnum), 1)
      return
    endif
  endfor
endfunction

" gopls reports the same source path in two spellings on macOS (/tmp vs
" /private/tmp, symlinked GOPATHs), so compare resolved absolute paths.
function! s:bufnr_for(path) abort
  let l:target = resolve(fnamemodify(a:path, ':p'))
  for l:info in getbufinfo({'bufloaded': 1})
    if resolve(fnamemodify(l:info['name'], ':p')) ==# l:target
      return l:info['bufnr']
    endif
  endfor
  return -1
endfunction

" fromRanges are positions inside the *caller*: the node itself for incoming
" calls, but the parent node for outgoing ones.  So a call site carries its
" own uri, which is not always the node's uri.
function! s:site_uri(node) abort
  if a:node['dir'] ==# 'out' && !empty(a:node['parent'])
    return a:node['parent']['uri']
  endif
  return a:node['uri']
endfunction

function! s:site_index(node) abort
  let l:count = len(a:node['sites'])
  if l:count == 0
    return 0
  endif
  return max([0, get(a:node, 'site_idx', 0)]) % l:count
endfunction

" Show uri/range in the current window.
function! s:reveal(uri, range) abort
  let l:path = lsp#utils#uri_to_path(a:uri)
  let l:bufnr = s:bufnr_for(l:path)
  if l:bufnr == -1
    execute 'silent keepalt hide edit ' . fnameescape(l:path)
  elseif l:bufnr != bufnr('%')
    execute 'silent keepalt hide buffer ' . l:bufnr
  endif

  let [l:lnum, l:col] = lsp#utils#position#lsp_to_vim(bufnr('%'), a:range['start'])
  call cursor(l:lnum, l:col)
  normal! zvzz
endfunction

" Router: ghost viewers (a scratch buffer in the tree tab) or, when the tree
" shares the editing tab, a real window.
function! s:show(uri, range) abort
  let l:ctx = get(b:, 'calltree', {})
  if get(l:ctx, 'own_tab', 0) && get(l:ctx, 'srcwin', 0)
    let l:path = lsp#utils#uri_to_path(a:uri)
    let l:bufnr = s:bufnr_for(l:path)
    let l:expr = l:bufnr == -1 ? l:path : l:bufnr
    let [l:lnum, l:col] = lsp#utils#position#lsp_to_vim(l:expr, a:range['start'])
    try
      call win_execute(l:ctx['srcwin'], printf('call calltree#action#_preview(%s, %d, %d)',
            \ string(l:path), l:lnum, l:col))
    catch
    endtry
    return
  endif
  call s:goto_real(a:uri, a:range)
endfunction

" Reveal in the viewer window and come back, so browsing is not interrupted.
function! s:goto_real(uri, range) abort
  let l:ctx = get(b:, 'calltree', {})
  let l:treewin = win_getid()
  let l:srcwin = get(l:ctx, 'srcwin', 0)
  if l:srcwin == 0 || l:srcwin == l:treewin || !win_gotoid(l:srcwin)
    if winnr('$') == 1
      return s:err('no source window to jump to')
    endif
    wincmd p
  endif

  call s:reveal(a:uri, a:range)

  " Jumping is for looking, not for leaving the tree.
  call win_gotoid(l:treewin)
endfunction

" call_site: jump to the range of the call inside the caller (fromRanges)
" instead of the callee's definition.  Seeing *where* it is used is usually
" what you want when walking the tree.
function! calltree#action#jump(call_site) abort
  let l:node = calltree#action#node()
  if empty(l:node) || get(l:node, 'message', 0) || empty(l:node['uri'])
    return
  endif
  if a:call_site && !empty(l:node['sites'])
    let l:node['site_idx'] = 0
    return s:show(s:site_uri(l:node), l:node['sites'][0])
  endif
  call s:show(l:node['uri'], l:node['sel'])
endfunction

" One function can be called from several places; ]c / [c walk them.
 " --- open ------------------------------------------------------------------
"
" e: open the node in the window :CallTree was invoked from and stay
" there.  This is the "take me to the code" action, as opposed to preview and
" g<CR>, which never leave the tree tab.

function! calltree#action#open() abort
  let l:node = calltree#action#node()
  if empty(l:node) || get(l:node, 'message', 0) || empty(l:node['uri'])
    return
  endif

  let l:ctx = get(b:, 'calltree', {})
  let l:openwin = get(l:ctx, 'openwin', 0)
  if empty(l:openwin) || empty(win_id2tabwin(l:openwin)) || !win_gotoid(l:openwin)
    " The original window is gone (closed, or another tab was wiped): open a
    " split next to the tree instead of failing.
    vertical rightbelow split
  endif

  call s:reveal(l:node['uri'], l:node['sel'])
endfunction

" --- preview ---------------------------------------------------------------
"
" While the cursor moves through the tree (j/k included) the source window
" follows along, so you can read code without pressing `e`.  Focus never
" leaves the tree; "preview" is a read, not a jump.

function! calltree#action#preview_schedule() abort
  if !calltree#cfg('preview', 1)
    return
  endif
  let l:node = calltree#action#node()
  if empty(l:node) || l:node['group'] || get(l:node, 'message', 0)
    return
  endif
  let l:key = l:node['uri'] . '#' . l:node['sel']['start']['line']
  if empty(l:node['uri'])
    return
  endif
  let l:bufnr = bufnr('%')
  if getbufvar(l:bufnr, 'calltree_preview_key', '') ==# l:key
    return
  endif
  call setbufvar(l:bufnr, 'calltree_preview_key', l:key)

  let l:timer = getbufvar(l:bufnr, 'calltree_preview_timer', -1)
  if l:timer != -1
    call timer_stop(l:timer)
  endif
  call setbufvar(l:bufnr, 'calltree_preview_timer',
        \ timer_start(calltree#cfg('preview_delay', 60),
        \             function('s:preview_fire', [l:bufnr])))
endfunction

function! s:preview_fire(bufnr, timer) abort
  " The user may have left the tree in the meantime.
  if bufnr('%') != a:bufnr
    return
  endif
  call calltree#action#preview()
endfunction

function! calltree#action#preview() abort
  let l:node = calltree#action#node()
  if empty(l:node) || l:node['group'] || get(l:node, 'message', 0) || empty(l:node['uri'])
    return
  endif
  if empty(get(get(b:, 'calltree', {}), 'srcwin', 0))
    return
  endif

  " Preview the call site, not the definition: while walking the tree you want
  " to see the callee being called inside the current function's body (or the
  " caller's body for upstream nodes).  g:calltree_preview_site = 0 reverts.
  let l:uri = l:node['uri']
  let l:range = l:node['sel']
  if calltree#cfg('preview_site', 1) && !empty(l:node['sites'])
    let l:uri = s:site_uri(l:node)
    let l:range = l:node['sites'][s:site_index(l:node)]
  endif

  call s:show(l:uri, l:range)
endfunction

" Renders the target inside the viewer window.  The viewer is a scratch buffer,
" not the file itself: browsing a tree must not open files, pollute the buffer
" list, or send didOpen for every symbol you pass over.  Content is copied from
" an already loaded buffer when there is one (so unsaved edits show up) and
" otherwise read from disk, cached by a signature.
function! calltree#action#_preview(path, lnum, col) abort
  if !exists('b:calltree_preview')
    setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
    setlocal nonumber norelativenumber nolist nowrap nospell
    let b:calltree_preview = 1
    let b:calltree_preview_sig = ''
    " The viewer is read-only, so `q` would otherwise start recording a macro.
    " Leave the tree layout instead, like `q` does from the tree window.
    nnoremap <buffer> <silent> <Plug>(calltree-close) :<C-u>call calltree#action#close()<CR>
    if get(g:, 'calltree_default_maps', 1)
      nmap <buffer> q <Plug>(calltree-close)
    endif
  endif

  let l:path = fnamemodify(a:path, ':p')
  let l:sig = s:preview_signature(l:path)
  if get(b:, 'calltree_preview_sig', '') !=# l:sig
    let l:lines = s:preview_lines(l:path)
    setlocal modifiable noreadonly
    silent %delete _
    call setline(1, empty(l:lines) ? [''] : l:lines)
    setlocal nomodifiable readonly
    execute 'silent! file ' . fnameescape('calltree://' . l:path)
    let &l:filetype = s:preview_filetype(l:path)
    let b:calltree_preview_sig = l:sig
  endif

  call cursor(max([1, min([a:lnum, line('$')])]), a:col)
  normal! zz
endfunction

function! s:preview_signature(path) abort
  let l:bufnr = s:bufnr_for(a:path)
  if l:bufnr != -1
    return a:path . '#buf:' . getbufvar(l:bufnr, 'changedtick')
  endif
  return a:path . '#file:' . getftime(a:path) . ':' . getfsize(a:path)
endfunction

function! s:preview_lines(path) abort
  let l:bufnr = s:bufnr_for(a:path)
  if l:bufnr != -1
    return getbufline(l:bufnr, 1, '$')
  endif
  if !filereadable(a:path)
    return []
  endif
  if getfsize(a:path) > calltree#cfg('preview_max_bytes', 2097152)
    return ['(file too large to preview: ' . fnamemodify(a:path, ':t') . ')']
  endif
  try
    return readfile(a:path)
  catch
    return []
  endtry
endfunction

let s:filetypes = {
      \ 'go': 'go', 'php': 'php', 'c': 'c', 'h': 'c', 'cc': 'cpp', 'cpp': 'cpp',
      \ 'hpp': 'cpp', 'rs': 'rust', 'ts': 'typescript', 'tsx': 'typescriptreact',
      \ 'js': 'javascript', 'jsx': 'javascriptreact', 'py': 'python',
      \ 'java': 'java', 'kt': 'kotlin', 'swift': 'swift', 'rb': 'ruby',
      \ 'vim': 'vim', 'sh': 'sh', 'bash': 'sh', 'zsh': 'zsh',
      \ 'md': 'markdown', 'json': 'json', 'yaml': 'yaml', 'yml': 'yaml',
      \ 'toml': 'toml', 'lua': 'lua', 'sql': 'sql', 'html': 'html',
      \ 'css': 'css', 'scss': 'scss', 'vue': 'vue', 'proto': 'proto',
      \ }

function! s:preview_filetype(path) abort
  return get(s:filetypes, tolower(fnamemodify(a:path, ':e')), '')
endfunction

" --- floating definition ---------------------------------------------------
"
" K peeks at the definition in a popup window: no window is entered, the viewer
" keeps whatever it was showing and nothing is opened.  Content follows the
" preview buffer's rules (a loaded buffer first, so unsaved edits show up).

let s:floats = {}

function! calltree#action#float() abort
  let l:node = calltree#action#node()
  if empty(l:node) || l:node['group'] || get(l:node, 'message', 0) || empty(l:node['uri'])
    return
  endif
  if !has('popupwin')
    " No floating windows in this build: the viewer is the next best thing.
    return calltree#action#preview()
  endif

  let l:path = lsp#utils#uri_to_path(l:node['uri'])
  let l:lines = s:preview_lines(l:path)
  if empty(l:lines)
    return s:err('cannot read ' . fnamemodify(l:path, ':t'))
  endif

  " CallHierarchyItem.range covers the whole declaration (doc comment,
  " signature, body).  Servers that only report the name get a few lines of
  " context instead, which beats a one-line popup.
  let l:first = l:node['sel']['start']['line'] + 1
  let l:last = l:first
  let l:range = get(l:node['item'], 'range', {})
  if !empty(l:range)
    " The doc comment above the signature belongs to the definition.
    let l:first = min([l:first, l:range['start']['line'] + 1])
    let l:last = l:range['end']['line'] + 1
  endif
  if l:last <= l:first
    let l:first = max([1, l:first - 2])
    let l:last = l:first + 9
  endif
  let l:first = min([l:first, len(l:lines)])
  let l:last = min([l:last, l:first + 499, len(l:lines)])

  let l:body = l:lines[l:first - 1 : l:last - 1]
  " A range ending on the blank lines after a closing brace wastes popup rows.
  while len(l:body) > 1 && l:body[-1] =~# '^\s*$'
    call remove(l:body, -1)
  endwhile

  call s:float_open(l:node, l:path, l:first, l:body)
endfunction

function! s:float_open(node, path, first, body) abort
  let l:bufnr = bufadd('')
  call bufload(l:bufnr)
  call setbufvar(l:bufnr, '&buftype', 'nofile')
  call setbufvar(l:bufnr, '&bufhidden', 'wipe')
  call setbufvar(l:bufnr, '&swapfile', 0)
  call setbufvar(l:bufnr, '&buflisted', 0)
  call setbufline(l:bufnr, 1, a:body)
  call setbufvar(l:bufnr, '&modified', 0)
  let l:ft = s:preview_filetype(a:path)
  if !empty(l:ft)
    call setbufvar(l:bufnr, '&filetype', l:ft)
  endif

  " Fit the content, then cap: taller bodies page with <C-d> / <C-u>.
  let l:natural = 0
  for l:line in a:body
    let l:natural = max([l:natural, strdisplaywidth(l:line)])
  endfor
  let l:width = max([20, min([l:natural + 2, calltree#cfg('float_width', 100),
        \ &columns - 2])])
  let l:height = min([len(a:body), calltree#cfg('float_height', 20)])

  let l:id = popup_atcursor(l:bufnr, {
        \ 'minwidth': l:width, 'maxwidth': l:width,
        \ 'minheight': l:height, 'maxheight': l:height,
        \ 'border': [], 'padding': [0, 1, 0, 1],
        \ 'wrap': 0, 'zindex': 300, 'scrollbar': 1, 'mapping': 0,
        \ 'moved': 'any', 'close': 'click',
        \ 'title': ' ' . a:node['name'] . '  '
        \          . fnamemodify(a:path, ':t') . ':' . a:first . ' ',
        \ 'filter': function('s:float_filter'),
        \ 'callback': function('s:float_closed'),
        \ })
  let s:floats[l:id] = {'total': len(a:body)}
endfunction

" Cursor keys keep working on the tree: the popup closes itself and the key
" still reaches the tree, so the cursor (and the preview) moves on as usual.
" "moved": "any" is the safety net for any other cursor movement.  Page keys
" page through a definition that does not fit, and any other key is swallowed
" after closing.  "mapping" is off on the popup so the tree's own mappings
" cannot fire underneath it.
function! s:float_filter(id, key) abort
  if a:key ==# 'j' || a:key ==# 'k' || a:key ==# "\<Down>" || a:key ==# "\<Up>"
        \ || a:key ==# "\<C-n>" || a:key ==# "\<C-p>"
    call popup_close(a:id)
    return 0
  endif

  let l:step = 0
  if a:key ==# "\<C-d>" || a:key ==# "\<PageDown>"
    let l:step = 10
  elseif a:key ==# "\<C-u>" || a:key ==# "\<PageUp>"
    let l:step = -10
  endif

  let l:pos = popup_getpos(a:id)
  let l:total = get(get(s:floats, a:id, {}), 'total', 0)
  if l:step == 0 || empty(l:pos) || l:total == 0
    call popup_close(a:id)
    return 1
  endif

  let l:first = l:pos['firstline'] + l:step
  call popup_setoptions(a:id, {
        \ 'firstline': max([1, min([l:first, l:total - l:pos['core_height'] + 1])]),
        \ })
  return 1
endfunction

function! s:float_closed(id, result) abort
  if has_key(s:floats, a:id)
    call remove(s:floats, a:id)
  endif
endfunction

function! calltree#action#cycle_site(step) abort
  let l:node = calltree#action#node()
  if empty(l:node) || get(l:node, 'message', 0) || empty(l:node['sites'])
    return
  endif
  let l:count = len(l:node['sites'])
  let l:idx = (get(l:node, 'site_idx', -1) + a:step + l:count) % l:count
  let l:node['site_idx'] = l:idx
  call s:show(s:site_uri(l:node), l:node['sites'][l:idx])
  echomsg 'CallTree: call site ' . (l:idx + 1) . '/' . l:count
endfunction

" Export what is currently visible as a flat list; handy together with fzf
" (`:CallTreeQF` then `:copen`, :cnext), and a good way to get every
" ancestor of a function onto one screen.
function! calltree#action#quickfix() abort
  let l:bufnr = bufnr('%')
  let l:index = get(b:, 'calltree_index', {})
  if empty(l:index)
    let l:win = calltree#view#FindWindow()
    if !l:win
      return s:err('no call tree to export')
    endif
    let l:bufnr = winbufnr(l:win)
    let l:index = getbufvar(l:bufnr, 'calltree_index', {})
  endif

  let l:items = []
  for l:lnum in sort(map(keys(l:index), 'str2nr(v:val)'), 'n')
    let l:node = get(l:index, l:lnum, {})
    if empty(l:node) || l:node['group'] || get(l:node, 'message', 0) || empty(l:node['uri'])
      continue
    endif
    let l:path = lsp#utils#uri_to_path(l:node['uri'])
    let l:bufnr = s:bufnr_for(l:path)
    let [l:line, l:col] = lsp#utils#position#lsp_to_vim(
          \ l:bufnr == -1 ? l:path : l:bufnr, l:node['sel']['start'])
    call add(l:items, {
          \ 'filename': l:path,
          \ 'lnum': l:line,
          \ 'col': l:col,
          \ 'text': l:node['name'] . ' [' . s:role(l:node) . ']',
          \ })
  endfor
  if empty(l:items)
    return s:err('nothing to export')
  endif
  call setqflist([], ' ', {'title': 'CallTree', 'items': l:items})
  copen
endfunction

function! s:role(node) abort
  if a:node['dir'] ==# 'in'
    return 'caller'
  elseif a:node['dir'] ==# 'out'
    return 'callee'
  endif
  return 'root'
endfunction

function! calltree#action#close() abort
  let l:win = calltree#view#FindWindow()
  if !l:win
    return
  endif
  let l:ctx = getbufvar(winbufnr(l:win), 'calltree', {})
  let l:own_tab = get(l:ctx, 'own_tab', 0)
  let l:tree_tab = win_id2tabwin(l:win)[0]
  let l:srcwin = get(l:ctx, 'srcwin', 0)
  call win_gotoid(l:win)

  " A dedicated tab exists only for browsing the tree: q leaves the whole tab.
  if l:own_tab && tabpagenr() == l:tree_tab
    try
      tabclose
      return
    catch
      " Unsaved changes elsewhere in the tab: fall back to closing one window.
    endtry
  endif

  if winnr('$') > 1
    close
  else
    " Closing the last window would quit Vim (E444); leave an empty buffer.
    enew
    return
  endif
  if l:srcwin && l:srcwin != l:win && win_id2win(l:srcwin) > 0
    call win_gotoid(l:srcwin)
  endif
endfunction
