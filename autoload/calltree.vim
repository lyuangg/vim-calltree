" vim-calltree: entry point and tree model.
"
" The tree lives in b:calltree of the tree buffer as plain nested dicts.  Nodes
" are shared by reference, so a provider callback can mutate a node in place
" and ask the view layer for a redraw.  Every redraw rebuilds the whole buffer:
" with a few hundred nodes that is cheaper than tracking folds and keeps the
" line -> node index trivially correct.

let s:generation = 0

function! s:err(msg) abort
  echohl ErrorMsg
  echomsg 'CallTree: ' . a:msg
  echohl None
endfunction

function! calltree#cfg(name, default) abort
  return get(g:, 'calltree_' . a:name, a:default)
endfunction

" --- nodes ----------------------------------------------------------------

" Identity of a symbol across servers and directions.  Two CallHierarchyItems
" for the same function always share uri + selectionRange.start.
function! calltree#item_key(item) abort
  let l:start = a:item['selectionRange']['start']
  return a:item['uri'] . '#' . l:start['line'] . ':' . l:start['character']
endfunction

" The raw item is kept verbatim: servers resolve it again on every
" incoming/outgoing request, and the opaque `data` field must survive the
" round trip.
function! calltree#new_node(item, dir) abort
  return {
        \ 'key': calltree#item_key(a:item),
        \ 'uri': a:item['uri'],
        \ 'name': a:item['name'],
        \ 'detail': get(a:item, 'detail', ''),
        \ 'item': a:item,
        \ 'sel': a:item['selectionRange'],
        \ 'dir': a:dir,
        \ 'children': [],
        \ 'sites': [],
        \ 'parent': {},
        \ 'loaded': 0,
        \ 'loading': 0,
        \ 'expanded': 0,
        \ 'cycle': 0,
        \ 'truncated': 0,
        \ 'hidden': 0,
        \ 'site_idx': -1,
        \ 'error': '',
        \ 'group': 0,
        \ }
endfunction

function! s:group_node(root, dir) abort
  let l:node = calltree#new_node(a:root['item'], a:dir)
  let l:node['name'] = a:dir ==# 'in' ? 'Callers' : 'Callees'
  let l:node['group'] = 1
  let l:node['parent'] = a:root
  return l:node
endfunction

" True when `key` already appears on the ancestor chain of `node`.  Call graphs
" contain cycles; refusing to expand them is what keeps the tree finite.
function! calltree#in_ancestors(node, key) abort
  let l:cur = a:node
  while !empty(l:cur)
    if get(l:cur, 'key', '') ==# a:key
      return 1
    endif
    let l:cur = get(l:cur, 'parent', {})
  endwhile
  return 0
endfunction

" --- commands -------------------------------------------------------------

function! calltree#open(mode) abort
  if &buftype !=# ''
    return s:err('open a source file first')
  endif

  let l:server = calltree#provider#vimlsp#FindServer(bufnr('%'))
  if empty(l:server)
    return s:err('no vim-lsp server with callHierarchyProvider for this buffer')
  endif

  let l:srcbufnr = bufnr('%')
  let l:srcpath = expand('%:p')
  let l:cursor = [line('.'), col('.')]
  let l:pos = lsp#utils#position#vim_to_lsp(l:srcbufnr, l:cursor)
  " Paths in the tree are shown relative to the workspace root; for gopls that
  " is the module root, which is what you want when reading a big repo.
  let l:root_uri = lsp#get_server_root_uri(l:server)
  let l:root_dir = empty(l:root_uri) ? getcwd() : lsp#utils#uri_to_path(l:root_uri)
  let l:srcwin = exists('w:calltree')
        \ ? get(get(b:, 'calltree', {}), 'srcwin', win_getid())
        \ : win_getid()

  let s:generation += 1
  let l:ctx = {
        \ 'gen': s:generation,
        \ 'server': l:server,
        \ 'srcbufnr': l:srcbufnr,
        \ 'srcwin': l:srcwin,
        \ 'root_dir': l:root_dir,
        \ 'pos': l:pos,
        \ 'mode': a:mode,
        \ 'root': {},
        \ 'index': {},
        \ 'bufnr': -1,
        \ }

  let l:layout = calltree#view#OpenWindow({
        \ 'path': l:srcpath, 'lnum': l:cursor[0], 'col': l:cursor[1]})
  let l:ctx['bufnr'] = winbufnr(l:layout['tree'])
  let l:ctx['own_tab'] = l:layout['own_tab']
  " <CR> / e open files back in the window :CallTree was invoked from.
  let l:ctx['openwin'] = l:srcwin
  if l:layout['viewer']
    " A dedicated tab brings its own viewer; the window :CallTree was invoked
    " from belongs to the editing tab and must not be touched.
    let l:ctx['srcwin'] = l:layout['viewer']
  endif
  call setbufvar(l:ctx['bufnr'], 'calltree', l:ctx)
  call setbufvar(l:ctx['bufnr'], 'calltree_gen', l:ctx['gen'])

  call s:load(l:ctx)
endfunction

function! calltree#refresh() abort
  let l:ctx = get(b:, 'calltree', {})
  if empty(l:ctx)
    " :CallTreeRefresh is usually typed from the source window; re-enter the
    " tree window so `b:calltree` is the real dict (getbufvar() returns a copy).
    let l:win = calltree#view#FindWindow()
    if !l:win
      return s:err('no call tree to refresh')
    endif
    return win_execute(l:win, 'call calltree#refresh()')
  endif
  if !bufloaded(l:ctx['srcbufnr'])
    return s:err('source buffer is gone')
  endif
  let s:generation += 1
  let l:ctx['gen'] = s:generation
  call setbufvar(l:ctx['bufnr'], 'calltree_gen', l:ctx['gen'])
  call s:load(l:ctx)
endfunction

function! s:load(ctx) abort
  let l:ctx = a:ctx
  let l:ctx['root'] = {}
  let l:ctx['index'] = {}
  call calltree#view#Render(l:ctx['bufnr'])
  call calltree#provider#vimlsp#Prepare(l:ctx['server'], l:ctx['srcbufnr'], l:ctx['pos'],
        \ function('s:on_prepared', [l:ctx]))
endfunction

function! s:on_prepared(ctx, result, error) abort
  let l:ctx = a:ctx
  if getbufvar(l:ctx['bufnr'], 'calltree_gen', -1) != l:ctx['gen']
    return
  endif

  " The real workspace root only exists after initialize, and this callback
  " runs after the first request completed, so pick it up here.  Without this
  " every path would be absolute whenever :CallTree was not run from the repo.
  let l:root_uri = lsp#get_server_root_uri(l:ctx['server'])
  if !empty(l:root_uri)
    let l:ctx['root_dir'] = lsp#utils#uri_to_path(l:root_uri)
  endif

  if !empty(a:error)
    let l:ctx['root'] = s:message_root('error: ' . a:error, 1)
    return calltree#view#Render(l:ctx['bufnr'])
  endif
  if empty(a:result)
    let l:ctx['root'] = s:message_root('no callable symbol under the cursor', 0)
    return calltree#view#Render(l:ctx['bufnr'])
  endif

  " prepareCallHierarchy may return several items (interface + implementation,
  " declaration + definition); the first is the most specific one.
  let l:root = calltree#new_node(a:result[0], 'root')
  let l:root['loaded'] = 1
  let l:root['expanded'] = 1
  if l:ctx['mode'] !=# 'out'
    call add(l:root['children'], s:group_node(l:root, 'in'))
  endif
  if l:ctx['mode'] !=# 'in'
    call add(l:root['children'], s:group_node(l:root, 'out'))
  endif

  let l:ctx['root'] = l:root
  call calltree#view#Render(l:ctx['bufnr'])

  " Show the root symbol in the viewer right away, before any cursor move.
  let l:wins = win_findbuf(l:ctx['bufnr'])
  if !empty(l:wins)
    call win_execute(l:wins[0], 'call calltree#action#preview()')
  endif

  let l:depth = calltree#cfg('auto_expand', 1)
  if l:depth > 0
    for l:group in copy(l:root['children'])
      call calltree#expand(l:group, l:ctx)
    endfor
    if l:depth > 1
      call calltree#action#auto_expand(l:ctx, l:depth - 1)
    endif
  endif
endfunction

function! s:message_root(text, is_error) abort
  return {
        \ 'key': ':message', 'uri': '', 'name': a:text, 'detail': '',
        \ 'item': {}, 'sel': {'start': {'line': 0, 'character': 0}},
        \ 'dir': 'root', 'children': [], 'sites': [], 'parent': {},
        \ 'loaded': 1, 'loading': 0, 'expanded': 1, 'cycle': 0,
        \ 'truncated': 0, 'hidden': 0, 'site_idx': -1,
        \ 'group': 0, 'message': 1,
        \ 'error': a:is_error ? a:text : '',
        \ }
endfunction

" --- expansion ------------------------------------------------------------

" Load one level of callers/callees for `node`, or toggle it when already
" loaded.  `ctx` is passed explicitly because provider callbacks may run while
" the tree buffer is not the current one.
function! calltree#expand(node, ctx) abort
  let l:ctx = a:ctx
  let l:node = a:node

  if l:node['dir'] ==# 'root'
    let l:node['expanded'] = !l:node['expanded']
    return calltree#view#Render(l:ctx['bufnr'])
  endif
  if l:node['cycle']
    return
  endif
  if !empty(l:node['error'])
    let l:node['error'] = ''
  endif
  if l:node['loaded']
    let l:node['expanded'] = !l:node['expanded']
    return calltree#view#Render(l:ctx['bufnr'])
  endif
  if l:node['loading']
    return
  endif

  let l:node['loading'] = 1
  call calltree#view#Render(l:ctx['bufnr'])

  " Funcref variables must start with a capital (E704), hence l:Cb.
  let l:Cb = function('s:on_calls', [l:ctx, l:node])
  if l:node['dir'] ==# 'in'
    call calltree#provider#vimlsp#Incoming(l:ctx['server'], l:ctx['srcbufnr'], l:node['item'], l:Cb)
  else
    call calltree#provider#vimlsp#Outgoing(l:ctx['server'], l:ctx['srcbufnr'], l:node['item'], l:Cb)
  endif
endfunction

function! s:on_calls(ctx, node, calls, error) abort
  let l:ctx = a:ctx
  if !bufloaded(l:ctx['bufnr'])
    return
  endif
  if getbufvar(l:ctx['bufnr'], 'calltree_gen', -1) != l:ctx['gen']
    return
  endif

  let l:node = a:node
  let l:node['loading'] = 0
  let l:node['loaded'] = 1

  if !empty(a:error)
    let l:node['error'] = a:error
    return calltree#view#Render(l:ctx['bufnr'])
  endif

  " Servers return call hierarchy entries in their own order (gopls: roughly
  " index order), which reads as noise.  Callees are ordered by where the call
  " appears in the function body; callers by file and definition position.
  let l:calls = copy(a:calls)
  if len(l:calls) > 1
    call sort(l:calls, function('s:compare_calls', [l:node['dir']]))
  endif

  " The same function is reported once per call site.  Merge those into a
  " single node and remember the call sites; that is what `×N` shows.
  let l:seen = {}
  let l:hidden = {}
  let l:max = calltree#cfg('max_children', 50)
  for l:call in l:calls
    let l:key = calltree#item_key(l:call['item'])
    if has_key(l:seen, l:key)
      call extend(l:seen[l:key]['sites'], l:call['ranges'])
      continue
    endif
    if len(l:node['children']) >= l:max
      " Keep counting distinct symbols we are not showing, so the truncated
      " marker can say how much is missing.
      let l:hidden[l:key] = 1
      continue
    endif
    let l:child = calltree#new_node(l:call['item'], l:node['dir'])
    let l:child['parent'] = l:node
    let l:child['sites'] = copy(l:call['ranges'])
    let l:child['cycle'] = calltree#in_ancestors(l:node, l:key)
    call add(l:node['children'], l:child)
    let l:seen[l:key] = l:child
  endfor

  " Merged call sites arrive interleaved; keep them in source order so that
  " ]c / [c walks the code forwards.
  for l:child in l:node['children']
    if len(l:child['sites']) > 1
      call sort(l:child['sites'], function('s:compare_ranges'))
    endif
  endfor

  let l:node['hidden'] = len(l:hidden)
  let l:node['truncated'] = l:node['hidden'] > 0
  let l:node['expanded'] = 1
  call calltree#view#Render(l:ctx['bufnr'])
endfunction


" --- ordering -------------------------------------------------------------

function! s:compare_positions(a, b) abort
  if a:a['line'] != a:b['line']
    return a:a['line'] < a:b['line'] ? -1 : 1
  endif
  if a:a['character'] != a:b['character']
    return a:a['character'] < a:b['character'] ? -1 : 1
  endif
  return 0
endfunction

function! s:compare_ranges(a, b) abort
  return s:compare_positions(a:a['start'], a:b['start'])
endfunction

function! s:first_call_pos(call) abort
  if empty(a:call['ranges'])
    " No call site reported: sort last rather than in front of everything.
    return {'line': 1073741824, 'character': 0}
  endif
  return a:call['ranges'][0]['start']
endfunction

function! s:compare_calls(dir, a, b) abort
  if a:dir ==# 'out'
    " Downstream: the order the callee is actually called in the body.
    return s:compare_positions(s:first_call_pos(a:a), s:first_call_pos(a:b))
  endif
  " Upstream: same file together, then the caller's own position in it.
  if a:a['item']['uri'] !=# a:b['item']['uri']
    return a:a['item']['uri'] <# a:b['item']['uri'] ? -1 : 1
  endif
  return s:compare_positions(a:a['item']['selectionRange']['start'],
        \ a:b['item']['selectionRange']['start'])
endfunction
