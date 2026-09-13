" Vim filetype plugin file
" Language:	R (additions to the R filetype plugin of Vim's own runtime)
" Maintainer:	José Cláudio Faria <joseclaudio.faria@gmail.com>

" Vim's own ftplugin/r.vim assigns b:undo_ftplugin instead of appending to it,
" so the fold options can only be registered after it has been sourced. The
" function does not exist if Vim-R is not loaded for R files.
if exists("*RNoteSetFolding")
    call RNoteSetFolding()
endif
