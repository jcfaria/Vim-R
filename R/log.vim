" Optional, per-channel diagnostic logging to w_log/, for tracking down
" bugs in a plugin that spans Vim, R and two C processes. Off by default:
" nothing is written to disk unless a channel is explicitly enabled, so a
" release build behaves exactly as if this file did not exist. See
" |Vim-R-logging| and w_log/README.md (created the first time any channel
" is enabled).
"
" g:R_log_channels is a List of channel-name strings, e.g.:
"   let g:R_log_channels = ['objbr', 'latex']
" Each enabled channel writes timestamped lines to w_log/<channel>.log.
" The R and C sides of the plugin log to the same files: enabling a
" channel here also exports VIMR_LOG_CHANNELS and VIMR_LOG_DIR to R and to
" vimrserver when they are started (see R/start_server.vim).

if !exists('g:R_log_channels')
    let g:R_log_channels = []
endif

function RLogDir()
    return g:rplugin.home . '/w_log'
endfunction

function RLogEnabled(channel)
    return exists('g:R_log_channels') && index(g:R_log_channels, a:channel) >= 0
endfunction

" Append one line to w_log/<channel>.log. A no-op unless a:channel is in
" g:R_log_channels, so callers do not need to guard every call site.
function RLog(channel, msg)
    if !RLogEnabled(a:channel)
        return
    endif
    let dir = RLogDir()
    if !isdirectory(dir)
        call mkdir(dir, 'p')
        let readme =<< trim END
            # Vim-R diagnostic logs

            Untracked scratch, like w_todo/: never commit this directory.
            Each file is one channel enabled through g:R_log_channels; the
            default (empty list) means this directory stays empty. Lines are
            tagged by where they came from: [vim:chan], [r:chan] or [c:chan].
        END
        call writefile(readme, dir . '/README.md')
    endif
    let line = strftime('%Y-%m-%dT%H:%M:%S') . ' [vim:' . a:channel . '] ' . a:msg
    call writefile([line], dir . '/' . a:channel . '.log', 'a')
endfunction
