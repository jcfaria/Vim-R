" Vim syntax file
" Language:	R (additions to the R syntax of Vim's own runtime)
" Maintainer:	José Cláudio Faria <joseclaudio.faria@gmail.com>

"==============================================================================
" Note comments: "#." is a note of level 1, "#.." of level 2, and "#..." (or
" more dots) of level 3
"==============================================================================
" These items must override rComment, which is defined by the runtime syntax
" script and matches "#.*". The three patterns are mutually exclusive, so the
" order in which they are defined is irrelevant.
syn match rNote1 contains=@Spell,rCommentTodo,rTodoParen "#\.\%(\.\)\@!.*"
syn match rNote2 contains=@Spell,rCommentTodo,rTodoParen "#\.\.\%(\.\)\@!.*"
syn match rNote3 contains=@Spell,rCommentTodo,rTodoParen "#\.\{3,}.*"

" Note_1, Note_2 and Note_3 are defined in R/note_hl.vim. They do not exist if
" R_note_hl is 0, and then the notes must look like any other comment.
if get(g:, "R_note_hl", 1)
    hi def link rNote1 Note_1
    hi def link rNote2 Note_2
    hi def link rNote3 Note_3
else
    hi def link rNote1 Comment
    hi def link rNote2 Comment
    hi def link rNote3 Comment
endif
