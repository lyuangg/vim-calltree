" PHP search provider tests.  Driven by test/php.sh, which builds the fixture
" project and sets $CALLTREE_TEST_DIR.
set nocompatible
set hidden

let s:dir = $CALLTREE_TEST_DIR
let s:plugin = fnamemodify(expand('<sfile>:p:h'), ':h')
let s:vimlsp = empty($CALLTREE_VIM_LSP) ? expand('~/.vim/plugged/vim-lsp') : $CALLTREE_VIM_LSP
execute 'set rtp+=' . fnameescape(s:plugin)
execute 'set rtp+=' . fnameescape(s:vimlsp)

runtime! plugin/calltree.vim
filetype plugin indent on

let g:calltree_tab = 0
let g:calltree_preview = 0
let g:calltree_auto_expand = 1
" This file covers the search backend; test/php_lsp.sh covers the server path.
let g:calltree_php_provider = 'search'
if !empty($CALLTREE_PHP_ENGINE)
  let g:calltree_php_engine = $CALLTREE_PHP_ENGINE
endif

let s:log = []
let s:fail = 0

function! s:check(name, cond) abort
  if !a:cond
    let s:fail += 1
  endif
  call add(s:log, (a:cond ? 'ok   ' : 'FAIL ') . a:name)
endfunction

" --- source model ----------------------------------------------------------

let s:parse = calltree#php#Parse(s:dir . '/src/Svc.php',
      \ readfile(s:dir . '/src/Svc.php'))
call s:check('parser finds 6 definitions', len(s:parse['defs']) == 6)

let s:svc = {}
let s:base = {}
for s:class in s:parse['classes']
  if s:class['name'] ==# 'Svc'
    let s:svc = s:class
  elseif s:class['name'] ==# 'BaseSvc'
    let s:base = s:class
  endif
endfor
call s:check('parser assigns classes',
      \ !empty(s:svc) && !empty(s:base) && s:svc['parent'] ==# 'BaseSvc')

let s:handle = calltree#php#FindDef(s:parse, 'handle', -1, 'Svc')
let s:handle_calls = map(calltree#php#FindCalls(s:parse, s:handle), 'v:val["name"]')
call s:check('parser ignores comments, strings and heredocs',
      \ s:handle['class'] ==# 'Svc'
      \ && len(s:handle_calls) == 3
      \ && index(s:handle_calls, 'helper') >= 0
      \ && index(s:handle_calls, 'leaf') >= 0
      \ && index(s:handle_calls, 'count') >= 0)

let s:heredoc = calltree#php#FindDef(s:parse, 'withHeredoc', -1, 'Svc')
let s:heredoc_calls = map(calltree#php#FindCalls(s:parse, s:heredoc), 'v:val["name"]')
call s:check('parser skips new expressions',
      \ s:heredoc_calls == ['leaf'])

call s:check('parser keeps utf-16 columns',
      \ calltree#php#Utf16Col('    $x = 中文; handle($x);', 17) == 13)

" --- tree ------------------------------------------------------------------

function! s:loading(bufnr) abort
  for l:node in values(getbufvar(a:bufnr, 'calltree_index', {}))
    if l:node['loading']
      return 1
    endif
  endfor
  return 0
endfunction

function! s:wait(bufnr, max) abort
  let l:i = 0
  while l:i < a:max
    sleep 50m
    let l:i += 1
    let l:ctx = getbufvar(a:bufnr, 'calltree', {})
    if empty(l:ctx) || empty(get(l:ctx, 'root', {}))
      continue
    endif
    let l:groups = l:ctx['root']['children']
    if empty(l:groups)
      continue
    endif
    let l:ready = 1
    for l:group in l:groups
      if !l:group['loaded']
        let l:ready = 0
      endif
    endfor
    if l:ready && !s:loading(a:bufnr)
      return
    endif
  endwhile
endfunction

function! s:open(rel, line_pattern, word, occurrence) abort
  execute 'edit ' . fnameescape(s:dir . '/' . a:rel)
  setfiletype php
  call cursor(1, 1)
  let l:lnum = 0
  let l:i = 0
  while l:i < a:occurrence
    let l:lnum = search(a:line_pattern, 'W')
    if l:lnum == 0
      return -1
    endif
    let l:i += 1
  endwhile
  call cursor(l:lnum, match(getline(l:lnum), a:word) + 1)
  call calltree#open('both')
  let l:bufnr = bufnr('%')
  call s:wait(l:bufnr, 200)
  return l:bufnr
endfunction

function! s:dump(name, bufnr) abort
  call writefile(getbufline(a:bufnr, 1, '$'), s:dir . '/' . a:name)
endfunction

let s:bufnr = s:open('src/Svc.php', 'function handle', 'handle', 1)
call s:dump('result.txt', s:bufnr)
call calltree#action#close()

let s:bufnr = s:open('src/Controller.php', '\$svc->handle(1)', 'handle', 1)
call s:dump('callsite.txt', s:bufnr)
call calltree#action#close()

let s:bufnr = s:open('src/Svc.php', 'public function run', 'run', 1)
call s:dump('run.txt', s:bufnr)
call calltree#action#close()

" Expand pong under ping: ping is already an ancestor, so it must be marked
" as a cycle instead of being expanded forever.
let s:bufnr = s:open('src/Cycle.php', 'function ping', 'ping', 1)
let s:treewin = win_findbuf(s:bufnr)[0]
call win_execute(s:treewin, 'call cursor(search("▸ pong", "W"), 1)')
call win_execute(s:treewin, 'call calltree#action#toggle()')
let s:i = 0
while s:i < 100 && s:loading(s:bufnr)
  sleep 50m
  let s:i += 1
endwhile
call s:dump('cycle.txt', s:bufnr)
call calltree#action#close()

" A low cap must be visible in the tree rather than silently truncating.
let g:calltree_php_max_results = 2
let s:bufnr = s:open('src/Hot.php', 'function hot', 'hot', 1)
call s:dump('cap.txt', s:bufnr)
unlet g:calltree_php_max_results
call calltree#action#close()

" Callers are filtered by class and visibility.
let s:bufnr = s:open('src/Static.php', 'public static function boot', 'boot', 1)
call s:dump('static_callers.txt', s:bufnr)
call calltree#action#close()

let s:bufnr = s:open('src/Static.php', 'private function secret', 'secret', 1)
call s:dump('secret_callers.txt', s:bufnr)
call calltree#action#close()

call writefile(s:log, s:dir . '/unit.txt')
if s:fail > 0
  cquit
endif
qa!
