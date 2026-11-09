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
