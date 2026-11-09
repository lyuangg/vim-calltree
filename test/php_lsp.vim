" PHP + intelephense: definition resolves the root, references supply callers,
" and callees still come from the source scan.  Driven by test/php_lsp.sh.
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
      \ 'name': 'intelephense',
      \ 'cmd': {s -> ['intelephense', '--stdio']},
      \ 'allowlist': ['php'],
      \ 'root_uri': {s -> lsp#utils#path_to_uri(s:dir)},
      \ })
call lsp#enable()
" Give the indexer time to see files that are not open in a buffer.
sleep 10

filetype plugin indent on
let g:calltree_tab = 0
let g:calltree_preview = 0
let g:calltree_auto_expand = 1
" Force the references path: an empty answer must not silently become search.
let g:calltree_php_references_fallback = 0

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

function! s:open(rel, line_pattern, word) abort
  execute 'edit ' . fnameescape(s:dir . '/' . a:rel)
  setfiletype php
  call cursor(1, 1)
  let l:lnum = search(a:line_pattern, 'W')
  call cursor(l:lnum, match(getline(l:lnum), a:word) + 1)
  call calltree#open('both')
  let l:bufnr = bufnr('%')
  call s:wait(l:bufnr, 600)
  return l:bufnr
endfunction

" Open the caller file first: vim-lsp sends didOpen when a request uses it,
" and intelephense then includes its call sites in references.
let s:bufnr = s:open('src/Controller.php', '\\App\\leaf()', 'leaf')
call writefile(getbufline(s:bufnr, 1, '$'), s:dir . '/leaf.txt')
call calltree#action#close()

let s:bufnr = s:open('src/Svc.php', 'function handle', 'handle')
call writefile(getbufline(s:bufnr, 1, '$'), s:dir . '/handle.txt')
call calltree#action#close()

qa!
