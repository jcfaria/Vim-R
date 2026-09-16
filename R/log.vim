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

" Central, documented registry of every channel this plugin actually logs
" to, so a human can discover and manage them with :RLogChannels instead
" of grepping the source for every RLog()/vimr_log()/Log() call site. Add
" an entry here whenever a new one is instrumented. "smoketest" is
" deliberately not listed: it exists only for test/smoke_test.sh's own
" unit test, driven directly through Rscript, not meant for a human to
" toggle.
" Built with one statement per entry so adding a new channel is always a
" one-line change.
if !exists('g:R_log_known_channels')
    let g:R_log_known_channels = {}
    let g:R_log_known_channels['vimrserver'] = 'vimrserver.c: TCP protocol, thread and job-control internals'
endif

function RLogChannelComplete(ArgLead, CmdLine, CursorPos)
    return filter(sort(keys(g:R_log_known_channels)),
                \ 'v:val =~ "^" . a:ArgLead')
endfunction

" :RLogChannels -- list every known channel with its description and
" whether it is currently in g:R_log_channels.
function RLogListChannels()
    if empty(g:R_log_known_channels)
        echo 'No log channels are registered.'
        return
    endif
    for chan in sort(keys(g:R_log_known_channels))
        let status = RLogEnabled(chan) ? 'on ' : 'off'
        echo printf('%-12s %s  %s', chan, status, g:R_log_known_channels[chan])
    endfor
endfunction

" :RLogEnable {channel} -- add a known channel to g:R_log_channels.
" Rejects an unlisted name instead of silently accepting a typo.
function RLogEnableChannel(channel)
    if !has_key(g:R_log_known_channels, a:channel)
        call RWarningMsg('Unknown log channel "' . a:channel . '". Known: ' .
                    \ join(sort(keys(g:R_log_known_channels)), ', '))
        return
    endif
    if index(g:R_log_channels, a:channel) < 0
        call add(g:R_log_channels, a:channel)
    endif
    echo 'Channel "' . a:channel .
                \ '" enabled. Restart R (and vimrserver) for it to take effect.'
endfunction

" :RLogDisable {channel} -- remove a channel from g:R_log_channels.
function RLogDisableChannel(channel)
    call filter(g:R_log_channels, 'v:val != a:channel')
    echo 'Channel "' . a:channel .
                \ '" disabled. Restart R (and vimrserver) for it to take effect.'
endfunction

command! -nargs=0 RLogChannels call RLogListChannels()
command! -nargs=1 -complete=customlist,RLogChannelComplete RLogEnable
            \ call RLogEnableChannel(<q-args>)
command! -nargs=1 -complete=customlist,RLogChannelComplete RLogDisable
            \ call RLogDisableChannel(<q-args>)
