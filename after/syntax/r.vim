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

hi def link rNote1 SpecialComment
hi def link rNote2 Statement
hi def link rNote3 Error
