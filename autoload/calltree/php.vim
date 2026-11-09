" autoload/calltree/php.vim
"
" A small static model of PHP source: function/method definitions, their
" bodies, enclosing classes and call expressions.  It exists to feed the
" search provider (autoload/calltree/provider/search.vim) with CallHierarchy
" like items, since PHP servers generally do not implement
" textDocument/prepareCallHierarchy.
"
" Everything is deliberately approximate.  Lines are sanitized first: strings,
" comments and heredocs are blanked while columns are preserved, so brace
" counting and identifier scans never see code that is not code.  The model
" does not know about namespaces, traits or dynamic dispatch.

let s:cache = {}

" A declaration starts at the line start (modifiers allowed) and ends at the
" function name.  \zs makes match() return the name position.
let s:def_pat = '\c^\s*\(abstract\s\+\|final\s\+\|public\s\+\|protected\s\+\|private\s\+\|static\s\+\)*function\s\+&\?\s*\zs[A-Za-z_][A-Za-z0-9_]*'
let s:class_pat = '\c^\s*\(abstract\s\+\|final\s\+\|readonly\s\+\)*\%(class\|interface\|trait\|enum\)\s\+\zs[A-Za-z_][A-Za-z0-9_]*'

" Keywords that look like calls but are language constructs.  Checked
" lowercased; `array`, `list`, `isset` and friends are the ones that actually
" show up followed by parentheses.
let s:keywords = {}
for s:kw in ['if', 'else', 'elseif', 'for', 'foreach', 'while', 'do', 'switch',
      \ 'case', 'match', 'catch', 'try', 'finally', 'function', 'fn', 'return',
      \ 'echo', 'print', 'include', 'include_once', 'require', 'require_once',
      \ 'isset', 'unset', 'empty', 'list', 'array', 'new', 'clone', 'throw',
      \ 'yield', 'exit', 'die', 'eval', 'declare', 'namespace', 'use',
      \ 'instanceof', 'endif', 'endforeach', 'endwhile', 'endfor', 'endswitch',
      \ 'enddeclare', 'abstract', 'final', 'class', 'interface', 'trait', 'enum',
      \ 'extends', 'implements', 'public', 'protected', 'private', 'static',
      \ 'const', 'var', 'global', 'and', 'or', 'xor', 'as', 'insteadof', 'goto',
      \ 'break', 'continue', 'parent', 'self']
  let s:keywords[s:kw] = 1
endfor
unlet! s:kw

" --- parsing ---------------------------------------------------------------

function! calltree#php#Parse(path, lines) abort
  let l:lines = map(copy(a:lines), 'substitute(v:val, "\r$", "", "")')
  let l:state = {'mode': '', 'term': ''}
  let l:san = []
  for l:line in l:lines
    let [l:s, l:state] = s:san_line(l:line, l:state)
    call add(l:san, l:s)
  endfor

  " Keep the path spelling the user/server uses: /tmp and /private/tmp are the
  " same file but different document URIs to an LSP server.
  let l:path = empty(a:path) ? '' : fnamemodify(a:path, ':p')
  let l:parse = {
        \ 'path': l:path,
        \ 'lines': l:lines,
        \ 'san': l:san,
        \ 'namespace': s:parse_namespace(l:san),
        \ 'defs': [],
        \ 'classes': [],
        \ }
  let l:parse['defs'] = s:parse_defs(l:parse)
  let l:parse['classes'] = s:parse_classes(l:parse)
  call s:attach_classes(l:parse)
  return l:parse
endfunction

function! calltree#php#EmptyParse(path) abort
  return {'path': a:path, 'lines': [], 'san': [], 'namespace': '',
        \ 'defs': [], 'classes': []}
endfunction

" Fully qualified name of a class declared in `parse`.
function! calltree#php#ClassFqn(parse, class) abort
  return empty(a:parse['namespace'])
        \ ? a:class['name']
        \ : a:parse['namespace'] . '\' . a:class['name']
endfunction

function! calltree#php#ParseBuffer(bufnr) abort
  let l:path = empty(bufname(a:bufnr)) ? '' : fnamemodify(bufname(a:bufnr), ':p')
  return calltree#php#Parse(l:path, getbufline(a:bufnr, 1, '$'))
endfunction

" ParseFile prefers a loaded buffer so unsaved edits drive the tree, and
" caches disk reads by mtime/size.  Both the current and referenced files go
" through here.
function! calltree#php#ParseFile(path) abort
  let l:path = fnamemodify(a:path, ':p')
  let l:bufnr = s:bufnr_for(l:path)
  if l:bufnr != -1
    let l:sig = 'buf:' . getbufvar(l:bufnr, 'changedtick')
    if has_key(s:cache, l:path) && s:cache[l:path]['sig'] ==# l:sig
      return s:cache[l:path]['parse']
    endif
    let l:parse = calltree#php#ParseBuffer(l:bufnr)
    let s:cache[l:path] = {'sig': l:sig, 'parse': l:parse}
    return l:parse
  endif

  if !filereadable(l:path)
    return calltree#php#EmptyParse(l:path)
  endif
  let l:size = getfsize(l:path)
  if l:size < 0 || l:size > calltree#cfg('php_max_bytes', 2097152)
    return calltree#php#EmptyParse(l:path)
  endif

  let l:sig = 'file:' . getftime(l:path) . ':' . l:size
  if has_key(s:cache, l:path) && s:cache[l:path]['sig'] ==# l:sig
    return s:cache[l:path]['parse']
  endif
  let l:parse = calltree#php#Parse(l:path, readfile(l:path))
  let s:cache[l:path] = {'sig': l:sig, 'parse': l:parse}
  return l:parse
endfunction

function! calltree#php#ResetCache() abort
  let s:cache = {}
endfunction

function! s:bufnr_for(path) abort
  let l:target = resolve(a:path)
  for l:info in getbufinfo({'bufloaded': 1})
    if !empty(l:info['name']) && resolve(fnamemodify(l:info['name'], ':p')) ==# l:target
      return l:info['bufnr']
    endif
  endfor
  return -1
endfunction

" Blank strings and comments, keeping byte columns intact.  `state` is carried
" across lines because PHP strings, block comments and heredocs can span them.
function! s:san_line(line, state) abort
  let l:out = ''
  let l:line = a:line
  let l:n = strlen(l:line)
  let l:i = 0
  let l:mode = a:state['mode']

  if l:mode ==# 'heredoc'
    let l:m = matchlist(l:line, '^\s*' . a:state['term'] . '\>')
    if empty(l:m)
      return [repeat(' ', l:n), a:state]
    endif
    let l:end = strlen(l:m[0])
    let l:out .= repeat(' ', l:end)
    let l:i = l:end
    let l:mode = ''
    let a:state['mode'] = ''
  endif

  while l:i < l:n
    if l:mode ==# ''
      let l:j = match(l:line, '[/#''"<]', l:i)
      if l:j < 0
        let l:out .= strpart(l:line, l:i)
        break
      endif
      let l:out .= strpart(l:line, l:i, l:j - l:i)
      let l:ch = strpart(l:line, l:j, 1)

      if l:ch ==# '/'
        let l:nx = strpart(l:line, l:j + 1, 1)
        if l:nx ==# '/'
          let l:out .= repeat(' ', l:n - l:j)
          break
        elseif l:nx ==# '*'
          let l:out .= '  '
          let l:i = l:j + 2
          let l:mode = 'block'
          let a:state['mode'] = 'block'
          continue
        endif
        let l:out .= '/'
        let l:i = l:j + 1
        continue
      elseif l:ch ==# '#'
        " #[Attr] is a PHP 8 attribute, not a comment.
        if strpart(l:line, l:j + 1, 1) ==# '['
          let l:out .= '#'
          let l:i = l:j + 1
          continue
        endif
        let l:out .= repeat(' ', l:n - l:j)
        break
      elseif l:ch ==# "'"
        let l:out .= ' '
        let l:i = l:j + 1
        let l:mode = 'single'
        let a:state['mode'] = 'single'
        continue
      elseif l:ch ==# '"'
        let l:out .= ' '
        let l:i = l:j + 1
        let l:mode = 'double'
        let a:state['mode'] = 'double'
        continue
      else
        let l:m = matchlist(strpart(l:line, l:j),
              \ '<<<\s*\([''"]\?\)\([A-Za-z_][A-Za-z0-9_]*\)\1')
        if empty(l:m)
          let l:out .= '<'
          let l:i = l:j + 1
          continue
        endif
        let l:out .= repeat(' ', l:n - l:j)
        let a:state['term'] = l:m[2]
        let a:state['mode'] = 'heredoc'
        break
      endif
    elseif l:mode ==# 'block'
      let l:j = stridx(l:line, '*/', l:i)
      if l:j < 0
        let l:out .= repeat(' ', l:n - l:i)
        break
      endif
      let l:out .= repeat(' ', l:j + 2 - l:i)
      let l:i = l:j + 2
      let l:mode = ''
      let a:state['mode'] = ''
      continue
    else
      let l:close = l:mode ==# 'single' ? "'" : '"'
      let l:j = l:i
      let l:found = 0
      while l:j < l:n
        let l:c = strpart(l:line, l:j, 1)
        if l:c ==# '\'
          let l:j += 2
          continue
        endif
        if l:c ==# l:close
          let l:found = 1
          break
        endif
        let l:j += 1
      endwhile
      if l:found
        let l:out .= repeat(' ', l:j + 1 - l:i)
        let l:i = l:j + 1
        let l:mode = ''
        let a:state['mode'] = ''
        continue
      endif
      let l:out .= repeat(' ', l:n - l:i)
      break
    endif
  endwhile

  return [l:out, a:state]
endfunction

function! s:parse_defs(parse) abort
  let l:defs = []
  let l:lines = a:parse['san']
  let l:lnum = 0
  while l:lnum < len(l:lines)
    let l:line = l:lines[l:lnum]
    let l:col = match(l:line, s:def_pat)
    if l:col < 0
      let l:lnum += 1
      continue
    endif
    let l:name = matchstr(l:line, s:def_pat)
    let l:next = s:next_sig(a:parse['san'], l:lnum, l:col + strlen(l:name))
    if empty(l:next) || l:next['char'] !=# '('
      let l:lnum += 1
      continue
    endif
    call add(l:defs, s:build_def(a:parse, l:lnum, l:col, l:name, l:next))
    let l:lnum += 1
  endwhile
  return l:defs
endfunction

" Build one definition: signature, parameters, body and the comment block that
" belongs to it.  A `;` where a body would be marks an abstract/interface
" method.
function! s:build_def(parse, lnum, col, name, paren) abort
  let l:san = a:parse['san']
  let l:close = s:match_pair(l:san, a:paren['line'], a:paren['col'], '(', ')')
  let l:body = empty(l:close) ? {} : s:find_body(l:san, l:close['line'], l:close['col'] + 1)

  let l:head = strpart(a:parse['san'][a:lnum], 0, a:col)
  let l:visibility = matchstr(l:head, '\c\<\(public\|protected\|private\)\>')
  let l:def = {
        \ 'name': a:name,
        \ 'name_line': a:lnum,
        \ 'name_col': a:col,
        \ 'name_char': calltree#php#Utf16Col(a:parse['lines'][a:lnum], a:col),
        \ 'visibility': empty(l:visibility) ? 'public' : tolower(l:visibility),
        \ 'static': l:head =~# '\c\<static\>' ? 1 : 0,
        \ 'sig_line': a:lnum,
        \ 'start_line': 0,
        \ 'end_line': a:lnum,
        \ 'body_start_line': -1,
        \ 'body_start_col': -1,
        \ 'body_end_line': -1,
        \ 'body_end_col': -1,
        \ 'abstract': 0,
        \ 'class': '',
        \ }

  if !empty(l:body) && l:body['char'] ==# '{'
    let l:def['body_start_line'] = l:body['line']
    let l:def['body_start_col'] = l:body['col']
    let l:end = s:match_pair(l:san, l:body['line'], l:body['col'], '{', '}')
    if empty(l:end)
      let l:def['body_end_line'] = len(l:san) - 1
      let l:def['body_end_col'] = strlen(get(l:san, len(l:san) - 1, ''))
    else
      let l:def['body_end_line'] = l:end['line']
      let l:def['body_end_col'] = l:end['col']
    endif
    let l:def['end_line'] = l:def['body_end_line']
  elseif !empty(l:body) && l:body['char'] ==# ';'
    let l:def['abstract'] = 1
    let l:def['end_line'] = l:body['line']
  endif

  let l:def['start_line'] = s:comment_start(a:parse, a:lnum)
  return l:def
endfunction

" The doc block directly above a declaration belongs to it; K uses
" item.range.start to show it.
function! s:comment_start(parse, lnum) abort
  let l:first = a:lnum
  while l:first > 0
    let l:prev = a:parse['lines'][l:first - 1]
    if l:prev !~# '^\s*\(//\|#\|\*\|/\*\)'
      break
    endif
    let l:first -= 1
  endwhile
  return l:first
endfunction

function! s:parse_namespace(san) abort
  for l:line in a:san
    let l:m = matchlist(l:line, '\c^\s*namespace\s\+\([A-Za-z_\\][A-Za-z0-9_\\]*\)\s*[;{]')
    if !empty(l:m)
      return l:m[1]
    endif
  endfor
  return ''
endfunction

function! s:parse_classes(parse) abort
  let l:classes = []
  let l:lines = a:parse['san']
  let l:lnum = 0
  while l:lnum < len(l:lines)
    let l:line = l:lines[l:lnum]
    let l:col = match(l:line, s:class_pat)
    if l:col < 0
      let l:lnum += 1
      continue
    endif
    let l:name = matchstr(l:line, s:class_pat)
    let l:open = s:find_char(l:lines, l:lnum, l:col + strlen(l:name), '{')
    if !empty(l:open)
      let l:close = s:match_pair(l:lines, l:open['line'], l:open['col'], '{', '}')
      let l:end = empty(l:close) ? len(l:lines) - 1 : l:close['line']
      let l:parent = matchstr(strpart(l:line, l:col + strlen(l:name)),
            \ '\c\<extends\s\+\zs[A-Za-z_\\][A-Za-z0-9_\\]*')
      call add(l:classes, {
            \ 'name': l:name,
            \ 'kind': tolower(matchstr(l:line, '\c\<\(class\|interface\|trait\|enum\)\>')),
            \ 'start_line': l:lnum,
            \ 'end_line': l:end,
            \ 'parent': l:parent,
            \ })
    endif
    let l:lnum += 1
  endwhile
  return l:classes
endfunction

function! s:attach_classes(parse) abort
  for l:def in a:parse['defs']
    let l:best = {}
    for l:class in a:parse['classes']
      if l:def['name_line'] >= l:class['start_line'] && l:def['name_line'] <= l:class['end_line']
        if empty(l:best) || l:class['start_line'] > l:best['start_line']
          let l:best = l:class
        endif
      endif
    endfor
    let l:def['class'] = empty(l:best) ? '' : l:best['name']
  endfor
endfunction

" --- small scanners --------------------------------------------------------

function! s:next_sig(san, lnum, col) abort
  let l:l = a:lnum
  let l:c = a:col
  let l:guard = 0
  while l:l < len(a:san) && l:guard < 200
    let l:k = match(a:san[l:l], '\S', l:c)
    if l:k >= 0
      return {'line': l:l, 'col': l:k, 'char': strpart(a:san[l:l], l:k, 1)}
    endif
    let l:l += 1
    let l:c = 0
    let l:guard += 1
  endwhile
  return {}
endfunction

" Find the first of `chars` from a position, crossing lines.
function! s:find_char(san, lnum, col, chars) abort
  let l:l = a:lnum
  let l:c = a:col
  let l:guard = 0
  while l:l < len(a:san) && l:guard < 400
    let l:line = a:san[l:l]
    let l:k = match(l:line, '[' . a:chars . ']', l:c)
    if l:k >= 0
      return {'line': l:l, 'col': l:k, 'char': strpart(l:line, l:k, 1)}
    endif
    let l:l += 1
    let l:c = 0
    let l:guard += 1
  endwhile
  return {}
endfunction

" Where the body starts after the parameter list.  Return types may contain
" parenthesised DNF types, so track parens until `{` or `;`.
function! s:find_body(san, lnum, col) abort
  let l:l = a:lnum
  let l:c = a:col
  let l:depth = 0
  let l:guard = 0
  while l:l < len(a:san) && l:guard < 400
    let l:line = a:san[l:l]
    while 1
      let l:k = match(l:line, '[(){};]', l:c)
      if l:k < 0
        break
      endif
      let l:ch = strpart(l:line, l:k, 1)
      if l:ch ==# '('
        let l:depth += 1
      elseif l:ch ==# ')'
        let l:depth -= 1
      elseif l:depth == 0 && (l:ch ==# '{' || l:ch ==# ';')
        return {'line': l:l, 'col': l:k, 'char': l:ch}
      endif
      let l:c = l:k + 1
    endwhile
    let l:l += 1
    let l:c = 0
    let l:guard += 1
  endwhile
  return {}
endfunction

" Matching close for open/close at (lnum, col).  Jumps between braces with
" match() instead of walking every byte: PHP bodies are large and this runs
" once per function definition.
function! s:match_pair(san, lnum, col, open, close) abort
  let l:l = a:lnum
  let l:c = a:col
  let l:depth = 0
  let l:guard = 0
  let l:pat = '[' . a:open . a:close . ']'
  while l:l < len(a:san) && l:guard < 2000
    let l:line = a:san[l:l]
    while 1
      let l:k = match(l:line, l:pat, l:c)
      if l:k < 0
        break
      endif
      if strpart(l:line, l:k, 1) ==# a:open
        let l:depth += 1
      else
        let l:depth -= 1
        if l:depth == 0
          return {'line': l:l, 'col': l:k, 'char': a:close}
        endif
      endif
      let l:c = l:k + 1
    endwhile
    let l:l += 1
    let l:c = 0
    let l:guard += 1
  endwhile
  return {}
endfunction

" --- queries ---------------------------------------------------------------

function! calltree#php#ClassAt(parse, lnum) abort
  let l:best = {}
  for l:class in a:parse['classes']
    if a:lnum >= l:class['start_line'] && a:lnum <= l:class['end_line']
      if empty(l:best) || l:class['start_line'] > l:best['start_line']
        let l:best = l:class
      endif
    endif
  endfor
  return l:best
endfunction

function! calltree#php#EnclosingDef(parse, lnum) abort
  let l:best = {}
  for l:def in a:parse['defs']
    if l:def['body_start_line'] >= 0
          \ && a:lnum >= l:def['body_start_line']
          \ && a:lnum <= l:def['body_end_line']
      if empty(l:best) || l:def['body_start_line'] > l:best['body_start_line']
        let l:best = l:def
      endif
    endif
  endfor
  return l:best
endfunction

function! calltree#php#FindDefs(parse, name) abort
  let l:out = []
  for l:def in a:parse['defs']
    if l:def['name'] ==? a:name
      call add(l:out, l:def)
    endif
  endfor
  return l:out
endfunction

" Pick the definition a name most likely refers to inside one file.  `class`
" is the receiver class when it is known ($this, self, Class::).
function! calltree#php#FindDef(parse, name, lnum, class) abort
  let l:cands = calltree#php#FindDefs(a:parse, a:name)
  if empty(l:cands)
    return {}
  endif
  if !empty(a:class)
    for l:def in l:cands
      if l:def['class'] ==? a:class
        return l:def
      endif
    endfor
  endif
  for l:def in l:cands
    if l:def['name_line'] == a:lnum
      return l:def
    endif
  endfor
  for l:def in l:cands
    if empty(l:def['class'])
      return l:def
    endif
  endfor
  return l:cands[0]
endfunction

function! calltree#php#IsDefName(parse, lnum, col) abort
  for l:def in a:parse['defs']
    if l:def['name_line'] == a:lnum && l:def['name_col'] == a:col
      return 1
    endif
  endfor
  return 0
endfunction

" Identifier under a byte column.  Returns {} when the cursor is not on one.
function! calltree#php#WordAt(line, col) abort
  let l:start = a:col
  while l:start > 0 && strpart(a:line, l:start - 1, 1) =~# '[A-Za-z0-9_]'
    let l:start -= 1
  endwhile
  let l:end = a:col
  while l:end < strlen(a:line) && strpart(a:line, l:end, 1) =~# '[A-Za-z0-9_]'
    let l:end += 1
  endwhile
  let l:name = strpart(a:line, l:start, l:end - l:start)
  if l:name !~# '^[A-Za-z_][A-Za-z0-9_]*$'
    return {}
  endif
  return {'name': l:name, 'col': l:start}
endfunction

" Byte column -> UTF-16 code units, which is what LSP positions use.  PHP
" identifiers are ASCII, but there can be non-ASCII code earlier on the line.
function! calltree#php#Utf16Col(line, byte_col) abort
  let l:units = 0
  for l:ch in split(strpart(a:line, 0, a:byte_col), '\zs')
    let l:units += char2nr(l:ch) > 0xFFFF ? 2 : 1
  endfor
  return l:units
endfunction

" The inverse, for turning an LSP position into a byte column.
function! calltree#php#ByteCol(line, char) abort
  let l:units = 0
  let l:bytes = 0
  for l:ch in split(a:line, '\zs')
    if l:units >= a:char
      break
    endif
    let l:units += char2nr(l:ch) > 0xFFFF ? 2 : 1
    let l:bytes += strlen(l:ch)
  endfor
  return l:bytes
endfunction

" A one-line LSP range for the identifier at byte_col.
function! calltree#php#Range(line, lnum, byte_col, len) abort
  let l:char = calltree#php#Utf16Col(a:line, a:byte_col)
  return {
        \ 'start': {'line': a:lnum, 'character': l:char},
        \ 'end': {'line': a:lnum, 'character': l:char + a:len},
        \ }
endfunction

" All positions of `name` followed by `(` on a sanitized line.  Used for
" incoming calls; CallSites sees only real code because of sanitizing.
function! calltree#php#CallSites(parse, lnum, name) abort
  let l:line = get(a:parse['san'], a:lnum, '')
  let l:pat = '\c\<' . a:name . '\>\s*('
  let l:out = []
  let l:pos = 0
  while 1
    let l:col = match(l:line, l:pat, l:pos)
    if l:col < 0
      break
    endif
    call add(l:out, l:col)
    let l:pos = l:col + strlen(a:name)
  endwhile
  return l:out
endfunction

" Receiver context to the left of an identifier: $this->, Foo::, $var->,
" new Foo, function foo, or a plain call.
function! calltree#php#CallContext(line, col) abort
  let l:before = strpart(a:line, 0, a:col)
  let l:trim = substitute(l:before, '\s\+$', '', '')

  if l:trim =~# '->$'
    let l:recv = substitute(l:trim, '->$', '', '')
    return s:receiver(substitute(l:recv, '\s\+$', '', ''))
  elseif l:trim =~# '::$'
    let l:recv = substitute(l:trim, '::$', '', '')
    return s:receiver(substitute(l:recv, '\s\+$', '', ''))
  endif
  if l:before =~# '\$$'
    return {'kind': 'var', 'recv': '', 'recv_name': ''}
  endif
  " new \App\Foo( and new Foo( both construct a class, not call a function.
  if l:trim =~? '\<new\s\+[A-Za-z_\\][A-Za-z0-9_\\]*$'
    return {'kind': 'new', 'recv': '', 'recv_name': ''}
  endif
  let l:word = matchstr(l:trim, '\<[A-Za-z_][A-Za-z0-9_]*$')
  if l:word =~? '^\(function\|fn\|new\)$'
    return {'kind': tolower(l:word), 'recv': '', 'recv_name': ''}
  endif
  return {'kind': 'call', 'recv': '', 'recv_name': ''}
endfunction

function! s:receiver(text) abort
  if a:text =~# '\$this$'
    return {'kind': 'self', 'recv': '$this', 'recv_name': ''}
  endif
  if a:text =~# '\<self$' || a:text =~# '\<static$'
    return {'kind': 'self', 'recv': a:text, 'recv_name': ''}
  endif
  if a:text =~# '\<parent$'
    return {'kind': 'parent', 'recv': 'parent', 'recv_name': ''}
  endif
  if a:text =~# '\$[A-Za-z_][A-Za-z0-9_]*$'
    return {'kind': 'any', 'recv': matchstr(a:text, '\$[A-Za-z_][A-Za-z0-9_]*$'),
          \ 'recv_name': ''}
  endif
  " The class expression is the last token before ::, not the whole prefix:
  " `$data = \App\Svc::run()` must yield \App\Svc.
  let l:name = matchstr(a:text, '[A-Za-z_\\][A-Za-z0-9_\\]*$')
  if empty(l:name)
    return {'kind': 'any', 'recv': '', 'recv_name': ''}
  endif
  return {'kind': 'class', 'recv': l:name, 'recv_name': l:name}
endfunction

" Every call expression inside a function body, in source order.
function! calltree#php#FindCalls(parse, def) abort
  let l:calls = []
  if a:def['body_start_line'] < 0
    return l:calls
  endif

  let l:def_pos = {}
  for l:def in a:parse['defs']
    let l:def_pos[l:def['name_line'] . ':' . l:def['name_col']] = 1
  endfor

  let l:lnum = a:def['body_start_line']
  let l:last = a:def['body_end_line']
  while l:lnum <= l:last && l:lnum < len(a:parse['san'])
    let l:line = a:parse['san'][l:lnum]
    let l:limit = strlen(l:line)
    let l:pos = 0
    if l:lnum == a:def['body_start_line']
      let l:pos = a:def['body_start_col'] + 1
    endif
    if l:lnum == l:last && a:def['body_end_col'] >= 0
      let l:limit = a:def['body_end_col']
    endif
    while l:pos < l:limit
      let l:m = matchstrpos(l:line, '\<[A-Za-z_][A-Za-z0-9_]*\>', l:pos)
      if empty(l:m[0])
        break
      endif
      let l:name = l:m[0]
      let l:col = l:m[1]
      let l:pos = l:m[2]

      if has_key(s:keywords, tolower(l:name))
        continue
      endif
      if has_key(l:def_pos, l:lnum . ':' . l:col)
        continue
      endif

      let l:after = match(l:line, '\S', l:pos)
      if l:after < 0 || l:after >= l:limit || strpart(l:line, l:after, 1) !=# '('
        continue
      endif

      let l:ctx = calltree#php#CallContext(l:line, l:col)
      if l:ctx['kind'] ==# 'var' || l:ctx['kind'] ==# 'new'
            \ || l:ctx['kind'] ==# 'function' || l:ctx['kind'] ==# 'fn'
        continue
      endif
      call add(l:calls, {
            \ 'name': l:name,
            \ 'line': l:lnum,
            \ 'col': l:col,
            \ 'len': strlen(l:name),
            \ 'recv_kind': l:ctx['kind'],
            \ 'recv_name': l:ctx['recv_name'],
            \ })
    endwhile
    let l:lnum += 1
  endwhile
  return l:calls
endfunction

" Parent class name of the class holding `def`, for parent:: calls.
function! calltree#php#ParentClass(parse, def) abort
  if empty(a:def['class'])
    return ''
  endif
  for l:class in a:parse['classes']
    if l:class['name'] ==? a:def['class']
          \ && a:def['name_line'] >= l:class['start_line']
          \ && a:def['name_line'] <= l:class['end_line']
      return l:class['parent']
    endif
  endfor
  return ''
endfunction

" --- items -----------------------------------------------------------------

" Convert a definition into the CallHierarchyItem shape the rest of the plugin
" speaks.  `data` carries no server state; the search provider re-derives the
" definition from uri + selectionRange when a node is expanded.
function! calltree#php#Item(parse, def) abort
  let l:end_line = a:def['end_line']
  let l:end_text = get(a:parse['lines'], l:end_line, '')
  return {
        \ 'name': a:def['name'],
        \ 'kind': 12,
        \ 'detail': empty(a:def['class']) ? a:def['name'] : a:def['class'] . '::' . a:def['name'],
        \ 'uri': lsp#utils#path_to_uri(a:parse['path']),
        \ 'range': {
        \   'start': {'line': a:def['start_line'], 'character': 0},
        \   'end': {'line': l:end_line, 'character': strlen(l:end_text)},
        \ },
        \ 'selectionRange': {
        \   'start': {'line': a:def['name_line'], 'character': a:def['name_char']},
        \   'end': {'line': a:def['name_line'],
        \           'character': a:def['name_char'] + strlen(a:def['name'])},
        \ },
        \ 'data': {'php': 1, 'class': a:def['class']},
        \ }
endfunction

" Code outside any function (bootstrap files, includes) still calls things.
" Group those under a per-file node so they show up without pretending to be
" a function.
function! calltree#php#TopLevelItem(parse) abort
  let l:name = fnamemodify(a:parse['path'], ':t')
  return {
        \ 'name': l:name . ' (top level)',
        \ 'kind': 13,
        \ 'detail': '',
        \ 'uri': lsp#utils#path_to_uri(a:parse['path']),
        \ 'range': {
        \   'start': {'line': 0, 'character': 0},
        \   'end': {'line': 0, 'character': 0},
        \ },
        \ 'selectionRange': {
        \   'start': {'line': 0, 'character': 0},
        \   'end': {'line': 0, 'character': 0},
        \ },
        \ 'data': {'php': 1, 'top': 1},
        \ }
endfunction

" No definition found in the project (built-in, dynamic, vendor outside the
" root).  The node is still useful: it names the call in the tree.
function! calltree#php#UnresolvedItem(name) abort
  return {
        \ 'name': a:name,
        \ 'kind': 12,
        \ 'detail': '',
        \ 'uri': '',
        \ 'range': {
        \   'start': {'line': 0, 'character': 0},
        \   'end': {'line': 0, 'character': 0},
        \ },
        \ 'selectionRange': {
        \   'start': {'line': 0, 'character': 0},
        \   'end': {'line': 0, 'character': 0},
        \ },
        \ 'data': {'php': 1, 'unresolved': 1},
        \ }
endfunction
