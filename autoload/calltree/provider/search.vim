" autoload/calltree/provider/search.vim
"
" Search-backed call hierarchy for PHP.  It implements the same three
" functions as the vim-lsp provider and returns CallHierarchyItem dicts, so
" the tree, preview, ordering, cycle handling and quickfix export are shared
" with the LSP backend.
"
" The model is static and name based:
"   * a definition is found by searching for `function <name>(`
"   * callers are call sites `name(`, grouped by their enclosing function
"   * callees are the call expressions inside the body, resolved by name
"
" Receivers that are statically known ($this, self, parent, Class::) are
" resolved in two steps: find the class declaration, then the method inside
" its body.  That is what keeps same-named methods of unrelated classes apart.
" Dynamic dispatch is out of scope; see README.

let s:root_cache = {}

" --- entry points ----------------------------------------------------------

function! calltree#provider#search#Available() abort
  return !empty(s:engine())
endfunction

function! calltree#provider#search#RootDir(bufnr) abort
  let l:path = fnamemodify(bufname(a:bufnr), ':p')
  if empty(l:path)
    return resolve(getcwd())
  endif
  let l:dir = fnamemodify(l:path, ':h')
  if has_key(s:root_cache, l:dir)
    return s:root_cache[l:dir]
  endif

  let l:cur = l:dir
  let l:guard = 0
  while !empty(l:cur) && l:guard < 48
    if isdirectory(l:cur . '/.git') || filereadable(l:cur . '/composer.json')
      let s:root_cache[l:dir] = l:cur
      return l:cur
    endif
    let l:parent = fnamemodify(l:cur, ':h')
    if l:parent ==# l:cur
      break
    endif
    let l:cur = l:parent
    let l:guard += 1
  endwhile

  let l:cwd = fnamemodify(getcwd(), ':p')
  let l:root = stridx(resolve(l:dir), resolve(l:cwd)) == 0 ? l:cwd : l:dir
  let s:root_cache[l:dir] = l:root
  return l:root
endfunction

function! calltree#provider#search#Prepare(server, bufnr, pos, Cb) abort
  let l:parse = calltree#php#ParseBuffer(a:bufnr)
  if empty(l:parse['lines']) || empty(l:parse['path'])
    return a:Cb([], 'save the buffer to a PHP file first')
  endif

  let [l:lnum1, l:col1] = lsp#utils#position#lsp_to_vim(a:bufnr, a:pos)
  let l:lnum = l:lnum1 - 1
  let l:col = l:col1 - 1
  let l:san = get(l:parse['san'], l:lnum, '')

  " The cursor anywhere on a signature line means "this function".
  for l:def in l:parse['defs']
    if l:def['name_line'] == l:lnum
      return a:Cb([calltree#php#Item(l:parse, l:def)], '')
    endif
  endfor

  let l:word = calltree#php#WordAt(l:san, l:col)
  if empty(l:word)
    return a:Cb([], '')
  endif
  " A variable or property is not a callable symbol.
  if l:word['col'] > 0 && strpart(l:san, l:word['col'] - 1, 1) ==# '$'
    return a:Cb([], '')
  endif
  if calltree#php#CallContext(l:san, l:word['col'])['kind'] ==# 'new'
    return a:Cb([], '')
  endif
  " The name must be used as a call, `name(`; declarations are handled above.
  let l:after = match(l:san, '\S', l:word['col'] + strlen(l:word['name']))
  if l:after < 0 || strpart(l:san, l:after, 1) !=# '('
    return a:Cb([], '')
  endif

  let l:classes = s:cursor_classes(l:parse, l:lnum, l:san, l:word['col'])
  let l:local = s:pick_class(calltree#php#FindDefs(l:parse, l:word['name']),
        \ l:classes, l:lnum)
  if !empty(l:local)
    return a:Cb([calltree#php#Item(l:parse, l:local)], '')
  endif

  call s:find_definition(l:word['name'], l:classes, a:bufnr, a:Cb)
endfunction

function! calltree#provider#search#Incoming(server, bufnr, item, Cb) abort
  if !empty(get(get(a:item, 'data', {}), 'top', 0))
    return a:Cb([], '')
  endif
  let l:name = get(a:item, 'name', '')
  if empty(l:name)
    return a:Cb([], '')
  endif
  let l:found = s:def_for_item(a:item)
  if empty(l:found) || empty(l:found['def']['class'])
    return s:incoming_function(l:name, a:bufnr, a:Cb)
  endif
  return s:incoming_method(l:found, a:bufnr, a:Cb)
endfunction

function! calltree#provider#search#Outgoing(server, bufnr, item, Cb) abort
  let l:found = s:def_for_item(a:item)
  if empty(l:found)
    return a:Cb([], '')
  endif
  let l:calls = calltree#php#FindCalls(l:found['parse'], l:found['def'])
  if empty(l:calls)
    return a:Cb([], '')
  endif

  let l:max = calltree#cfg('max_children', 50)
  let l:state = {
        \ 'calls': {},
        \ 'names': [],
        \ 'orig': {},
        \ 'picked': {},
        \ 'extra': 0,
        \ 'bufnr': a:bufnr,
        \ 'root_parse': l:found['parse'],
        \ 'root_def': l:found['def'],
        \ 'Cb': a:Cb,
        \ }

  " The receiver is part of the identity: $this->save() and parent::save()
  " can resolve to different methods in the same body.
  for l:call in l:calls
    let l:key = s:call_key(l:call)
    if has_key(l:state['calls'], l:key)
      call add(l:state['calls'][l:key], l:call)
    elseif len(l:state['names']) >= l:max
      let l:state['extra'] += 1
    else
      let l:state['calls'][l:key] = [l:call]
      let l:state['orig'][l:key] = l:call['name']
      call add(l:state['names'], l:key)
    endif
  endfor

  " Same-file definitions are cheap and usually the right ones.
  for l:key in l:state['names']
    let l:cands = calltree#php#FindDefs(l:state['root_parse'], l:state['orig'][l:key])
    let l:pick = s:pick_class(l:cands, s:wanted_classes(l:state['calls'][l:key][0],
          \ l:state['root_parse'], l:state['root_def']), -1)
    if !empty(l:pick)
      let l:state['picked'][l:key] = {'parse': l:state['root_parse'], 'def': l:pick}
    endif
  endfor

  call s:resolve_outgoing(l:state)
endfunction

" --- prepare helpers -------------------------------------------------------

" True when the position is on a function declaration or a `name(` call.  It
" keeps the PHP providers from treating variables, properties and `new Foo(`
" as callable symbols.
function! calltree#provider#search#CallableAt(bufnr, pos) abort
  let l:parse = calltree#php#ParseBuffer(a:bufnr)
  if empty(l:parse['lines'])
    return 0
  endif
  let [l:lnum1, l:col1] = lsp#utils#position#lsp_to_vim(a:bufnr, a:pos)
  let l:lnum = l:lnum1 - 1
  let l:col = l:col1 - 1
  for l:def in l:parse['defs']
    if l:def['name_line'] == l:lnum
      return 1
    endif
  endfor

  let l:san = get(l:parse['san'], l:lnum, '')
  let l:word = calltree#php#WordAt(l:san, l:col)
  if empty(l:word)
    return 0
  endif
  if l:word['col'] > 0 && strpart(l:san, l:word['col'] - 1, 1) ==# '$'
    return 0
  endif
  if calltree#php#CallContext(l:san, l:word['col'])['kind'] ==# 'new'
    return 0
  endif
  let l:after = match(l:san, '\S', l:word['col'] + strlen(l:word['name']))
  return l:after >= 0 && strpart(l:san, l:after, 1) ==# '('
endfunction

" Classes the symbol under the cursor most likely belongs to.  For $this and
" self the current class comes first, then its parent (inherited methods).
function! s:cursor_classes(parse, lnum, san, col) abort
  let l:ctx = calltree#php#CallContext(a:san, a:col)
  let l:out = []
  if l:ctx['kind'] ==# 'class'
    call add(l:out, l:ctx['recv_name'])
  elseif l:ctx['kind'] ==# 'self' || l:ctx['kind'] ==# 'parent'
    let l:class = calltree#php#ClassAt(a:parse, a:lnum)
    if empty(l:class)
      return l:out
    endif
    if l:ctx['kind'] ==# 'self'
      call add(l:out, l:class['name'])
    endif
    if !empty(l:class['parent'])
      call add(l:out, s:last_segment(l:class['parent']))
    endif
  endif
  return l:out
endfunction

" Pick a definition from one file, honouring class hints.  With no hint,
" prefer the cursor line, then a global function, then the first match.
function! s:pick_class(cands, classes, lnum) abort
  if empty(a:cands)
    return {}
  endif
  for l:class in a:classes
    for l:def in a:cands
      if s:class_eq(l:def['class'], l:class)
        return l:def
      endif
    endfor
  endfor
  if !empty(a:classes)
    return {}
  endif
  for l:def in a:cands
    if l:def['name_line'] == a:lnum
      return l:def
    endif
  endfor
  for l:def in a:cands
    if empty(l:def['class'])
      return l:def
    endif
  endfor
  return a:cands[0]
endfunction

" With a known receiver class, find the class first: searching for the method
" name alone can land on an unrelated same-named method.
function! s:find_definition(name, classes, bufnr, Cb) abort
  if !empty(a:classes)
    let l:names = []
    for l:class in a:classes
      call add(l:names, s:last_segment(l:class))
    endfor
    return s:find_classes(l:names, {'bufnr': a:bufnr},
          \ function('s:on_prepare_classes', [a:name, a:classes, a:bufnr, a:Cb]))
  endif
  call s:find_definition_by_name(a:name, a:classes, a:bufnr, a:Cb)
endfunction

function! s:on_prepare_classes(name, classes, bufnr, Cb, found, error) abort
  if empty(a:error)
    for l:want in a:classes
      for l:cls in get(a:found, tolower(s:last_segment(l:want)), [])
        if !s:class_want_eq(l:cls['parse'], l:cls['class'], l:want)
          continue
        endif
        let l:def = s:def_in_class(l:cls['parse'], l:cls['class'], a:name)
        if !empty(l:def)
          return call(a:Cb, [[calltree#php#Item(l:cls['parse'], l:def)], ''])
        endif
      endfor
    endfor
  endif
  call s:find_definition_by_name(a:name, a:classes, a:bufnr, a:Cb)
endfunction

function! s:find_definition_by_name(name, classes, bufnr, Cb) abort
  let l:pattern = '\bfunction\s+&?\s*' . a:name . '\s*\('
  call s:search(l:pattern, calltree#provider#search#RootDir(a:bufnr),
        \ {'max': 200},
        \ function('s:on_definition_search', [a:name, a:classes, a:Cb]))
endfunction

" Parse candidates lazily: a name can be defined in hundreds of files, and
" parsing all of them costs seconds in Vim script.
function! s:on_definition_search(name, classes, Cb, matches, meta) abort
  if !empty(get(a:meta, 'error', ''))
    return a:Cb([], a:meta['error'])
  endif
  let l:fallback = {}
  let l:tried = 0
  let l:parsed = {}
  for l:m in a:matches
    if l:tried >= 20
      break
    endif
    let l:parse = calltree#php#ParseFile(l:m['path'])
    if !has_key(l:parsed, l:m['path'])
      let l:parsed[l:m['path']] = 1
      let l:tried += 1
    endif
    let l:def = s:def_at(l:parse, l:m['line'], a:name)
    if empty(l:def)
      continue
    endif
    let l:cand = {'parse': l:parse, 'def': l:def}
    if empty(l:fallback)
      let l:fallback = l:cand
    endif
    for l:class in a:classes
      if s:class_eq(l:def['class'], l:class)
        return a:Cb([calltree#php#Item(l:parse, l:def)], '')
      endif
    endfor
    if empty(a:classes)
      return a:Cb([calltree#php#Item(l:parse, l:def)], '')
    endif
  endfor
  if empty(l:fallback)
    return a:Cb([], 'no PHP definition found for "' . a:name . '"')
  endif
  call a:Cb([calltree#php#Item(l:fallback['parse'], l:fallback['def'])], '')
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

" --- incoming --------------------------------------------------------------
"
" Callers are filtered by call form, not just by name:
"   * a global function only matches plain `name(`
"   * a method matches Class::name(, self::/static::/parent:: and $this->name(
"   * private methods are searched only in their own file, protected ones in
"     the class file and direct subclasses
"   * a public method also matches $var->name( in files that mention the class
" That is what keeps `Foo::init(` out of the callers of `Bar::init(`.

function! s:incoming_function(name, bufnr, Cb) abort
  " Exclude method/static forms at the regex level: a preceding -, :, > or
  " backslash means ->name(, ::name( or \name(.
  let l:pattern = '(?:^|[^-:>\\])\b' . a:name . '\s*\('
  call s:search(l:pattern, calltree#provider#search#RootDir(a:bufnr),
        \ {'max': calltree#cfg('php_max_results', 300)},
        \ function('s:on_incoming', [a:name, a:Cb, {'method': 0}]))
endfunction

function! s:incoming_method(found, bufnr, Cb) abort
  let l:def = a:found['def']
  let l:opts = {
        \ 'method': 1,
        \ 'name': l:def['name'],
        \ 'target': l:def['class'],
        \ 'visibility': l:def['visibility'],
        \ 'static': l:def['static'],
        \ 'kind': s:class_kind(a:found['parse'], l:def['class']),
        \ 'allowed_classes': {tolower(l:def['class']): 1},
        \ 'allowed_files': {a:found['parse']['path']: 1},
        \ 'overrides': {},
        \ 'mentions': {},
        \ }

  " Private methods never leave the class; interfaces have no extends chain
  " that a search can follow here.
  if l:opts['visibility'] ==# 'private' || l:opts['kind'] ==# 'interface'
    return s:incoming_method_search(a:found, l:opts, a:bufnr, a:Cb)
  endif

  let l:target = escape(l:def['class'], '\')
  " rg uses Rust regex syntax: +, ? and (...) are the quantifiers/groups.
  if l:opts['kind'] ==# 'trait'
    let l:pattern = '\buse\s+([A-Za-z_\\][A-Za-z0-9_\\]*\\)?' . l:target . '\b'
  else
    let l:pattern = '\bextends\s+([A-Za-z_\\][A-Za-z0-9_\\]*\\)?' . l:target . '\b'
  endif
  call s:search(l:pattern, calltree#provider#search#RootDir(a:bufnr),
        \ {'max': 100},
        \ function('s:on_related', [l:opts, a:found, a:bufnr, a:Cb]))
endfunction

" Subclasses (or classes using a trait) can call the method.  A subclass that
" overrides it is kept for parent:: but not for self/static/$this.
function! s:on_related(opts, found, bufnr, Cb, matches, meta) abort
  if !empty(get(a:meta, 'error', ''))
    return s:incoming_method_search(a:found, a:opts, a:bufnr, a:Cb)
  endif
  let l:target = a:opts['target']
  let l:parsed = {}
  let l:tried = 0
  for l:m in a:matches
    if l:tried >= 30
      break
    endif
    if has_key(l:parsed, l:m['path'])
      continue
    endif
    let l:parsed[l:m['path']] = 1
    let l:tried += 1
    let l:parse = calltree#php#ParseFile(l:m['path'])
    for l:class in l:parse['classes']
      if a:opts['kind'] !=# 'trait'
            \ && s:last_segment(l:class['parent']) !=? l:target
        continue
      endif
      let l:key = tolower(l:class['name'])
      if has_key(a:opts['allowed_classes'], l:key)
        continue
      endif
      let a:opts['allowed_classes'][l:key] = 1
      let a:opts['allowed_files'][l:parse['path']] = 1
      if !empty(s:def_in_class(l:parse, l:class, a:opts['name']))
        let a:opts['overrides'][l:key] = 1
      endif
    endfor
  endfor
  call s:incoming_method_search(a:found, a:opts, a:bufnr, a:Cb)
endfunction

function! s:incoming_method_search(found, opts, bufnr, Cb) abort
  let l:parts = []
  let l:names = keys(a:opts['allowed_classes'])
  if a:opts['static']
    call add(l:parts, '\b(?:' . join(l:names, '|') . ')\s*::\s*'
          \ . a:opts['name'] . '\s*\(')
  endif
  let l:selfish = a:opts['static']
        \ ? '(?:\$this\s*->|(?:self|static|parent)\s*::)'
        \ : '(?:\$this\s*->|parent\s*::)'
  call add(l:parts, l:selfish . '\s*' . a:opts['name'] . '\s*\(')
  " Instance calls; public ones are filtered by the file mentioning the class.
  call add(l:parts, '\$[A-Za-z_]\w*\s*->\s*' . a:opts['name'] . '\s*\(')
  let l:pattern = '(?:' . join(l:parts, '|') . ')'

  " A single file as the search root loses the filename in ag's output, so
  " search the directory and let accept_site() keep only the class file.
  let l:root = a:opts['visibility'] ==# 'private'
        \ ? fnamemodify(a:found['parse']['path'], ':h')
        \ : calltree#provider#search#RootDir(a:bufnr)
  call s:search(l:pattern, l:root,
        \ {'max': calltree#cfg('php_max_results', 300)},
        \ function('s:on_incoming', [a:opts['name'], a:Cb, a:opts]))
endfunction

function! s:on_incoming(name, Cb, opts, matches, meta) abort
  if !empty(get(a:meta, 'error', ''))
    return a:Cb([], a:meta['error'])
  endif

  " rg reports lines; keep only the call sites that belong to this symbol.
  let l:sites = []
  for l:m in a:matches
    let l:parse = calltree#php#ParseFile(l:m['path'])
    if empty(l:parse['lines']) || l:m['line'] >= len(l:parse['san'])
      continue
    endif
    for l:col in calltree#php#CallSites(l:parse, l:m['line'], a:name)
      if !s:accept_site(a:opts, l:parse, l:m['line'], l:col)
        continue
      endif
      call add(l:sites, {'path': l:m['path'], 'line': l:m['line'], 'col': l:col})
    endfor
  endfor

  let [l:calls, l:meta] = calltree#provider#search#IncomingFromSites(a:name, l:sites, a:meta)
  call a:Cb(l:calls, '', l:meta)
endfunction

function! s:accept_site(opts, parse, lnum, col) abort
  let l:san = a:parse['san'][a:lnum]
  let l:ctx = calltree#php#CallContext(l:san, a:col)

  if !a:opts['method']
    return l:ctx['kind'] ==# 'call'
  endif

  if l:ctx['kind'] ==# 'class'
    let l:recv = tolower(s:last_segment(l:ctx['recv_name']))
    if !has_key(a:opts['allowed_classes'], l:recv)
      return 0
    endif
    if a:opts['visibility'] !=# 'public'
          \ && !has_key(a:opts['allowed_files'], a:parse['path'])
      return 0
    endif
    return !has_key(a:opts['overrides'], l:recv)
  endif

  if l:ctx['kind'] ==# 'self' || l:ctx['kind'] ==# 'parent'
    let l:class = calltree#php#ClassAt(a:parse, a:lnum)
    let l:key = tolower(get(l:class, 'name', ''))
    if !has_key(a:opts['allowed_classes'], l:key)
          \ || !has_key(a:opts['allowed_files'], a:parse['path'])
      return 0
    endif
    if l:ctx['kind'] ==# 'parent'
      " parent:: in the class itself calls its parent, not this method.
      return l:key !=? tolower(a:opts['target'])
    endif
    return !has_key(a:opts['overrides'], l:key)
  endif

  if l:ctx['kind'] ==# 'any'
    if a:opts['visibility'] ==# 'public'
      return s:file_mentions(a:parse, a:opts)
    endif
    " A private method is reachable on any instance of the class, so look at
    " the class the call is written in, not just the file.
    let l:key = tolower(get(calltree#php#ClassAt(a:parse, a:lnum), 'name', ''))
    if a:opts['visibility'] ==# 'private'
      return l:key ==? tolower(a:opts['target'])
    endif
    return has_key(a:opts['allowed_classes'], l:key)
  endif

  return 0
endfunction

" A public instance method can be called through any variable.  Restricting
" those to files that mention the class is a cheap precision/recall trade.
function! s:file_mentions(parse, opts) abort
  let l:path = a:parse['path']
  if has_key(a:opts['mentions'], l:path)
    return a:opts['mentions'][l:path]
  endif
  let l:pat = '\c\<' . join(keys(a:opts['allowed_classes']), '\|') . '\>'
  let l:found = 0
  for l:line in a:parse['lines']
    if l:line =~# l:pat
      let l:found = 1
      break
    endif
  endfor
  let a:opts['mentions'][l:path] = l:found
  return l:found
endfunction

function! s:class_kind(parse, name) abort
  for l:class in a:parse['classes']
    if l:class['name'] ==? a:name
      return get(l:class, 'kind', 'class')
    endif
  endfor
  return 'class'
endfunction

" Shared by the search and the LSP-references callers: turn call positions
" into caller nodes, grouped by the enclosing function.
" sites: [{path, line (0-based), col (byte, 0-based)}]
function! calltree#provider#search#IncomingFromSites(name, sites, meta) abort
  let l:by_key = {}
  let l:order = []
  for l:site in a:sites
    let l:parse = calltree#php#ParseFile(l:site['path'])
    if empty(l:parse['lines']) || l:site['line'] >= len(l:parse['san'])
      continue
    endif
    let l:san = l:parse['san'][l:site['line']]
    let l:col = l:site['col']
    if calltree#php#IsDefName(l:parse, l:site['line'], l:col)
      continue
    endif
    " `new Foo(` / `new \App\Foo(` constructs a class, not a call.
    if calltree#php#CallContext(l:san, l:col)['kind'] ==# 'new'
      continue
    endif

    let l:def = calltree#php#EnclosingDef(l:parse, l:site['line'])
    let l:item = empty(l:def)
          \ ? calltree#php#TopLevelItem(l:parse)
          \ : calltree#php#Item(l:parse, l:def)
    let l:key = calltree#item_key(l:item)
    let l:range = calltree#php#Range(l:parse['lines'][l:site['line']],
          \ l:site['line'], l:col, strlen(a:name))
    if has_key(l:by_key, l:key)
      call add(l:by_key[l:key]['ranges'], l:range)
    else
      let l:entry = {'item': l:item, 'ranges': [l:range]}
      let l:by_key[l:key] = l:entry
      call add(l:order, l:entry)
    endif
  endfor
  return [l:order, {'overflow': get(a:meta, 'overflow', 0)}]
endfunction

" --- outgoing --------------------------------------------------------------

" Stage 1: decide what still needs a search.  A statically known receiver is
" resolved through its class; everything else by function name.
function! s:resolve_outgoing(state) abort
  let l:need_class = {}
  let l:need_name = {}
  for l:key in a:state['names']
    if has_key(a:state['picked'], l:key)
      continue
    endif
    let l:wants = s:wanted_classes(a:state['calls'][l:key][0],
          \ a:state['root_parse'], a:state['root_def'])
    if empty(l:wants)
      let l:need_name[tolower(a:state['orig'][l:key])] = a:state['orig'][l:key]
    else
      for l:want in l:wants
        let l:last = s:last_segment(l:want)
        let l:need_class[tolower(l:last)] = l:last
      endfor
    endif
  endfor

  if !empty(l:need_class)
    return s:find_classes(values(l:need_class), a:state,
          \ function('s:on_outgoing_classes', [a:state]))
  endif
  if !empty(l:need_name)
    return s:search_names(a:state, l:need_name)
  endif
  return s:outgoing_done(a:state, {})
endfunction

" Search class declarations by unqualified name.  Vendor is included: parent
" classes and shared base classes often live there.
function! s:find_classes(names, state, Cb) abort
  let l:pattern = '\b(class|interface|trait|enum)\s+(' . join(a:names, '|') . ')\b'
  call s:search(l:pattern, calltree#provider#search#RootDir(a:state['bufnr']),
        \ {'max': 200, 'ignore': 0}, function('s:on_classes', [a:Cb]))
endfunction

" Several namespaces can declare the same class name, so keep a short list
" per name and let the caller match the fully qualified name.
function! s:on_classes(Cb, matches, meta) abort
  if !empty(get(a:meta, 'error', ''))
    return call(a:Cb, [{}, a:meta['error']])
  endif
  let l:found = {}
  let l:parsed = {}
  let l:tried = 0
  for l:m in a:matches
    if l:tried >= 30
      break
    endif
    if has_key(l:parsed, l:m['path'])
      continue
    endif
    let l:parsed[l:m['path']] = 1
    let l:tried += 1
    let l:parse = calltree#php#ParseFile(l:m['path'])
    " A file can declare several classes; register all of them.
    for l:class in l:parse['classes']
      let l:key = tolower(l:class['name'])
      if !has_key(l:found, l:key)
        let l:found[l:key] = []
      endif
      if len(l:found[l:key]) < 10
        call add(l:found[l:key], {'parse': l:parse, 'class': l:class})
      endif
    endfor
  endfor
  call a:Cb(l:found, '')
endfunction

function! s:on_outgoing_classes(state, classes, error) abort
  if !empty(a:error)
    return call(a:state['Cb'], [[], a:error])
  endif

  for l:key in a:state['names']
    if has_key(a:state['picked'], l:key)
      continue
    endif
    let l:wants = s:wanted_classes(a:state['calls'][l:key][0],
          \ a:state['root_parse'], a:state['root_def'])
    for l:want in l:wants
      for l:cls in get(a:classes, tolower(s:last_segment(l:want)), [])
        if !s:class_want_eq(l:cls['parse'], l:cls['class'], l:want)
          continue
        endif
        let l:def = s:def_in_class(l:cls['parse'], l:cls['class'], a:state['orig'][l:key])
        if !empty(l:def)
          let a:state['picked'][l:key] = {'parse': l:cls['parse'], 'def': l:def}
          break
        endif
      endfor
      if has_key(a:state['picked'], l:key)
        break
      endif
    endfor
  endfor

  let l:need_name = {}
  for l:key in a:state['names']
    if has_key(a:state['picked'], l:key)
      continue
    endif
    if empty(s:wanted_classes(a:state['calls'][l:key][0],
          \ a:state['root_parse'], a:state['root_def']))
      let l:need_name[tolower(a:state['orig'][l:key])] = a:state['orig'][l:key]
    endif
  endfor
  if empty(l:need_name)
    return s:outgoing_done(a:state, {})
  endif
  return s:search_names(a:state, l:need_name)
endfunction

" Stage 2 for plain calls ($var->m(), m()): resolve by function name.
function! s:search_names(state, need) abort
  let l:pattern = '\bfunction\s+&?\s*(' . join(values(a:need), '|') . ')\s*\('
  call s:search(l:pattern, calltree#provider#search#RootDir(a:state['bufnr']),
        \ {'max': calltree#cfg('php_max_results', 300)},
        \ function('s:on_outgoing_names', [a:state]))
endfunction

function! s:on_outgoing_names(state, matches, meta) abort
  if !empty(get(a:meta, 'error', ''))
    return call(a:state['Cb'], [[], a:meta['error']])
  endif

  " Group by name, then parse only the first usable definition per name.
  let l:by_name = {}
  for l:m in a:matches
    let l:name = matchstr(l:m['text'], '\cfunction\s\+&\?\s*\zs[A-Za-z_][A-Za-z0-9_]*')
    if empty(l:name)
      continue
    endif
    let l:k = tolower(l:name)
    if !has_key(l:by_name, l:k)
      let l:by_name[l:k] = []
    endif
    call add(l:by_name[l:k], l:m)
  endfor

  for l:key in a:state['names']
    if has_key(a:state['picked'], l:key)
      continue
    endif
    let l:k = tolower(a:state['orig'][l:key])
    for l:m in get(l:by_name, l:k, [])
      let l:parse = calltree#php#ParseFile(l:m['path'])
      let l:def = s:def_at(l:parse, l:m['line'], a:state['orig'][l:key])
      if empty(l:def)
        continue
      endif
      let a:state['picked'][l:key] = {'parse': l:parse, 'def': l:def}
      break
    endfor
  endfor

  call s:outgoing_done(a:state, a:meta)
endfunction

function! s:outgoing_done(state, meta) abort
  let l:calls = []
  for l:key in a:state['names']
    let l:sites = []
    for l:call in a:state['calls'][l:key]
      call add(l:sites, s:range(
            \ get(a:state['root_parse']['lines'], l:call['line'], ''),
            \ l:call['line'], l:call['col'], l:call['len']))
    endfor
    let l:item = has_key(a:state['picked'], l:key)
          \ ? calltree#php#Item(a:state['picked'][l:key]['parse'],
          \                     a:state['picked'][l:key]['def'])
          \ : calltree#php#UnresolvedItem(a:state['calls'][l:key][0]['name'])
    call add(l:calls, {'item': l:item, 'ranges': l:sites})
  endfor
  call call(a:state['Cb'], [l:calls, '', {
        \ 'hidden': a:state['extra'],
        \ 'overflow': get(a:meta, 'overflow', 0),
        \ }])
endfunction

function! s:call_key(call) abort
  return tolower(a:call['name']) . '|' . a:call['recv_kind'] . '|'
        \ . tolower(a:call['recv_name'])
endfunction

" Classes a call must resolve to, when the receiver says so.  self tries the
" current class and its parent; parent only the parent.
function! s:wanted_classes(call, parse, def) abort
  let l:out = []
  if a:call['recv_kind'] ==# 'self'
    if !empty(a:def['class'])
      call add(l:out, a:def['class'])
    endif
    let l:parent = calltree#php#ParentClass(a:parse, a:def)
    if !empty(l:parent)
      call add(l:out, l:parent)
    endif
  elseif a:call['recv_kind'] ==# 'parent'
    let l:parent = calltree#php#ParentClass(a:parse, a:def)
    if !empty(l:parent)
      call add(l:out, l:parent)
    endif
  elseif a:call['recv_kind'] ==# 'class'
    call add(l:out, a:call['recv_name'])
  endif
  return l:out
endfunction

function! s:def_in_class(parse, class, name) abort
  for l:def in a:parse['defs']
    if l:def['name'] ==? a:name && l:def['class'] ==? a:class['name']
      return l:def
    endif
  endfor
  return {}
endfunction

function! s:last_segment(name) abort
  let l:parts = split(a:name, '\\')
  return empty(l:parts) ? a:name : l:parts[-1]
endfunction

function! s:class_eq(a, b) abort
  return !empty(a:a) && !empty(a:b) && s:last_segment(a:a) ==? s:last_segment(a:b)
endfunction

" A qualified want (\Luna\Controller\Base) must match the file namespace;
" an unqualified one only has the class name to go by.
function! s:class_want_eq(parse, class, want) abort
  if a:want =~# '\\'
    let l:fqn = calltree#php#ClassFqn(a:parse, a:class)
    return l:fqn ==? substitute(a:want, '^\\', '', '')
  endif
  return a:class['name'] ==? a:want
endfunction

" Re-derive a definition from an item, so expanding a caller/callee node does
" not need any state carried on the item.
function! s:def_for_item(item) abort
  if empty(get(a:item, 'uri', ''))
    return {}
  endif
  let l:path = lsp#utils#uri_to_path(a:item['uri'])
  let l:parse = calltree#php#ParseFile(l:path)
  if empty(l:parse['lines'])
    return {}
  endif
  let l:start = get(get(a:item, 'selectionRange', {}), 'start', {})
  let l:lnum = get(l:start, 'line', -1)
  let l:name = get(a:item, 'name', '')
  for l:def in l:parse['defs']
    if l:def['name'] ==? l:name && l:def['name_line'] == l:lnum
      return {'parse': l:parse, 'def': l:def}
    endif
  endfor
  for l:def in l:parse['defs']
    if l:def['name'] ==? l:name
      return {'parse': l:parse, 'def': l:def}
    endif
  endfor
  return {}
endfunction

function! s:range(line, lnum, col, len) abort
  let l:char = calltree#php#Utf16Col(a:line, a:col)
  return {
        \ 'start': {'line': a:lnum, 'character': l:char},
        \ 'end': {'line': a:lnum, 'character': l:char + a:len},
        \ }
endfunction

" --- search ----------------------------------------------------------------

function! s:engine() abort
  let l:pref = calltree#cfg('php_engine', 'auto')
  if l:pref ==# 'rg' || l:pref ==# 'ag'
    return executable(l:pref) ? l:pref : ''
  endif
  if executable('rg')
    return 'rg'
  endif
  return executable('ag') ? 'ag' : ''
endfunction

function! s:cmd(engine, pattern, root, ignore) abort
  let l:ignore = calltree#cfg('php_ignore', ['vendor', 'node_modules'])
  if a:engine ==# 'rg'
    let l:cmd = ['rg', '--no-heading', '--line-number', '--color', 'never',
          \ '--no-messages', '--ignore-case', '--with-filename']
    for l:glob in calltree#cfg('php_globs', ['*.php', '*.phtml'])
      call extend(l:cmd, ['--glob', l:glob])
    endfor
    if a:ignore
      for l:dir in l:ignore
        call extend(l:cmd, ['--glob', '!' . l:dir . '/**'])
        call extend(l:cmd, ['--glob', '!**/' . l:dir . '/**'])
      endfor
    endif
    call extend(l:cmd, ['-e', a:pattern, a:root])
    return l:cmd
  endif
  let l:cmd = ['ag', '--nogroup', '--noheading', '--numbers', '--ignore-case',
        \ '--filename', '-G', '\.(php|phtml)$']
  if a:ignore
    for l:dir in l:ignore
      call extend(l:cmd, ['--ignore', l:dir])
    endfor
  endif
  " ag takes the pattern positionally, unlike rg's -e.
  call extend(l:cmd, [a:pattern, a:root])
  return l:cmd
endfunction

" Async rg/ag run.  Stops reading after `max` matching lines: that is the knob
" that keeps a common name in a large repo from freezing the tree.
" Cb receives (matches, meta); matches are {path, line, text}.
function! s:search(pattern, root, opts, Cb) abort
  let l:engine = s:engine()
  if empty(l:engine)
    return call(a:Cb, [[], {'overflow': 0,
          \ 'error': 'PHP search needs ripgrep (rg) or ag on $PATH'}])
  endif

  let l:state = {
        \ 'matches': [],
        \ 'count': 0,
        \ 'max': get(a:opts, 'max', calltree#cfg('php_max_results', 300)),
        \ 'overflow': 0,
        \ 'done': 0,
        \ 'job': v:null,
        \ 'timer': -1,
        \ 'Cb': a:Cb,
        \ }
  let l:state['job'] = job_start(
        \ s:cmd(l:engine, a:pattern, a:root, get(a:opts, 'ignore', 1)), {
        \ 'in_io': 'null',
        \ 'out_cb': function('s:on_out', [l:state]),
        \ 'err_cb': function('s:on_err', [l:state]),
        \ 'close_cb': function('s:on_close', [l:state]),
        \ })
  if job_status(l:state['job']) ==# 'fail'
    let l:state['done'] = 1
    return call(a:Cb, [[], {'overflow': 0,
          \ 'error': 'cannot run ' . l:engine}])
  endif
  if l:state['done']
    return
  endif
  let l:state['timer'] = timer_start(calltree#cfg('php_timeout', 15000),
        \ function('s:on_timeout', [l:state]))
endfunction

" With the default NL out_mode Vim hands us one complete line per callback
" (the trailing newline is stripped), so no line reassembly is needed.
function! s:on_out(state, channel, msg) abort
  if a:state['done']
    return
  endif
  for l:line in split(a:msg, "\n")
    call s:consume(a:state, l:line)
    if a:state['done']
      return
    endif
  endfor
endfunction

function! s:consume(state, line) abort
  if empty(a:line)
    return
  endif
  if a:state['count'] >= a:state['max']
    let a:state['overflow'] = 1
    return s:finish(a:state)
  endif
  let l:m = matchlist(a:line, '^\(.\{-}\):\(\d\+\):\(.*\)$')
  if empty(l:m)
    return
  endif
  call add(a:state['matches'], {
        \ 'path': l:m[1],
        \ 'line': str2nr(l:m[2]) - 1,
        \ 'text': l:m[3],
        \ })
  let a:state['count'] += 1
endfunction

function! s:on_err(state, channel, msg) abort
endfunction

function! s:on_close(state, channel) abort
  call s:finish(a:state)
endfunction

function! s:on_timeout(state, timer) abort
  if a:state['done']
    return
  endif
  let a:state['overflow'] = 1
  call s:finish(a:state)
endfunction

function! s:finish(state) abort
  if a:state['done']
    return
  endif
  let a:state['done'] = 1
  if a:state['timer'] != -1
    call timer_stop(a:state['timer'])
  endif
  if a:state['job'] isnot v:null && job_status(a:state['job']) ==# 'run'
    call job_stop(a:state['job'])
  endif
  call call(a:state['Cb'], [a:state['matches'],
        \ {'overflow': a:state['overflow']}])
endfunction
