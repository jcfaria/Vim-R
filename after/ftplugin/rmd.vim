" Vim filetype plugin file
" Language:	R Markdown (additions to the R Markdown filetype plugin of Vim's own runtime)
" Maintainer:	José Cláudio Faria <joseclaudio.faria@gmail.com>

" Sourced after the runtime's ftplugin, whose b:undo_ftplugin is then
" appended to. The function does not exist if Vim-R is not loaded.
if exists("*RNoteSetFolding")
    call RNoteSetFolding()
endif
