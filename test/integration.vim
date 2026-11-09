" End-to-end check against a real gopls.  Driven by test/integration.sh, which
" creates the fixture project and sets $CALLTREE_TEST_DIR.
set nocompatible
set hidden
let s:dir = $CALLTREE_TEST_DIR
let s:plugin = fnamemodify(expand('<sfile>:p:h'), ':h')
let s:vimlsp = empty($CALLTREE_VIM_LSP) ? expand('~/.vim/plugged/vim-lsp') : $CALLTREE_VIM_LSP
execute 'set rtp+=' . fnameescape(s:plugin)
execute 'set rtp+=' . fnameescape(s:vimlsp)

let g:lsp_use_native_client = 1
let g:lsp_diagnostics_enabled = 0
let g:lsp_log_file = s:dir . '/lsp.log'

runtime! plugin/lsp.vim
runtime! plugin/calltree.vim

call lsp#register_server({
      \ 'name': 'gopls',
      \ 'cmd': {s -> ['gopls']},
      \ 'allowlist': ['go'],
      \ 'root_uri': {s -> lsp#utils#path_to_uri(s:dir)},
      \ })
call lsp#enable()

filetype plugin indent on
execute 'edit ' . fnameescape(s:dir . '/main.go')
setfiletype go
call cursor(search('^func mid'), 6)
call calltree#open('both')

let s:treebuf = bufnr('%')
let s:waited = 0
while s:waited < 300
  sleep 100m
  let s:waited += 1
  let s:ctx = getbufvar(s:treebuf, 'calltree', {})
  if empty(s:ctx) || empty(get(s:ctx, 'root', {}))
    continue
  endif
  let s:groups = s:ctx['root']['children']
  if len(s:groups) == 2 && s:groups[0]['loaded'] && s:groups[1]['loaded']
    break
  endif
endwhile

" expand the caller one more level: top -> main
call win_gotoid(win_findbuf(s:treebuf)[0])
let s:caller = get(b:calltree_index, search(' top  '), {})
if !empty(s:caller)
  call calltree#expand(s:caller, b:calltree)
  let s:more = 0
  while s:more < 300 && !s:caller['loaded']
    sleep 100m
    let s:more += 1
  endwhile
endif

let s:out = getbufline(s:treebuf, 1, '$')
call writefile(s:out, s:dir . '/result.txt')

" Second probe: callee ordering must follow the call order in the body.
call calltree#action#close()
execute 'edit ' . fnameescape(s:dir . '/main.go')
setfiletype go
call cursor(search('^func ordered'), 6)
call calltree#open('both')
let s:treebuf = bufnr('%')
let s:waited = 0
while s:waited < 200
  sleep 100m
  let s:waited += 1
  let s:ctx = getbufvar(s:treebuf, 'calltree', {})
  if empty(s:ctx) || empty(get(s:ctx, 'root', {}))
    continue
  endif
  let s:groups = s:ctx['root']['children']
  if len(s:groups) == 2 && s:groups[0]['loaded'] && s:groups[1]['loaded']
    break
  endif
endwhile
call writefile(getbufline(s:treebuf, 1, '$'), s:dir . '/ordered.txt')

" fmt.Println must be painted with the stdlib group
let s:stdlib_line = search(' Println')
if s:stdlib_line > 0
  call writefile(map(prop_list(s:stdlib_line), 'v:val["type"]'), s:dir . '/stdlib.txt')
endif

" Previewing a callee must land on the call site inside ordered(), not on the
" callee's definition.
" the viewer window of the tree tab is ctx.srcwin when g:calltree_tab is on
let s:srcwin = get(getbufvar(s:treebuf, 'calltree', {}), 'srcwin', 0)
if s:srcwin == 0
  let s:srcwin = win_findbuf(bufnr('main.go'))[0]
endif
call win_gotoid(win_findbuf(s:treebuf)[0])
call cursor(search('▸ third'), 1)
call calltree#action#preview()
call writefile(['preview_third=' . getcurpos(s:srcwin)[1]], s:dir . '/preview.txt')
qa!
