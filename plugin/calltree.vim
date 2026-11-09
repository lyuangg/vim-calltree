" vim-calltree: LSP call hierarchy tree view for Vim (vim-lsp backend).
if exists('g:loaded_calltree')
  finish
endif
let g:loaded_calltree = 1

let s:sid = expand('<SID>')

function! s:define_highlights() abort
  call calltree#view#InitHighlights()
endfunction

augroup calltree_highlights
  autocmd!
  execute 'autocmd ColorScheme * call ' . s:sid . 'define_highlights()'
  execute 'autocmd OptionSet background call ' . s:sid . 'define_highlights()'
augroup END

call s:define_highlights()

augroup calltree_resize
  autocmd!
  autocmd VimResized * call calltree#view#Resize()
augroup END

command! -nargs=0 CallTree        call calltree#open('both')
command! -nargs=0 CallTreeCallers call calltree#open('in')
command! -nargs=0 CallTreeCallees call calltree#open('out')
command! -nargs=0 CallTreeExpand  call calltree#action#expand_level()
command! -nargs=0 CallTreeRefresh call calltree#refresh()
command! -nargs=0 CallTreeQF      call calltree#action#quickfix()
command! -nargs=0 CallTreeClose   call calltree#action#close()
