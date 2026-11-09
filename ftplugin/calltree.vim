" Buffer-local mappings and the preview autocommand are installed here so
" that a late 'runtimepath' addition still gets them; the work lives in
" autoload/calltree/view.vim so both entry points share one definition.
call calltree#view#InitMaps()
