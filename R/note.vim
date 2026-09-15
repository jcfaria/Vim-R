"==============================================================================
" Navigation through the note comments "#.", "#.." and "#..." and outline of
" their hierarchy (see after/syntax/r.vim).
"==============================================================================

" Level of a title: 1, 2 or 3, and 0 if the line is not a title. A title is a
" whole line, unlike the highlighting, which also marks a note written after
" code, because a fold and a jump can only begin at the start of a line.
function RNoteLevel(line)
    if a:line !~ '^#'
        return 0
    endif
    if a:line =~ '^#\.\{3,}'
        return 3
    elseif a:line =~ '^#\.\.'
        return 2
    elseif a:line =~ '^#\.'
        return 1
    elseif g:R_note_sections && a:line =~ '[-=#]\{4,}\s*$'
        return 1
    endif
    return 0
endfunction

" Title without its marker
function RNoteTitle(line)
    let ttl = substitute(a:line, '^#\.\+\s*', '', '')
    if ttl ==# a:line
        let ttl = substitute(substitute(a:line, '^#\+\s*', '', ''),
                    \ '\s*[-=#]\{4,}\s*$', '', '')
    endif
    return trim(ttl)
endfunction

" A count is the deepest level to stop at, so that 1<LocalLeader>gs walks the
" level 1 titles only, which is what serves a lecture. Note that in the chunk
" maps a count means "repeat"; the divergence is deliberate.
" The 'range' attribute is what keeps a count from calling the function once
" per line of the range that Vim builds out of it.
function RNoteGoTo(dir) range
    let maxlv = v:count > 0 ? v:count : 3
    let ln = line('.') + a:dir
    while ln >= 1 && ln <= line('$')
        if RNoteLevel(getline(ln)) > 0 && RNoteLevel(getline(ln)) <= maxlv
            call cursor(ln, 1)
            return
        endif
        let ln += a:dir
    endwhile
    call RWarningMsg('There is no ' . (a:dir > 0 ? 'next' : 'previous')
                \ . ' note to go.')
endfunction

" The quickfix window strips the leading whitespace of the 'text' field, so
" the indentation that shows the hierarchy has to be written by a
" 'quickfixtextfunc', which owns the whole line, including the line number.
function RNoteOutlineText(info)
    let items = getloclist(a:info.winid, {'id': a:info.id, 'items': 1}).items
    let lines = []
    for i in range(a:info.start_idx - 1, a:info.end_idx - 1)
        let lv = RNoteLevel(items[i].text)
        call add(lines, printf('%5d  %s%s', items[i].lnum,
                    \ repeat('    ', lv > 1 ? lv - 1 : 0),
                    \ RNoteTitle(items[i].text)))
    endfor
    return lines
endfunction

" The location list is window local, so the list of quickfix of the user is
" not clobbered, and the file name column would be redundant anyway.
function RNoteOutline()
    let items = []
    for ln in range(1, line('$'))
        if RNoteLevel(getline(ln)) > 0
            call add(items, {'bufnr': bufnr('%'), 'lnum': ln, 'col': 1,
                        \ 'text': trim(getline(ln))})
        endif
    endfor
    if len(items) == 0
        call RWarningMsg('There is no note in this buffer.')
        return
    endif
    let what = {'items': items, 'title': 'Notes in ' . expand('%:t')}
    if exists('&quickfixtextfunc')
        let what['quickfixtextfunc'] = 'RNoteOutlineText'
    endif
    call setloclist(0, [], ' ', what)
    lopen
endfunction

command RNoteOutline :call RNoteOutline()

"==============================================================================
" Folding by level
"==============================================================================

" The fold begins on the title line, which is what lets 'foldtext' show the
" title. Syntax regions would be cheaper, but the runtime's "syn sync
" minlines=40" makes them report the wrong level after an edit until
" ":syntax sync fromstart" runs, and a marker inside a block breaks the folds
" of {} that the runtime creates.
function RNoteFoldExpr(lnum)
    let lv = RNoteLevel(getline(a:lnum))
    return lv > 0 ? '>' . lv : '='
endfunction

" The default foldtext() drops the '#', which looks like a defect in a lecture
function RNoteFoldText()
    return substitute(getline(v:foldstart), '\s*$', '', '')
                \ . '  [' . (v:foldend - v:foldstart + 1) . ' lines]'
endfunction

" 'foldmethod' is seized only if it is still 'manual', which leaves alone a
" user who has a global 'foldmethod' or who folds with treesitter.
function RNoteSetFolding()
    if index(g:R_note_folding, &filetype) == -1
        return
    endif
    " The value is what matters, not the existence: the runtime's R syntax
    " script takes 'foldmethod' at "exists(...) && g:r_syntax_folding"
    " (syntax/r.vim), so a value of 0 leaves syntax folding off and there is
    " nothing to yield to. Testing only the existence used to leave whoever
    " disabled syntax folding by writing 0, instead of deleting the line,
    " with no folding at all.
    if exists("g:r_syntax_folding") && g:r_syntax_folding
        if !exists("s:said_syntax_folding")
            let s:said_syntax_folding = 1
            call RWarningMsg('R_note_folding is ignored because '
                        \ . 'g:r_syntax_folding is enabled. The two are '
                        \ . 'mutually exclusive. Please see Vim-R '
                        \ . 'documentation.')
        endif
        return
    endif
    if &l:foldmethod !=# 'manual'
        return
    endif
    setlocal foldmethod=expr
    setlocal foldexpr=RNoteFoldExpr(v:lnum)
    let undo = 'setlocal foldmethod< foldexpr<'
    if g:R_note_foldtext
        setlocal foldtext=RNoteFoldText()
        let undo .= ' foldtext<'
    endif
    if g:R_note_foldlevel >= 0
        let &l:foldlevel = g:R_note_foldlevel
        let undo .= ' foldlevel<'
    endif
    if exists("b:undo_ftplugin")
        let b:undo_ftplugin .= " | " . undo
    else
        let b:undo_ftplugin = undo
    endif
endfunction
