" This file contains code used only on Windows

let s:sumatra_in_path = 0

let g:R_set_home_env = get(g:, "R_set_home_env", 1)
let g:R_i386 = get(g:, "R_i386", 0)

if exists('g:R_path')
    let s:rpath = split(g:R_path, ';')
    call map(s:rpath, 'expand(v:val)')
    call reverse(s:rpath)
    for s:dir in s:rpath
        if isdirectory(s:dir)
            let $PATH = s:dir . ';' . $PATH
        else
            call RWarningMsg('"' . s:dir . '" is not a directory. Fix the value of R_path in your vimrc.')
        endif
    endfor
    unlet s:rpath
    unlet s:dir
else
    " R installed by its own installer puts the bin directories of Rtools in
    " the PATH by itself, reading RTOOLS<version>_HOME and falling back to
    " the default installation directory. The code below does the same for
    " the cases in which R does not do it, and looks for whatever Rtools is
    " installed instead of naming one version, which is what made this code
    " dead when Rtools40 was superseded.
    let s:rtools = []
    let s:env = environ()
    for s:k in keys(s:env)
        if s:k =~? '^RTOOLS\d\+\%(_AARCH64\)\=_HOME$' && s:env[s:k] != ''
            let s:rtools += [[str2nr(matchstr(s:k, '\d\+')),
                        \ substitute(s:env[s:k], '[\\/]\+$', '', '')]]
        endif
    endfor
    for s:d in glob('C:\rtools*', 1, 1)
        let s:rtools += [[str2nr(matchstr(s:d, '\c\<rtools\zs\d\+')), s:d]]
    endfor
    " Newest Rtools first and, for the same version, the environment
    " variable before the default directory
    call sort(s:rtools, {x, y -> y[0] - x[0]})
    for [s:nr, s:rtdir] in s:rtools
        if isdirectory(s:rtdir . '\usr\bin')
            " The directory of the compilers is named after the CPU since
            " Rtools42 and was mingw64 in Rtools40
            let s:tc = glob(s:rtdir . '\*-w64-mingw32.static.posix\bin', 1, 1)
                        \ + glob(s:rtdir . '\mingw64\bin', 1, 1)
            let $PATH = s:rtdir . '\usr\bin;' . $PATH
            if len(s:tc)
                let $PATH = s:tc[0] . ';' . $PATH
            endif
            break
        endif
    endfor
    unlet! s:rtools s:env s:k s:d s:nr s:rtdir s:tc

    let s:reg_roots = ["HKLM", "HKCU"]
    for s:rr in s:reg_roots
        call writefile(['reg.exe QUERY "' . s:rr . '\SOFTWARE\R-core\R" /s'], g:rplugin.tmpdir . "/run_cmd.bat")
        let s:ripl = system(g:rplugin.tmpdir . "/run_cmd.bat")
        let s:rip = filter(split(s:ripl, "\n"), 'v:val =~ ".*InstallPath.*REG_SZ"')
        if len(s:rip) == 0
            " Normally, 32 bit applications access only 32 bit registry and...
            " We have to try again if the user has installed R only in the other architecture.
            if has("win64")
                call writefile(['reg.exe QUERY "' . s:rr . '\SOFTWARE\R-core\R" /s /reg:32'], g:rplugin.tmpdir . "/run_cmd.bat")
            else
                call writefile(['reg.exe QUERY "' . s:rr . '\SOFTWARE\R-core\R" /s /reg:64'], g:rplugin.tmpdir . "/run_cmd.bat")
            endif
            let s:ripl = system(g:rplugin.tmpdir . "/run_cmd.bat")
            let s:rip = filter(split(s:ripl, "\n"), 'v:val =~ ".*InstallPath.*REG_SZ"')
        endif
        if len(s:rip) > 0
            break
        endif
    endfor
    if len(s:rip) > 0
        let s:rinstallpath = substitute(s:rip[0], '.*InstallPath.*REG_SZ\s*', '', '')
        let s:rinstallpath = substitute(s:rinstallpath, '\n', '', 'g')
        let s:rinstallpath = substitute(s:rinstallpath, '\s*$', '', 'g')
    endif
    if !exists("s:rinstallpath")
        call RWarningMsg("Could not find R path in Windows Registry. If you have already installed R, please, set the value of 'R_path'.")
        let g:rplugin.failed = 1
        finish
    endif
    let hasR32 = isdirectory(s:rinstallpath . '\bin\i386')
    let hasR64 = isdirectory(s:rinstallpath . '\bin\x64')
    if hasR32 && !hasR64
        let g:R_i386 = 1
    endif
    if hasR64 && !hasR32
        let g:R_i386 = 0
    endif
    if hasR32 && g:R_i386
        let $PATH = s:rinstallpath . '\bin\i386;' . $PATH
    elseif hasR64 && g:R_i386 == 0
        let $PATH = s:rinstallpath . '\bin\x64;' . $PATH
    else
        let $PATH = s:rinstallpath . '\bin;' . $PATH
    endif
    unlet s:rinstallpath
endif

if !exists("g:R_args")
    if type(g:R_external_term) == v:t_number && g:R_external_term == 0
        let g:R_args = ["--no-save"]
    else
        let g:R_args = ["--sdi", "--no-save"]
    endif
endif

let g:R_R_window_title = "R Console"

function SetRHome()
    " R and Vim use different values for the $HOME variable.
    if g:R_set_home_env
        let s:saved_home = $HOME
        call writefile(['reg.exe QUERY "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v "Personal"'], g:rplugin.tmpdir . "/run_cmd.bat")
        let prs = system(g:rplugin.tmpdir . "/run_cmd.bat")
        if len(prs) > 0
            let prs = substitute(prs, '.*REG_SZ\s*', '', '')
            let prs = substitute(prs, '\n', '', 'g')
            let prs = substitute(prs, '\r', '', 'g')
            let prs = substitute(prs, '\s*$', '', 'g')
            let $HOME = prs
        endif
    endif
endfunction

function UnsetRHome()
    if exists("s:saved_home")
        let $HOME = s:saved_home
        unlet s:saved_home
    endif
endfunction

function StartR_Windows()
    if string(g:SendCmdToR) != "function('SendCmdToR_fake')"
        call JobStdin(g:rplugin.jobs["Server"], "81Check if R is running\n")
        return
    endif

    if g:rplugin.R =~? 'Rterm' && g:R_app =~? 'Rterm'
        call RWarningMsg('"R_app" cannot be "Rterm.exe". R will crash if you send any command.')
        sleep 200m
    endif

    let g:SendCmdToR = function('SendCmdToR_NotYet')

    call SetRHome()
    if has("nvim")
        call system("start " . g:rplugin.R . ' ' . join(g:R_args))
    else
        silent exe "!start " . g:rplugin.R . ' ' . join(g:R_args)
    endif
    call UnsetRHome()

    call WaitVimcomStart()
endfunction

function CleanVimAndStartR()
    call ClearRInfo()
    call StartR_Windows()
endfunction

function SendCmdToR_Windows(...)
    if g:R_clear_line
        let cmd = "\001" . "\013" . a:1 . "\n"
    else
        let cmd = a:1 . "\n"
    endif
    call JobStdin(g:rplugin.jobs["Server"], "83" . cmd)
    return 1
endfunction

call AddForDeletion(g:rplugin.tmpdir . "/run_cmd.bat")

" 2020-05-19
if exists("g:Rtools_path")
    call RWarningMsg('The variable "Rtools_path" is no longer used.')
endif
