#' Command sent to R console after `\rp`.
#' @param object Object under cursor.
#' @param firstobj If `object` is a function, the the first function parameter.
vim.print <- function(object, firstobj) {
    ns <- NULL
    name <- object
    # `exists("stats::lm")` is always false: resolve a namespaced name
    # against its package instead of the global environment.
    if (grepl(":::", object, fixed = TRUE)) {
        parts <- strsplit(object, ":::", fixed = TRUE)[[1L]]
        if (length(parts) == 2L) {
            ns <- asNamespace(parts[[1L]])
            name <- parts[[2L]]
        }
    } else if (grepl("::", object, fixed = TRUE)) {
        parts <- strsplit(object, "::", fixed = TRUE)[[1L]]
        if (length(parts) == 2L) {
            ns <- asNamespace(parts[[1L]])
            name <- parts[[2L]]
        }
    }

    found <- if (is.null(ns))
        exists(name)
    else
        exists(name, where = ns, inherits = FALSE)
    if (!found)
        stop("object '", object, "' not found")

    if (!missing(firstobj)) {
        objclass <- vim.getclass(firstobj)
        if (objclass[1] != "#E#" && objclass[1] != "") {
            saved.warn <- getOption("warn")
            options(warn = -1)
            on.exit(options(warn = saved.warn))
            mlen <- try(length(methods(name)), silent = TRUE)
            if (class(mlen)[1] == "integer" && mlen > 0) {
                # One class at a time: passing the whole vector makes
                # exists() raise "first argument has length > 1" on R 4.6.
                for (cls in objclass) {
                    method <- paste0(name, ".", cls)
                    has_method <- if (is.null(ns))
                        exists(method)
                    else
                        exists(method, where = ns, inherits = TRUE)
                    if (has_method) {
                        .newobj <- if (is.null(ns))
                            get(method)
                        else
                            get(method, envir = ns, inherits = TRUE)
                        message(paste0("Note: Printing ", name, ".", cls))
                        break
                    }
                }
            }
        }
    }
    if (!exists(".newobj"))
        .newobj <- if (is.null(ns))
            get(name)
        else
            get(name, envir = ns, inherits = FALSE)
    print(.newobj)
}
