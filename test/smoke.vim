" Headless smoke test for the parts that do not need a language server:
" node identity, cycle detection, renderer, line -> node index.
"
"   vim -Nu NONE -es -S test/smoke.vim
"
" Results go to test/smoke.log; exit code 1 on failure.

set nocompatible
let s:here = expand('<sfile>:p:h')
execute 'set rtp+=' . fnameescape(fnamemodify(s:here, ':h'))
execute 'set rtp+=' . fnameescape(expand('~/.vim/plugged/vim-lsp'))

let s:log = []
let s:fail = 0

function! s:check(name, cond) abort
  if !a:cond
    let s:fail += 1
  endif
  call add(s:log, (a:cond ? 'ok   ' : 'FAIL ') . a:name)
endfunction

let s:item = {
      \ 'name': 'handle',
      \ 'kind': 6,
      \ 'detail': 'App\Svc',
      \ 'uri': 'file:///tmp/proj/src/Svc.php',
      \ 'range': {'start': {'line': 10, 'character': 4}, 'end': {'line': 20, 'character': 5}},
      \ 'selectionRange': {'start': {'line': 10, 'character': 19}, 'end': {'line': 10, 'character': 25}},
      \ 'data': {'opaque': 1},
      \ }

call s:check('item_key uses selectionRange',
      \ calltree#item_key(s:item) ==# 'file:///tmp/proj/src/Svc.php#10:19')

let s:root = calltree#new_node(s:item, 'root')
call s:check('item is kept verbatim for server resolution',
      \ get(s:root['item'], 'data', {}) == {'opaque': 1})
call s:check('new_node defaults', s:root['loaded'] == 0 && s:root['expanded'] == 0)

let s:group = calltree#new_node(s:item, 'in')
let s:group['name'] = 'Callers'
let s:group['group'] = 1
let s:group['parent'] = s:root

let s:child_item = deepcopy(s:item)
let s:child_item['name'] = 'callerA'
let s:child_item['uri'] = 'file:///tmp/proj/src/A.php'
let s:child_item['selectionRange']['start'] = {'line': 3, 'character': 2}
let s:child = calltree#new_node(s:child_item, 'in')
let s:child['parent'] = s:group
let s:child['sites'] = [
      \ {'start': {'line': 30, 'character': 8}, 'end': {'line': 30, 'character': 12}},
      \ {'start': {'line': 40, 'character': 8}, 'end': {'line': 40, 'character': 12}},
      \ ]

let s:cyc = calltree#new_node(s:item, 'in')
let s:cyc['parent'] = s:group
let s:cyc['cycle'] = calltree#in_ancestors(s:group, calltree#item_key(s:item))

call s:check('cycle detected against ancestors',
      \ calltree#in_ancestors(s:group, calltree#item_key(s:item)) == 1)
call s:check('unrelated key is not a cycle',
      \ calltree#in_ancestors(s:group, 'file:///nope#0:0') == 0)

let s:root['loaded'] = 1
let s:root['expanded'] = 1
let s:root['children'] = [s:group]
let s:group['loaded'] = 1
let s:group['expanded'] = 1
let s:group['children'] = [s:child, s:cyc]

enew
setlocal buftype=nofile
let s:ctx = {
      \ 'gen': 1, 'bufnr': bufnr('%'), 'root': s:root, 'index': {},
      \ 'server': 'test', 'srcbufnr': bufnr('%'), 'srcwin': win_getid(),
      \ 'pos': {}, 'mode': 'both',
      \ }
let b:calltree = s:ctx
call setbufvar(bufnr('%'), 'calltree_gen', 1)
call calltree#view#Render(bufnr('%'))

call s:check('expanded tree renders 4 lines', line('$') == 4)
call s:check('root line', getline(1) =~# '● handle')
call s:check('root location', getline(1) =~# 'Svc.php:11')
call s:check('group line with count', getline(2) =~# '▲ Callers (2)')
call s:check('child line with call sites', getline(3) =~# 'callerA ×2')
call s:check('child location', getline(3) =~# 'A.php:4')
call s:check('cycle marker', getline(4) =~# '↻')
call s:check('index maps line to the same node dict', b:calltree_index[1] is s:root)
call s:check('index maps nested node', b:calltree_index[3] is s:child)

" quickfix export: only real nodes, groups and messages excluded
call calltree#action#quickfix()
call s:check('quickfix exports visible nodes', len(getqflist()) == 3)
call s:check('quickfix keeps tree order', getqflist()[0]['lnum'] == 11)
cclose

let s:root_types = map(prop_list(1), 'v:val["type"]')
call s:check('root painted with the root group', index(s:root_types, 'calltree_root') >= 0)
let s:header_types = map(prop_list(2), 'v:val["type"]')
call s:check('callers header uses the caller group', index(s:header_types, 'calltree_dir_in') >= 0)
let s:child_types = map(prop_list(3), 'v:val["type"]')
call s:check('caller node uses the caller group', index(s:child_types, 'calltree_caller') >= 0)

let s:group['expanded'] = 0
call calltree#view#Render(bufnr('%'))
call s:check('collapsed group hides children', line('$') == 2)
call s:check('collapsed marker', getline(2) =~# '▸')

" Expanding a node inserts lines below it; the cursor must follow its node
" instead of being reset to line 1 by the full redraw.
let s:group['expanded'] = 1
call calltree#view#Render(bufnr('%'))
call cursor(4, 1)
let s:anchor = b:calltree_index[4]
let s:grand = calltree#new_node(s:child_item, 'in')
let s:grand['parent'] = s:child
call add(s:child['children'], s:grand)
let s:child['expanded'] = 1
call calltree#view#Render(bufnr('%'))
call s:check('cursor follows its node across a redraw', b:calltree_index[line('.')] is s:anchor)
call s:check('cursor is not thrown back to the top', line('.') == 5)

let s:root['children'] = []
call calltree#view#Render(bufnr('%'))
call s:check('root collapse leaves one line', line('$') == 1)

" d: prune a node from the view; its subtree goes with it, the root stays.
enew
setlocal buftype=nofile
let s:droot = calltree#new_node(s:item, 'root')
let s:droot['loaded'] = 1
let s:droot['expanded'] = 1
let s:dchild = calltree#new_node(s:child_item, 'in')
let s:dchild['parent'] = s:droot
let s:droot['children'] = [s:dchild]
let b:calltree = {'gen': 3, 'bufnr': bufnr('%'), 'root': s:droot, 'index': {},
      \ 'srcbufnr': bufnr('%'), 'srcwin': win_getid(), 'pos': {}, 'mode': 'both'}
call setbufvar(bufnr('%'), 'calltree_gen', 3)
call calltree#view#Render(bufnr('%'))
call s:check('tree renders root and child', line('$') == 2)
call cursor(2, 1)
call calltree#action#delete()
call s:check('d removes the node line', line('$') == 1 && getline(1) =~# '● handle')
call s:check('d drops the node from the index', !has_key(b:calltree_index, 2))
call cursor(1, 1)
call calltree#action#delete()
call s:check('d refuses to delete the root', line('$') == 1 && s:droot['name'] ==# 'handle')

" d is incremental: the remaining lines keep their nodes and properties, and
" a group's count is redrawn in place.
enew
setlocal buftype=nofile
let s:iroot = calltree#new_node(s:item, 'root')
let s:iroot['loaded'] = 1
let s:iroot['expanded'] = 1
let s:igroup = calltree#new_node(s:item, 'in')
let s:igroup['name'] = 'Callers'
let s:igroup['group'] = 1
let s:igroup['parent'] = s:iroot
let s:igroup['loaded'] = 1
let s:igroup['expanded'] = 1
let s:iroot['children'] = [s:igroup]
let s:ia = calltree#new_node(s:child_item, 'in')
let s:ia['parent'] = s:igroup
let s:ia['loaded'] = 1
let s:ia['expanded'] = 1
let s:ia1 = calltree#new_node(s:child_item, 'in')
let s:ia1['name'] = 'a1'
let s:ia1['parent'] = s:ia
let s:ia['children'] = [s:ia1]
let s:ib = calltree#new_node(s:child_item, 'in')
let s:ib['name'] = 'b'
let s:ib['parent'] = s:igroup
let s:igroup['children'] = [s:ia, s:ib]
let b:calltree = {'gen': 4, 'bufnr': bufnr('%'), 'root': s:iroot, 'index': {},
      \ 'srcbufnr': bufnr('%'), 'srcwin': win_getid(), 'pos': {}, 'mode': 'both'}
call setbufvar(bufnr('%'), 'calltree_gen', 4)
call calltree#view#Render(bufnr('%'))
call s:check('incremental tree renders 5 lines', line('$') == 5)
call s:check('group shows its child count', getline(2) =~# '(2)')
call cursor(3, 1)
call calltree#action#delete()
call s:check('d removes the node and its expanded child', line('$') == 3)
call s:check('d shifts the following node', b:calltree_index[3] is s:ib)
call s:check('d keeps the group node in the index', b:calltree_index[2] is s:igroup)
call s:check('d redraws the group count', getline(2) =~# '(1)')
call s:check('d keeps props on the shifted line', !empty(prop_list(3)))
call s:check('d keeps the group line style', !empty(prop_list(2)))
call s:check('d keeps the cursor on the following node',
      \ line('.') == 3 && b:calltree_index[line('.')] is s:ib)

" tree connectors: ├─ / └─ for branches, │ where a branch continues, each
" level coloured from the randomly rotated palette
enew
setlocal buftype=nofile
let s:groot = calltree#new_node(s:item, 'root')
let s:groot['loaded'] = 1
let s:groot['expanded'] = 1
let s:groot['children'] = []
for s:label in ['Callers', 'Callees']
  let s:ggroup = calltree#new_node(s:item, s:label ==# 'Callers' ? 'in' : 'out')
  let s:ggroup['name'] = s:label
  let s:ggroup['group'] = 1
  let s:ggroup['parent'] = s:groot
  let s:ggroup['loaded'] = 1
  let s:ggroup['expanded'] = 1
  let s:gchild = calltree#new_node(s:child_item, s:ggroup['dir'])
  let s:gchild['parent'] = s:ggroup
  let s:ggroup['children'] = [s:gchild]
  call add(s:groot['children'], s:ggroup)
endfor
let b:calltree = {'gen': 5, 'bufnr': bufnr('%'), 'root': s:groot, 'index': {},
      \ 'srcbufnr': bufnr('%'), 'srcwin': win_getid(), 'pos': {}, 'mode': 'both'}
call setbufvar(bufnr('%'), 'calltree_gen', 5)
call calltree#view#Render(bufnr('%'))
call s:check('tree draws a connector for a branch', getline(2) =~# '^├─ ')
call s:check('tree closes the last branch with └─', getline(4) =~# '^└─ ')
call s:check('tree continues the parent branch at depth 2',
      \ getline(3) =~# '^│  └─ ')
call s:check('root has no connector', getline(1) =~# '^● ')
let s:gspans = filter(copy(prop_list(3)), 'v:val["type"] =~# "^calltree_guide_"')
call s:check('branch and connector use different colours',
      \ len(s:gspans) == 2
      \ && len(uniq(sort(map(copy(s:gspans), 'v:val["type"]')))) == 2)
call s:check('all guide colours are defined',
      \ len(filter(map(range(1, 6), 'hlexists("CallTreeGuide" . v:val)'), '!v:val')) == 0)
let g:calltree_guides = 0
call calltree#view#Render(bufnr('%'))
call s:check('guides can be turned off',
      \ getline(3) =~# '^    ▸' && getline(3) !~# '│')
unlet g:calltree_guides

" K: the floating definition shows the declaration range, hides itself as soon
" as the tree cursor moves, and does not leak its scratch buffer.
if has('popupwin')
  let s:tmpfile = tempname()
  let s:srclines = ['package x', '', '// doc comment']
  for s:i in range(1, 12)
    call add(s:srclines, "\tline" . s:i)
  endfor
  call add(s:srclines, '}')
  call writefile(s:srclines, s:tmpfile)

  let s:float_item = {
        \ 'name': 'f', 'kind': 12, 'uri': lsp#utils#path_to_uri(s:tmpfile),
        \ 'range': {'start': {'line': 2, 'character': 0}, 'end': {'line': 14, 'character': 1}},
        \ 'selectionRange': {'start': {'line': 2, 'character': 6}, 'end': {'line': 2, 'character': 7}},
        \ }
  let s:froot = calltree#new_node(s:float_item, 'root')
  let s:froot['loaded'] = 1
  let s:froot['expanded'] = 1
  " A second line, so that j/k can actually move the tree cursor.
  let s:fchild = calltree#new_node(s:float_item, 'out')
  let s:fchild['parent'] = s:froot
  let s:fchild['loaded'] = 1
  let s:froot['children'] = [s:fchild]

  enew
  setlocal buftype=nofile
  let b:calltree = {'gen': 2, 'bufnr': bufnr('%'), 'root': s:froot, 'index': {},
        \ 'srcbufnr': bufnr('%'), 'srcwin': win_getid(), 'pos': {}, 'mode': 'both'}
  call setbufvar(bufnr('%'), 'calltree_gen', 2)
  call calltree#view#Render(bufnr('%'))

  let g:calltree_float_height = 6
  call calltree#action#float()
  let s:pops = popup_list()
  call s:check('float opens a popup', len(s:pops) == 1)
  let s:pwin = get(s:pops, 0, 0)
  let s:pfbuf = winbufnr(s:pwin)
  call s:check('float starts at the declaration range',
        \ get(getbufline(s:pfbuf, 1), 0, '') ==# '// doc comment')
  call s:check('float caps its height', popup_getpos(s:pwin)['core_height'] == 6)

  " <C-e>/<C-y> scroll the popup one line at a time without closing it.
  call feedkeys("\<C-e>", 'x')
  call s:check('<C-e> scrolls the float down a line',
        \ get(popup_getpos(s:pwin), 'firstline', 0) == 2
        \ && !empty(popup_list()))
  call feedkeys("\<C-y>", 'x')
  call s:check('<C-y> scrolls the float back up a line',
        \ get(popup_getpos(s:pwin), 'firstline', 0) == 1
        \ && !empty(popup_list()))

  " J/K do the same inside the popup, where they do not reach the tree.
  call feedkeys('J', 'x')
  call s:check('J scrolls the float down a line',
        \ get(popup_getpos(s:pwin), 'firstline', 0) == 2
        \ && !empty(popup_list()))
  call feedkeys('K', 'x')
  call s:check('K scrolls the float back up a line',
        \ get(popup_getpos(s:pwin), 'firstline', 0) == 1
        \ && !empty(popup_list()))

  " Page keys page through a definition that does not fit.
  call feedkeys("\<C-d>", 'x')
  call s:check('page scrolling stays inside the popup',
        \ popup_getpos(s:pwin)['firstline'] == 8 && line('.') == 1)

  " j moves the tree and the popup hides itself ("moved": "any").
  call feedkeys('j', 'x')
  call s:check('j moves the tree and closes the popup',
        \ empty(popup_list()) && line('.') == 2)

  " A key that is not a cursor movement dismisses the popup without reaching
  " the tree.
  call cursor(1, 1)
  call calltree#action#float()
  let s:pfbuf2 = winbufnr(get(popup_list(), 0, 0))
  call feedkeys('x', 'x')
  call s:check('any other key closes the popup',
        \ empty(popup_list()) && line('.') == 1)
  call s:check('the popup buffer is wiped', !bufloaded(s:pfbuf2))

  " 'updatetime' expiry reaches the filter as the synthetic <CursorHold> key;
  " reading a definition must not make it disappear.
  call cursor(1, 1)
  call calltree#action#float()
  call feedkeys("\<CursorHold>", 'x')
  call s:check('CursorHold does not close the definition float',
        \ !empty(popup_list()))
  call feedkeys('x', 'x')
  call s:check('the definition float still closes on a real key',
        \ empty(popup_list()))

  " ?: the key help lists the bindings and dismisses itself on any key.
  call calltree#action#help()
  let s:helpwin = get(popup_list(), 0, 0)
  call s:check('? opens the key help', s:helpwin != 0)
  let s:helpbuf = winbufnr(s:helpwin)
  call s:check('help lists the default keys',
        \ get(getbufline(s:helpbuf, 1), 0, '') =~# '<CR>, o')
  call s:check('help keys are highlighted',
        \ !empty(prop_list(1, {'bufnr': s:helpbuf})))
  call feedkeys("\<CursorHold>", 'x')
  call s:check('CursorHold does not close the key help',
        \ !empty(popup_list()))
  call feedkeys('x', 'x')
  call s:check('any key closes the key help', empty(popup_list()))
  unlet g:calltree_float_height
endif

enew
call calltree#view#InitMaps()
call s:check('? is mapped to the key help',
      \ maparg('?', 'n') ==# '<Plug>(calltree-help)')
call s:check('dd is mapped to delete',
      \ maparg('dd', 'n') ==# '<Plug>(calltree-delete)')
call s:check('J scrolls the preview down',
      \ maparg('J', 'n') ==# '<Plug>(calltree-scroll-down)')
call s:check('K scrolls the preview up',
      \ maparg('K', 'n') ==# '<Plug>(calltree-scroll-up)')
call s:check('gK shows the floating definition',
      \ maparg('gK', 'n') ==# '<Plug>(calltree-float)')
call s:check('gd opens the definition',
      \ maparg('gd', 'n') ==# '<Plug>(calltree-definition)')

" A definition range that only covers the name must not cut the body short:
" for PHP the parser supplies the real extent of the declaration.
if has('popupwin')
  let s:phpfile = tempname() . '.php'
  call writefile(['<?php', 'class X', '{', '    public function long()', '    {']
        \ + map(range(1, 25), '"        $v" . v:val . " = " . v:val . ";"')
        \ + ['    }', '}'], s:phpfile)
  let s:degitem = {
        \ 'name': 'long', 'kind': 12, 'uri': lsp#utils#path_to_uri(s:phpfile),
        \ 'range': {'start': {'line': 3, 'character': 0},
        \           'end': {'line': 3, 'character': 0}},
        \ 'selectionRange': {'start': {'line': 3, 'character': 20},
        \                     'end': {'line': 3, 'character': 24}},
        \ }
  let s:degnode = calltree#new_node(s:degitem, 'root')
  let s:degnode['loaded'] = 1
  enew
  setlocal buftype=nofile
  let b:calltree = {'gen': 9, 'bufnr': bufnr('%'), 'root': s:degnode,
        \ 'index': {1: s:degnode}, 'srcbufnr': bufnr('%'),
        \ 'srcwin': win_getid(), 'pos': {}, 'mode': 'both'}
  let b:calltree_index = {1: s:degnode}
  call calltree#action#float()
  let s:degwin = get(popup_list(), 0, 0)
  let s:deglines = getbufline(winbufnr(s:degwin), 1, '$')
  let s:longdef = calltree#php#FindDef(
        \ calltree#php#ParseFile(s:phpfile), 'long', 3, '')
  call s:check('a name-only range still shows the whole declaration',
        \ !empty(s:longdef)
        \ && len(s:deglines) == s:longdef['end_line'] - s:longdef['start_line'] + 1
        \ && get(s:deglines, 0, '') =~# 'public function long')
  call popup_close(s:degwin)
endif

" The viewer buffer is read-only: q must leave the tree layout, not start a
" macro recording.
enew
setlocal buftype=nofile
let s:prevfile = tempname()
" Padding lines past the ones under test give J/K room to scroll.
call writefile(['package x', 'func f() {}']
      \ + map(range(1, 200), '"line " . v:val'), s:prevfile)
call calltree#action#_preview(s:prevfile, 1, 1)
call s:check('preview buffer shows the file', getline(1) ==# 'package x')
call s:check('preview window shows line numbers',
      \ &l:number && !&l:relativenumber)
call s:check('preview buffer maps q to close the tree',
      \ maparg('q', 'n') ==# '<Plug>(calltree-close)')
call s:check('preview buffer maps <CR> to open the file',
      \ maparg('<CR>', 'n') ==# '<Plug>(calltree-preview-open)')
call s:check('preview buffer maps gd to the definition',
      \ maparg('gd', 'n') ==# '<Plug>(calltree-definition)')
call s:check('preview buffer maps ? to the key help',
      \ maparg('?', 'n') ==# '<Plug>(calltree-help)')

" <CR>: the preview's line is the file's line, so it opens the real file there.
call cursor(2, 1)
call calltree#action#open_preview()
call s:check('preview <CR> opens the file',
      \ resolve(expand('%:p')) ==# resolve(fnamemodify(s:prevfile, ':p')))
call s:check('preview <CR> jumps to the line',
      \ line('.') == 2 && getline(2) ==# 'func f() {}')

" The same keys inside the real tree layout: <CR> goes back to the window
" :CallTree was started from, and ? shows the preview's own key list.
enew
setlocal buftype=nofile
let s:origwin = win_getid()
let g:calltree_tab = 1
let s:layout = calltree#view#OpenWindow({})
call setbufvar(winbufnr(s:layout.tree), 'calltree',
      \ {'gen': 1, 'bufnr': winbufnr(s:layout.tree),
      \  'openwin': s:origwin, 'srcwin': s:layout.viewer})
call win_execute(s:layout.viewer,
      \ 'call calltree#action#_preview(' . string(s:prevfile) . ', 1, 1)')
call win_gotoid(s:layout.viewer)
call cursor(2, 1)
if has('popupwin')
  call calltree#action#help()
  call s:check('preview ? lists the preview keys',
        \ get(getbufline(winbufnr(get(popup_list(), 0, 0)), 1), 0, '') =~# '^<CR>')
  call popup_close(get(popup_list(), 0, 0))
endif

" J/K scroll the viewer a line at a time and leave the tree cursor alone.
" Only the down direction is checked: -es keeps the cursor on the window's top
" line, which makes <C-y> a no-op here even though it works in a real Vim.
call win_gotoid(s:layout.tree)
let s:top = getwininfo(s:layout.viewer)[0]['topline']
call calltree#action#scroll_preview(1)
call s:check('J scrolls the preview down, tree focus stays put',
      \ getwininfo(s:layout.viewer)[0]['topline'] == s:top + 1
      \ && win_getid() == s:layout.tree)
call win_gotoid(s:layout.viewer)
call cursor(2, 1)

call calltree#action#open_preview()
call s:check('preview <CR> returns to the editing window',
      \ win_getid() == s:origwin && tabpagenr() == 1)
call s:check('preview <CR> keeps the preview line',
      \ line('.') == 2
      \ && resolve(expand('%:p')) ==# resolve(fnamemodify(s:prevfile, ':p')))

" gd in the tree: the node's definition in the window :CallTree was started
" from, the same destination as e.  (The preview window's gd resolves the
" symbol under the cursor and needs a language server; integration covers it.)
let s:defitem = {
      \ 'name': 'f', 'kind': 12, 'uri': lsp#utils#path_to_uri(s:prevfile),
      \ 'range': {'start': {'line': 0, 'character': 0},
      \           'end': {'line': 1, 'character': 11}},
      \ 'selectionRange': {'start': {'line': 0, 'character': 0},
      \                     'end': {'line': 0, 'character': 1}},
      \ }
let s:defnode = calltree#new_node(s:defitem, 'root')
let s:defnode['loaded'] = 1
call setbufvar(winbufnr(s:layout.tree), 'calltree_index', {1: s:defnode})
call win_gotoid(s:layout.tree)
call calltree#action#definition()
call s:check('tree gd opens the node definition',
      \ win_getid() == s:origwin && tabpagenr() == 1
      \ && resolve(expand('%:p')) ==# resolve(fnamemodify(s:prevfile, ':p'))
      \ && line('.') == 1)

call win_gotoid(s:layout.tree)
tabclose
unlet g:calltree_tab

" Position conversion, the part every jump depends on.
enew
call setline(1, ['<?php', '    $x = 中文; handle($x);'])
let [s:lnum, s:col] = lsp#utils#position#lsp_to_vim(bufnr('%'), {'line': 1, 'character': 14})
call s:check('utf-16 character to byte column', s:lnum == 2 && s:col == 19)

call writefile(s:log, fnamemodify(s:here, ':h') . '/test/smoke.log')
if s:fail > 0
  cquit
endif
qa!
