#' exists(), resolved against a package namespace when `ns` is given instead
#' of the global environment (`exists("stats::lm")` is always false).
#' `bare_inherits`/`ns_inherits` default to what a plain object lookup and a
#' namespaced lookup each need; callers doing method dispatch override
#' `ns_inherits` to search up from the namespace.
ns_exists <- function(name, ns, bare_inherits = TRUE, ns_inherits = FALSE) {
    if (is.null(ns))
        exists(name, inherits = bare_inherits)
    else
        exists(name, where = ns, inherits = ns_inherits)
}

#' get(), with the same namespace resolution as ns_exists().
ns_get <- function(name, ns, bare_inherits = TRUE, ns_inherits = FALSE) {
    if (is.null(ns))
        get(name, inherits = bare_inherits)
    else
        get(name, envir = ns, inherits = ns_inherits)
}

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

    if (!ns_exists(name, ns))
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
                    if (ns_exists(method, ns, ns_inherits = TRUE)) {
                        .newobj <- ns_get(method, ns, ns_inherits = TRUE)
                        message(paste0("Note: Printing ", name, ".", cls))
                        break
                    }
                }
            }
        }
    }
    if (!exists(".newobj"))
        .newobj <- ns_get(name, ns)
    print(.newobj)
}
