"==============================================================================
" The note comments "#.", "#.." and "#..." in file types that are not R's, such
" as plain text (see R_note_filetypes in the documentation).
"
" Nothing of the rest of Vim-R is loaded for these file types: neither the
" connection to R nor the completion, only R/note.vim and R/note_hl.vim. A
" title has to begin at the start of the line, so that a "#." in the middle of
" a sentence is left alone, and the section markers of RStudio, an R
" convention, are not titles.
"==============================================================================

if exists("g:did_vimr_notes")
    finish
endif
let g:did_vimr_notes = 1

let s:fts = get(g:, "R_note_filetypes", [])
if type(s:fts) == v:t_string
    let s:fts = [s:fts]
endif
" The R file types already have the notes, from after/syntax/r.vim and from
" the ftplugins of Vim-R.
call filter(s:fts, 'index(["r", "rmd", "quarto", "rnoweb", "rrst", "rhelp"], v:val) == -1')
if empty(s:fts)
    finish
endif
let g:R_note_filetypes = s:fts

let s:home = fnameescape(expand("<sfile>:p:h:h"))

function s:Syntax()
    syn match vimrNote1 contains=@Spell "^#\.\%(\.\)\@!.*"
    syn match vimrNote2 contains=@Spell "^#\.\.\%(\.\)\@!.*"
    syn match vimrNote3 contains=@Spell "^#\.\{3,}.*"
    " Note_1, Note_2 and Note_3 do not exist if R_note_hl is 0
    if get(g:, "R_note_hl", 1)
        hi def link vimrNote1 Note_1
        hi def link vimrNote2 Note_2
        hi def link vimrNote3 Note_3
    else
        hi def link vimrNote1 Comment
        hi def link vimrNote2 Comment
        hi def link vimrNote3 Comment
    endif
endfunction

" Like RCreateMaps() of common_global.vim, which is not sourced here
function s:Map(plug, combo, target)
    if index(get(g:, "R_disable_cmds", [""]), a:plug) > -1
        return
    endif
    exe 'noremap <buffer><silent> <Plug>' . a:plug . ' ' . a:target . '<CR>'
    " A '|' after ':unmap' would be taken as part of the {lhs}
    let b:undo_ftplugin .= " | exe 'silent! unmap <buffer> <Plug>" . a:plug . "'"
    if get(g:, "R_user_maps_only", 0) != 1 && !hasmapto('<Plug>' . a:plug, "n")
        exe 'noremap <buffer><silent> <LocalLeader>' . a:combo . ' ' . a:target . '<CR>'
        let b:undo_ftplugin .= " | exe 'silent! unmap <buffer> <LocalLeader>" . a:combo . "'"
    endif
endfunction

" Run after the file type plugin, whose b:undo_ftplugin is appended to and
" not replaced.
function s:Setup()
    exe "source " . s:home . "/R/note.vim"
    let b:rplugin_note_sections = 0
    if !exists("b:undo_ftplugin") || b:undo_ftplugin == ''
        let b:undo_ftplugin = 'unlet! b:rplugin_note_sections'
    else
        let b:undo_ftplugin .= ' | unlet! b:rplugin_note_sections'
    endif
    call s:Map('RNextNote',     'gs', ':call RNoteGoTo(1)')
    call s:Map('RPreviousNote', 'gS', ':call RNoteGoTo(-1)')
    call s:Map('RNoteOutline',  'go', ':call RNoteOutline()')
    call RNoteSetFolding()
endfunction

augroup VimRNotes
    autocmd!
    exe 'autocmd FileType ' . join(s:fts, ',') . ' call s:Setup()'
    exe 'autocmd Syntax ' . join(s:fts, ',') . ' call s:Syntax()'
augroup END
