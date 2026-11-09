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
  unlet g:calltree_float_height
endif

" The viewer buffer is read-only: q must leave the tree layout, not start a
" macro recording.
enew
setlocal buftype=nofile
let s:prevfile = tempname()
call writefile(['package x', 'func f() {}'], s:prevfile)
call calltree#action#_preview(s:prevfile, 1, 1)
call s:check('preview buffer shows the file', getline(1) ==# 'package x')
call s:check('preview buffer maps q to close the tree',
      \ maparg('q', 'n') ==# '<Plug>(calltree-close)')

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
