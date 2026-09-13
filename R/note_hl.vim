"==============================================================================
" Colors of the note comments "#.", "#.." and "#..." (see after/syntax/r.vim).
"
" The three levels are exposed as Note_1, Note_2 and Note_3, and their colors
" are computed from the colorscheme at runtime, because a "highlight link"
" would copy the attributes of the linked group too, and the levels have to
" differ by their own attributes (underline, bold, none).
"==============================================================================

let s:groups = ['Note_1', 'Note_2', 'Note_3']

" Highlighting written by Vim-R, and highlighting recognized as the user's
if !exists("s:mine")
    let s:mine = {}
endif
if !exists("s:userdef")
    let s:userdef = {}
endif

"==============================================================================
" Color arithmetic
"==============================================================================

function s:Hex2RGB(hex)
    let h = substitute(a:hex, '^#', '', '')
    return [str2nr(h[0:1], 16), str2nr(h[2:3], 16), str2nr(h[4:5], 16)]
endfunction

function s:Clamp(v, min, max)
    return a:v < a:min ? a:min : (a:v > a:max ? a:max : a:v)
endfunction

" Linear interpolation in RGB. Mixing in HSL would be useless for the gray
" Comment color of many colorschemes, whose hue is undefined.
function s:Mix(hex1, hex2, f)
    let c1 = s:Hex2RGB(a:hex1)
    let c2 = s:Hex2RGB(a:hex2)
    let rgb = []
    for i in [0, 1, 2]
        call add(rgb, s:Clamp(float2nr(round(c1[i] + (c2[i] - c1[i]) * a:f)), 0, 255))
    endfor
    return printf('#%02x%02x%02x', rgb[0], rgb[1], rgb[2])
endfunction

function s:Lum(hex)
    let l = []
    for c in s:Hex2RGB(a:hex)
        let s = c / 255.0
        call add(l, s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4))
    endfor
    return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
endfunction

function s:Contrast(hex1, hex2)
    let l1 = s:Lum(a:hex1)
    let l2 = s:Lum(a:hex2)
    return ((l1 > l2 ? l1 : l2) + 0.05) / ((l1 > l2 ? l2 : l1) + 0.05)
endfunction

"==============================================================================
" The xterm 256 color palette
"==============================================================================

let s:cube = [0, 95, 135, 175, 215, 255]
let s:ansi = ['#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee', '#cd00cd',
            \ '#00cdcd', '#e5e5e5', '#7f7f7f', '#ff0000', '#00ff00', '#ffff00',
            \ '#5c5cff', '#ff00ff', '#00ffff', '#ffffff']

function s:Cterm2Hex(n)
    let n = a:n + 0
    if n < 0 || n > 255
        return ''
    elseif n < 16
        return s:ansi[n]
    elseif n < 232
        let i = n - 16
        return printf('#%02x%02x%02x',
                    \ s:cube[i / 36], s:cube[(i / 6) % 6], s:cube[i % 6])
    endif
    let v = 8 + (n - 232) * 10
    return printf('#%02x%02x%02x', v, v, v)
endfunction

" The search is restricted to 16-255 because the terminal emulator may
" redefine the first sixteen entries of the palette.
function s:Hex2Cterm(hex)
    let t = s:Hex2RGB(a:hex)
    let best = -1
    let bestd = 1.0e30
    for n in range(16, 255)
        let c = s:Hex2RGB(s:Cterm2Hex(n))
        let d = 2.0 * pow(t[0] - c[0], 2) + 4.0 * pow(t[1] - c[1], 2)
                    \ + 3.0 * pow(t[2] - c[2], 2)
        if d < bestd
            let bestd = d
            let best = n
        endif
    endfor
    return best
endfunction

" Move a palette index along the axes of the 6x6x6 cube, which is the only way
" of keeping the hue: looking for the nearest RGB turns the navy #003460 of
" peachpuff into 23 (#005f5f, teal). f > 0 lightens, f < 0 darkens.
function s:CtermShift(idx, f)
    let n = a:idx + 0
    if n < 0
        return -1
    endif
    if n < 16
        " Only the terminal emulator knows the RGB of the first sixteen
        " entries, but the bright variant of an ANSI color is always n + 8.
        let alt = a:f > 0 ? (n < 8 ? n + 8 : n) : (n >= 8 ? n - 8 : n)
        return alt
    endif
    if n >= 232
        let g = n - 232
        let g2 = float2nr(round(g + (a:f > 0 ? (23 - g) : -g) * abs(a:f)))
        let res = 232 + s:Clamp(g2, 0, 23)
    else
        let i = n - 16
        let out = []
        for c in [i / 36, (i / 6) % 6, i % 6]
            let c2 = float2nr(round(c + (a:f > 0 ? (5 - c) : -c) * abs(a:f)))
            call add(out, s:Clamp(c2, 0, 5))
        endfor
        let res = 16 + out[0] * 36 + out[1] * 6 + out[2]
    endif
    " Saturated or very dark colors cannot move along the cube: force one step,
    " otherwise the three levels would share the same palette entry.
    if res == n
        let alt = a:f > 0 ? n + 1 : n - 1
        let res = (alt >= 16 && alt <= 255) ? alt : n
    endif
    return res
endfunction

" One step of the cube is sometimes too small to be seen (in peachpuff, 25 ->
" 24 is a contrast ratio of 1.09): insist until the two indexes are apart.
function s:CtermSep(idx, f)
    if a:idx < 0
        return -1
    endif
    let res = s:CtermShift(a:idx, a:f)
    let f = a:f
    let n = 0
    while n < 6 && res != a:idx
                \ && s:Contrast(s:Cterm2Hex(res), s:Cterm2Hex(a:idx)) < 1.35
        let f = f * 1.5
        let nxt = s:CtermShift(a:idx, f)
        if nxt == res
            break
        endif
        let res = nxt
        let n += 1
    endwhile
    return res
endfunction

"==============================================================================
" Reading the colorscheme
"==============================================================================

function s:NvimHl(name, what)
    if !has("nvim") || !exists("*nvim_get_hl")
        return -1
    endif
    let hl = nvim_get_hl(0, {'name': a:name, 'link': v:false})
    return has_key(hl, a:what) ? hl[a:what] + 0 : -1
endfunction

" Foreground of a group as [gui_hex, cterm_index], '' and -1 if not defined.
" Without 'termguicolors', the "gui" mode of synIDattr() is the only way of
" reading the gui color, and even then it may be a color name instead of a hex
" string, which only nvim_get_hl() resolves.
function s:Fg(name)
    let id = synIDtrans(hlID(a:name))
    if id == 0
        return ['', -1]
    endif
    let gui = ''
    let nfg = s:NvimHl(a:name, 'fg')
    if nfg >= 0
        let gui = printf('#%06x', nfg)
    else
        let v = synIDattr(id, 'fg#', 'gui')
        if v =~# '^#\x\{6}$'
            let gui = tolower(v)
        endif
    endif
    let cterm = s:NvimHl(a:name, 'ctermfg')
    if cterm < 0
        let v = synIDattr(id, 'fg', 'cterm')
        if v =~# '^\d\+$'
            let cterm = v + 0
        endif
    endif
    return [gui, cterm]
endfunction

" A hex string for a color that is only known as a palette index, and nothing
" for the first sixteen entries, whose RGB belongs to the terminal emulator
function s:Hex(gui, cterm)
    if a:gui != ''
        return a:gui
    endif
    return a:cterm >= 16 ? s:Cterm2Hex(a:cterm) : ''
endfunction

function s:NormalBg()
    let id = synIDtrans(hlID('Normal'))
    if id
        let nbg = s:NvimHl('Normal', 'bg')
        if nbg >= 0
            return printf('#%06x', nbg)
        endif
        let v = synIDattr(id, 'bg#', 'gui')
        if v =~# '^#\x\{6}$'
            return tolower(v)
        endif
        let v = synIDattr(id, 'bg', 'cterm')
        if v =~# '^\d\+$' && v + 0 >= 16
            return s:Cterm2Hex(v + 0)
        endif
    endif
    " Vim's 'default' colorscheme leaves Normal without any color
    return &background ==# 'dark' ? '#000000' : '#ffffff'
endfunction

function s:NormalFg()
    let [gui, cterm] = s:Fg('Normal')
    let hex = s:Hex(gui, cterm)
    return hex == '' ? (&background ==# 'dark' ? '#ffffff' : '#000000') : hex
endfunction

" Comment does not exist if the syntax is off, hence the fall back chain
function s:BaseFg()
    for g in [g:R_note_hl_base, 'Comment', 'Statement', 'Normal']
        let [gui, cterm] = s:Fg(g)
        if gui != '' || cterm >= 0
            return [gui, cterm, g]
        endif
    endfor
    return [&background ==# 'dark' ? '#a0a0a0' : '#505050', -1, 'builtin']
endfunction

"==============================================================================
" Ownership of the Note_* groups
"==============================================================================

function s:Body(name)
    if !hlexists(a:name)
        return ''
    endif
    let out = substitute(execute('highlight ' . a:name), '\n\s*', ' ', 'g')
    return trim(substitute(out, '^\s*\S\+\s\+xxx\s*', '', ''))
endfunction

" The output of ':highlight <group>' is already a valid argument list for
" ':highlight', except for the 'links to' form, which needs ':highlight link'.
function s:Restore(name, body)
    let link = matchstr(a:body, '\<links to \zs\S\+')
    if link != ''
        exe 'highlight! link ' . a:name . ' ' . link
    else
        exe 'highlight ' . a:name . ' ' . a:body
    endif
endfunction

" A group becomes the user's as soon as its definition differs from ours. This
" has to be able to run *before* ':colorscheme' clears every group, which is
" why it is also hooked on ColorSchemePre.
function s:Observe(...)
    for n in (a:0 ? a:000 : s:groups)
        let cur = s:Body(n)
        if cur != '' && cur !=# 'cleared'
                    \ && (!has_key(s:mine, n) || cur !=# s:mine[n])
            let s:userdef[n] = cur
        endif
    endfor
endfunction

function s:Set(name, args)
    call s:Observe(a:name)
    let cur = s:Body(a:name)
    let live = cur != '' && cur !=# 'cleared'
    if live && has_key(s:userdef, a:name) && cur ==# s:userdef[a:name]
        return has_key(s:mine, a:name) ? 'user-took-over' : 'user-kept'
    endif
    if has_key(s:userdef, a:name)
        " ':colorscheme' runs ':highlight clear', which deletes the user's
        " definition as well as ours. Put his back instead of replacing it.
        call s:Restore(a:name, s:userdef[a:name])
        return 'user-restored'
    endif
    exe 'highlight ' . a:name . ' ' . a:args
    let s:mine[a:name] = s:Body(a:name)
    return 'applied'
endfunction

"==============================================================================
" Applying the highlighting
"==============================================================================

function RNoteHlApply()
    if !g:R_note_hl
        return {}
    endif
    let bg = s:NormalBg()
    let nfg = s:NormalFg()
    let [gui, cterm, src] = s:BaseFg()
    " An explicit index of the 256 color palette is what the author of the
    " colorscheme chose; an index below 16 only names an entry whose RGB is
    " unknown, so the gui color, if there is one, is the better starting point.
    if cterm >= 16
        let cbase = cterm
    elseif gui != ''
        let cbase = s:Hex2Cterm(gui)
    else
        let cbase = cterm
    endif
    let gui = s:Hex(gui, cterm)

    " "Lighter" has to mean "less emphasis": in a dark colorscheme a lighter
    " color has *more* contrast and would stand out more than the level 1. The
    " ladder is therefore defined by the direction of Normal's foreground,
    " which is always the most legible color of the colorscheme.
    let strong = gui == '' ? '' : s:Mix(gui, nfg, g:R_note_hl_amount)
    let weak = gui == '' ? '' : s:Mix(gui, nfg, g:R_note_hl_amount3)
    let up = s:Lum(bg) < 0.35 ? 1 : -1
    let cs = s:CtermSep(cbase, up * g:R_note_hl_amount)
    let cw = s:CtermShift(cbase, up * g:R_note_hl_amount3)
    if cw == cs
        let cw = cbase
    endif

    let gs = strong == '' ? '' : ' guifg=' . strong
    let gw = weak == '' ? '' : ' guifg=' . weak
    let ps = cs < 0 ? '' : ' ctermfg=' . cs
    let pw = cw < 0 ? '' : ' ctermfg=' . cw
    " Nothing but the attributes is left on a terminal without colors
    let specs = {
                \ 'Note_1': 'term=bold,underline cterm=bold,underline gui=bold,underline' . gs . ps,
                \ 'Note_2': 'term=bold cterm=bold gui=bold' . gs . ps,
                \ 'Note_3': 'term=NONE cterm=' . (cs == cw ? 'italic' : 'NONE')
                \           . ' gui=NONE' . gw . pw}

    let res = {}
    for [k, v] in items(specs)
        let res[k] = s:Set(k, v)
    endfor
    let g:rplugin.note_hl = {'base': src, 'bg': bg, 'normal_fg': nfg,
                \ 'fg_1': strong, 'fg_3': weak, 'ctermfg_base': cbase,
                \ 'ctermfg_1': cs, 'ctermfg_3': cw, 'status': res}
    return res
endfunction

" Hand a group back to Vim-R after having redefined it
function RNoteHlReset(...)
    for n in (a:0 ? a:000 : s:groups)
        if has_key(s:userdef, n)
            unlet s:userdef[n]
        endif
        if has_key(s:mine, n)
            unlet s:mine[n]
        endif
        exe 'highlight clear ' . n
    endfor
    return RNoteHlApply()
endfunction

augroup VimRNoteHl
    autocmd!
    " ':colorscheme' runs ':highlight clear' before triggering ColorScheme, so
    " by then the user's own ':hi Note_1' is already gone: note it before.
    if exists("##ColorSchemePre")
        autocmd ColorSchemePre * call s:Observe()
    endif
    autocmd ColorScheme * call RNoteHlApply()
    " Comment gets its color only when the syntax is enabled
    autocmd Syntax r,rmd,quarto,rnoweb,rrst,rhelp call RNoteHlApply()
    " ':set background' triggers ColorScheme only if a colorscheme was loaded
    autocmd OptionSet background call RNoteHlApply()
augroup END

call RNoteHlApply()
