" autoload/calltree/provider/phplsp.vim
"
" PHP provider that leans on the language server where it can:
"   * textDocument/definition resolves the root symbol, including calls like
"     $svc->handle() whose receiver type only the server knows
"   * textDocument/references supplies callers; references are filtered down
"     to actual `name(` call sites and grouped by the enclosing function
"
" Callees stay with the search provider: references describe incoming edges,
" not the body of a function.  Every server step falls back to search when the
" server is missing or does not implement the method.

function! calltree#provider#phplsp#Available(bufnr) abort
  return !empty(calltree#provider#vimlsp#FindServer(a:bufnr))
endfunction

" 'lsp' means the server is the only source; 'auto' may fall back to search.
function! s:fallback() abort
  return calltree#cfg('php_provider', 'auto') !=# 'lsp'
endfunction

function! calltree#provider#phplsp#Prepare(server, bufnr, pos, Cb) abort
  if empty(a:server)
    return calltree#provider#search#Prepare(a:server, a:bufnr, a:pos, a:Cb)
  endif
  " A definition request on a property or a `new Foo(` would resolve to
  " something that is not callable; reject those before asking the server.
  if !calltree#provider#search#CallableAt(a:bufnr, a:pos)
    return a:Cb([], '')
  endif
  call s:request(a:server, a:bufnr, 'textDocument/definition', {
        \ 'textDocument': {'uri': lsp#utils#get_buffer_uri(a:bufnr)},
        \ 'position': a:pos,
        \ }, function('s:on_definition', [a:server, a:bufnr, a:pos, a:Cb]))
endfunction

function! calltree#provider#phplsp#Incoming(server, bufnr, item, Cb) abort
  if empty(a:server) || empty(get(a:item, 'uri', ''))
        \ || !empty(get(get(a:item, 'data', {}), 'top', 0))
    return calltree#provider#search#Incoming(a:server, a:bufnr, a:item, a:Cb)
  endif

  " If the item's file is open, let vim-lsp flush that buffer; otherwise the
  " source buffer is the only one it knows.  The server resolves the URI.
  let l:path = lsp#utils#uri_to_path(a:item['uri'])
  let l:target = bufnr(l:path)
  let l:reqbuf = l:target != -1 ? l:target : a:bufnr
  call s:request(a:server, l:reqbuf, 'textDocument/references', {
        \ 'textDocument': {'uri': a:item['uri']},
        \ 'position': a:item['selectionRange']['start'],
        \ 'context': {'includeDeclaration': v:false},
        \ }, function('s:on_references', [a:server, a:bufnr, a:item, a:Cb]))
endfunction

" Callees are found by scanning the body (no references needed), then every
" call site is refined with textDocument/definition.  That is what resolves
" aliased/inherited methods and chained receivers like
" $this->response()->setData(), which a name search cannot.
function! calltree#provider#phplsp#Outgoing(server, bufnr, item, Cb) abort
  if empty(a:server) || !calltree#cfg('php_callee_definition', 1)
    return calltree#provider#search#Outgoing(a:server, a:bufnr, a:item, a:Cb)
  endif
  call calltree#provider#search#Outgoing(a:server, a:bufnr, a:item,
        \ function('s:on_outgoing', [a:server, a:bufnr, a:item, a:Cb]))
endfunction

" search#Outgoing answers with 2 args on its early-return paths and 3 on the
" normal path, hence the optional meta.
function! s:on_outgoing(server, bufnr, item, Cb, calls, error, ...) abort
  let l:meta = a:0 > 0 ? a:1 : {}
  if !empty(a:error) || empty(a:calls) || empty(get(a:item, 'uri', ''))
    return call(a:Cb, [a:calls, a:error, l:meta])
  endif

  let l:path = lsp#utils#uri_to_path(a:item['uri'])
  let l:target = bufnr(l:path)
  let l:reqbuf = l:target != -1 ? l:target : a:bufnr
  let l:state = {'left': 0, 'calls': a:calls, 'Cb': a:Cb, 'meta': l:meta}

  for l:call in a:calls
    if empty(l:call['ranges'])
      continue
    endif
    let l:state['left'] += 1
    call s:request(a:server, l:reqbuf, 'textDocument/definition', {
          \ 'textDocument': {'uri': a:item['uri']},
          \ 'position': l:call['ranges'][0]['start'],
          \ }, function('s:on_callee_definition', [l:state, l:call]))
  endfor

  if l:state['left'] == 0
    call call(a:Cb, [a:calls, '', l:meta])
  endif
endfunction

function! s:on_callee_definition(state, call, result, error) abort
  if empty(a:error)
    let l:loc = s:first_location(a:result)
    if !empty(l:loc)
      let l:path = lsp#utils#uri_to_path(l:loc['uri'])
      let l:parse = calltree#php#ParseFile(l:path)
      let l:name = a:call['item']['name']
      let l:def = s:def_at(l:parse, l:loc['range']['start']['line'], l:name)
      if !empty(l:def)
        let a:call['item'] = calltree#php#Item(l:parse, l:def)
      elseif empty(get(a:call['item'], 'uri', ''))
        " Name search failed; the server still knows where it is.
        let a:call['item'] = {
              \ 'name': l:name, 'kind': 12, 'detail': '',
              \ 'uri': l:loc['uri'], 'range': l:loc['range'],
              \ 'selectionRange': l:loc['range'], 'data': {'php': 1},
              \ }
      endif
    endif
  endif

  let a:state['left'] -= 1
  if a:state['left'] <= 0
    call call(a:state['Cb'], [a:state['calls'], '', a:state['meta']])
  endif
endfunction

" --- definition ------------------------------------------------------------

function! s:on_definition(server, bufnr, pos, Cb, result, error) abort
  let l:loc = empty(a:error) ? s:first_location(a:result) : {}
  if empty(l:loc)
    if s:fallback()
      " No server answer (unsupported method, no definition, not indexed):
      " the name-based search is the fallback.
      return calltree#provider#search#Prepare(a:server, a:bufnr, a:pos, a:Cb)
    endif
    return a:Cb([], 'no PHP definition found under the cursor')
  endif

  let l:path = lsp#utils#uri_to_path(l:loc['uri'])
  let l:parse = calltree#php#ParseFile(l:path)
  let l:name = s:cursor_name(a:bufnr, a:pos)
  let l:line = l:loc['range']['start']['line']
  let l:def = s:def_at(l:parse, l:line, l:name)

  if !empty(l:def)
    return call(a:Cb, [[calltree#php#Item(l:parse, l:def)], ''])
  endif
  if empty(l:name)
    return calltree#provider#search#Prepare(a:server, a:bufnr, a:pos, a:Cb)
  endif

  " The server knows where the symbol is even when the file could not be
  " parsed; a synthetic item still drives references and preview.
  call a:Cb([{
        \ 'name': l:name,
        \ 'kind': 12,
        \ 'detail': '',
        \ 'uri': l:loc['uri'],
        \ 'range': l:loc['range'],
        \ 'selectionRange': l:loc['range'],
        \ 'data': {'php': 1},
        \ }], '')
endfunction

" Location | Location[] | LocationLink[] | null -> {uri, range}.
function! s:first_location(result) abort
  let l:list = type(a:result) == v:t_list ? a:result : [a:result]
  if empty(l:list) || type(l:list[0]) != v:t_dict
    return {}
  endif
  let l:loc = l:list[0]
  if has_key(l:loc, 'targetUri')
    return {
          \ 'uri': l:loc['targetUri'],
          \ 'range': get(l:loc, 'targetSelectionRange', l:loc['targetRange']),
          \ }
  endif
  if !has_key(l:loc, 'uri') || !has_key(l:loc, 'range')
    return {}
  endif
  return {'uri': l:loc['uri'], 'range': l:loc['range']}
endfunction

function! s:cursor_name(bufnr, pos) abort
  let l:parse = calltree#php#ParseBuffer(a:bufnr)
  let [l:lnum, l:col] = lsp#utils#position#lsp_to_vim(a:bufnr, a:pos)
  let l:word = calltree#php#WordAt(get(l:parse['san'], l:lnum - 1, ''), l:col - 1)
  return empty(l:word) ? '' : l:word['name']
endfunction

function! s:def_at(parse, lnum, name) abort
  for l:def in a:parse['defs']
    if l:def['name_line'] == a:lnum && l:def['name'] ==? a:name
      return l:def
    endif
  endfor
  for l:def in a:parse['defs']
    if l:def['name'] ==? a:name
      return l:def
    endif
  endfor
  return {}
endfunction

" --- references ------------------------------------------------------------

function! s:on_references(server, bufnr, item, Cb, result, error) abort
  if !empty(a:error)
    " references unsupported / server failed: a name search is the fallback.
    if s:fallback()
      return calltree#provider#search#Incoming(a:server, a:bufnr, a:item, a:Cb)
    endif
    return a:Cb([], a:error)
  endif
  " A server that is still indexing can answer with an empty list.  Falling
  " back to search keeps the tree useful; set the option to 0 to trust the
  " server unconditionally.
  if type(a:result) != v:t_list
        \ || (empty(a:result) && s:fallback()
        \     && calltree#cfg('php_references_fallback', 1))
    if s:fallback()
      return calltree#provider#search#Incoming(a:server, a:bufnr, a:item, a:Cb)
    endif
    return a:Cb([], '')
  endif

  let l:name = a:item['name']
  let l:max = calltree#cfg('php_max_results', 300)
  let l:sites = []
  let l:seen = {}
  let l:processed = 0
  let l:overflow = 0

  for l:loc in a:result
    if l:processed >= l:max
      let l:overflow = 1
      break
    endif
    let l:processed += 1
    if type(l:loc) != v:t_dict || !has_key(l:loc, 'uri') || !has_key(l:loc, 'range')
      continue
    endif
    let l:path = lsp#utils#uri_to_path(l:loc['uri'])
    let l:parse = calltree#php#ParseFile(l:path)
    if empty(l:parse['lines'])
      continue
    endif
    let l:start = l:loc['range']['start']
    let l:lnum = get(l:start, 'line', -1)
    if l:lnum < 0 || l:lnum >= len(l:parse['san'])
      continue
    endif
    let l:orig = l:parse['lines'][l:lnum]
    let l:byte = calltree#php#ByteCol(l:orig, get(l:start, 'character', 0))
    let l:col = s:call_col(l:parse['san'][l:lnum], l:name, l:byte)
    if l:col < 0
      continue
    endif
    let l:key = l:path . ':' . l:lnum . ':' . l:col
    if has_key(l:seen, l:key)
      continue
    endif
    let l:seen[l:key] = 1
    call add(l:sites, {'path': l:path, 'line': l:lnum, 'col': l:col})
  endfor

  let [l:calls, l:meta] = calltree#provider#search#IncomingFromSites(
        \ l:name, l:sites, {'overflow': l:overflow})
  call a:Cb(l:calls, '', l:meta)
endfunction

" References also point at imports, docblocks, property reads and strings.
" Only a `name(` on the sanitized line is a call; pick the occurrence closest
" to the position the server reported.
function! s:call_col(san, name, byte) abort
  let l:word = calltree#php#WordAt(a:san, a:byte)
  if !empty(l:word) && l:word['name'] ==? a:name
    let l:after = match(a:san, '\S', l:word['col'] + strlen(a:name))
    if l:after >= 0 && strpart(a:san, l:after, 1) ==# '('
      return l:word['col']
    endif
  endif

  let l:pat = '\c\<' . a:name . '\>\s*('
  let l:pos = 0
  let l:best = -1
  let l:bestd = 0
  while 1
    let l:col = match(a:san, l:pat, l:pos)
    if l:col < 0
      break
    endif
    let l:d = l:col > a:byte ? l:col - a:byte : a:byte - l:col
    if l:best < 0 || l:d < l:bestd
      let l:best = l:col
      let l:bestd = l:d
    endif
    let l:pos = l:col + strlen(a:name)
  endwhile
  return l:best
endfunction

" --- vim-lsp request plumbing ---------------------------------------------

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
    return a:Cb([], get(l:error, 'message', string(l:error)))
  endif
  call a:Cb(get(l:response, 'result', []), '')
endfunction

function! s:on_transport_error(Cb, error) abort
  call a:Cb([], string(a:error))
endfunction
