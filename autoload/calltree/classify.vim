" autoload/calltree/classify.vim
"
" Tells project code apart from the standard library and third-party modules so
" the tree view can colour them differently.  Purely path based: GOROOT and the
" Go module cache are asked from `go env` once per session.

let s:initialized = 0
let s:goroot = ''
let s:gomodcache = ''
let s:cache = {}

function! s:go_env(name) abort
  let l:value = getenv(a:name)
  if !empty(l:value)
    return l:value
  endif
  if !executable('go')
    return ''
  endif
  try
    return trim(system('go env ' . a:name))
  catch
    return ''
  endtry
endfunction

function! s:init() abort
  let s:initialized = 1
  let l:goroot = s:go_env('GOROOT')
  if !empty(l:goroot)
    let s:goroot = resolve(l:goroot) . '/src/'
  endif
  let l:modcache = s:go_env('GOMODCACHE')
  if !empty(l:modcache)
    let s:gomodcache = resolve(l:modcache) . '/'
  endif
endfunction

" '' for project code, otherwise 'stdlib' | 'dependency' | 'vendor'.
function! calltree#classify#kind(uri) abort
  if empty(a:uri)
    return ''
  endif
  if has_key(s:cache, a:uri)
    return s:cache[a:uri]
  endif
  if !s:initialized
    call s:init()
  endif

  let l:path = resolve(lsp#utils#uri_to_path(a:uri))
  let l:kind = ''
  if !empty(s:goroot) && stridx(l:path, s:goroot) == 0
    let l:kind = 'stdlib'
  elseif !empty(s:gomodcache) && stridx(l:path, s:gomodcache) == 0
    let l:kind = 'dependency'
  elseif stridx(l:path, '/pkg/mod/') >= 0
    let l:kind = 'dependency'
  elseif stridx(l:path, '/vendor/') >= 0
    let l:kind = 'vendor'
  endif

  let s:cache[a:uri] = l:kind
  return l:kind
endfunction
