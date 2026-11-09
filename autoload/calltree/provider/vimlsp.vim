" autoload/calltree/provider/vimlsp.vim
"
" The only LSP-aware file.  A second provider (nvim builtin LSP, cscope, a
" runtime trace) can be added later without touching the tree or the view.

function! s:has_call_hierarchy(server) abort
  let l:caps = lsp#get_server_capabilities(a:server)
  " callHierarchyProvider is either a boolean or an options dict, and v:false
  " is reported through the same default; empty() flattens all three cases.
  return !empty(get(l:caps, 'callHierarchyProvider', v:false))
endfunction

function! calltree#provider#vimlsp#FindServer(bufnr) abort
  if !exists('*lsp#get_allowed_servers')
    return ''
  endif
  let l:servers = lsp#get_allowed_servers(a:bufnr)
  " Server capabilities only exist after initialize has completed, which
  " happens on the first request.  Prefer a known-good server, otherwise fall
  " back to the first allowed one and let the request start it.
  for l:server in l:servers
    if s:has_call_hierarchy(l:server)
      return l:server
    endif
  endfor
  return empty(l:servers) ? '' : l:servers[0]
endfunction

" vim-lsp's request API is a callbag.  The `bufnr` key is not optional in our
" case: lsp#request uses it for the ensure_flush step (didOpen/didChange) and
" defaults to the current buffer, which for us is the tree scratch buffer that
" has no server attached.
function! s:request(server, bufnr, method, params, Cb) abort
  call lsp#callbag#pipe(
        \ lsp#request(a:server, {
        \   'bufnr': a:bufnr,
        \   'method': a:method,
        \   'params': a:params,
        \ }),
        \ lsp#callbag#subscribe({
        \   'next': function('s:on_response', [a:Cb]),
        \   'error': function('s:on_transport_error', [a:Cb]),
        \ })
        \ )
endfunction

function! s:on_response(Cb, data) abort
  let l:response = a:data['response']
  if lsp#client#is_error(l:response)
    let l:error = get(l:response, 'error', {})
    let l:message = get(l:error, 'message', string(l:error))
    " -32601 is JSON-RPC MethodNotFound.  Several PHP servers (intelephense,
    " phpantom) answer exactly this, and the raw message is unhelpful.
    if get(l:error, 'code', 0) == -32601 || l:message =~? 'unhandled method\|method not found'
      let l:message = 'server does not implement call hierarchy: ' . l:message
    endif
    return a:Cb([], l:message)
  endif
  let l:result = get(l:response, 'result', [])
  if type(l:result) != v:t_list
    " prepareCallHierarchy answers null when the cursor is not on a callable.
    let l:result = []
  endif
  call a:Cb(l:result, '')
endfunction

function! s:on_transport_error(Cb, error) abort
  call a:Cb([], string(a:error))
endfunction

function! calltree#provider#vimlsp#Prepare(server, bufnr, pos, Cb) abort
  call s:request(a:server, a:bufnr, 'textDocument/prepareCallHierarchy', {
        \ 'textDocument': {'uri': lsp#utils#get_buffer_uri(a:bufnr)},
        \ 'position': a:pos,
        \ }, a:Cb)
endfunction

function! calltree#provider#vimlsp#Incoming(server, bufnr, item, Cb) abort
  call s:request(a:server, a:bufnr, 'callHierarchy/incomingCalls', {'item': a:item},
        \ function('s:unpack', [a:Cb, 'from']))
endfunction

function! calltree#provider#vimlsp#Outgoing(server, bufnr, item, Cb) abort
  call s:request(a:server, a:bufnr, 'callHierarchy/outgoingCalls', {'item': a:item},
        \ function('s:unpack', [a:Cb, 'to']))
endfunction

" Incoming entries are {from, fromRanges}, outgoing are {to, fromRanges}.
" Both collapse to {item, ranges} so the tree layer stays direction-agnostic.
" fromRanges are positions inside `from`/`to`, i.e. inside the child node, so
" they can be used to jump to the call site rather than the definition.
function! s:unpack(Cb, side, result, error) abort
  if !empty(a:error)
    return a:Cb([], a:error)
  endif
  let l:calls = []
  for l:entry in a:result
    call add(l:calls, {
          \ 'item': l:entry[a:side],
          \ 'ranges': get(l:entry, 'fromRanges', []),
          \ })
  endfor
  call a:Cb(l:calls, '')
endfunction
