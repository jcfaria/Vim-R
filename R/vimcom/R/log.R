#' Optional, per-channel diagnostic logging to w_log/, mirroring R/log.vim
#' on the Vim side. Off by default: vimcom.log_channels is unset unless
#' Vim-R's g:R_log_channels is non-empty, and vimr_log() then does nothing.
#' @param channel Channel name, e.g. "objbr".
#' @param msg Message to append to w_log/<channel>.log.
vimr_log <- function(channel, msg) {
    chans <- getOption("vimcom.log_channels", "")
    if (!nzchar(chans))
        return(invisible(NULL))
    chans <- strsplit(chans, ",", fixed = TRUE)[[1L]]
    if (!(channel %in% chans))
        return(invisible(NULL))
    dir <- getOption("vimcom.log_dir", "")
    if (!nzchar(dir))
        return(invisible(NULL))
    if (!dir.exists(dir))
        dir.create(dir, recursive = TRUE)
    line <- paste0(format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
                   " [r:", channel, "] ", msg, "\n")
    cat(line, file = file.path(dir, paste0(channel, ".log")), append = TRUE)
    invisible(NULL)
}
