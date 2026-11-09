" autoload/calltree/provider.vim
"
" Provider dispatch.  The tree layer only speaks CallHierarchyItem, so a
" backend is three functions: Prepare, Incoming and Outgoing.  PHP is served
" by a static search backend because PHP language servers rarely implement
" textDocument/prepareCallHierarchy.

function! calltree#provider#Choose(bufnr) abort
  let l:ft = getbufvar(a:bufnr, '&filetype')
  let l:name = fnamemodify(bufname(a:bufnr), ':t')
  let l:is_php = l:ft ==# 'php' || l:name =~? '\.\%(php[345]\?\|phtml\)$'
  if l:is_php
    " auto: definition/references through the server, search as fallback.
    " 'lsp': server only, no search fallback.  'search': pure search.
    let l:mode = calltree#cfg('php_provider', 'auto')
    if l:mode ==# 'search'
      return 'search'
    endif
    let l:has_server = !empty(calltree#provider#vimlsp#FindServer(a:bufnr))
    if l:mode ==# 'lsp'
      return l:has_server ? 'phplsp' : ''
    endif
    return l:has_server ? 'phplsp' : 'search'
  endif
  return 'vimlsp'
endfunction

function! calltree#provider#Prepare(provider, server, bufnr, pos, Cb) abort
  call call('calltree#provider#' . a:provider . '#Prepare',
        \ [a:server, a:bufnr, a:pos, a:Cb])
endfunction

function! calltree#provider#Incoming(provider, server, bufnr, item, Cb) abort
  call call('calltree#provider#' . a:provider . '#Incoming',
        \ [a:server, a:bufnr, a:item, a:Cb])
endfunction

function! calltree#provider#Outgoing(provider, server, bufnr, item, Cb) abort
  call call('calltree#provider#' . a:provider . '#Outgoing',
        \ [a:server, a:bufnr, a:item, a:Cb])
endfunction
