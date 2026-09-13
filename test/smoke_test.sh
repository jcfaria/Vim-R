#!/usr/bin/env bash
#==============================================================================
# Vim-R end-to-end smoke test (Vim and Neovim)
#
# What it does, for each editor:
#
#   1. starts the editor in a detached Tmux session, with the plugin loaded
#      from this repository and nothing else,
#   2. starts R in the editor's built-in terminal (<LocalLeader>rf),
#   3. sends the test script to R (<LocalLeader>aa),
#   4. opens the Object Browser (<LocalLeader>ro),
#   5. asserts on the *contents* of the R Console buffer and of the
#      Object_Browser buffer,
#   6. weaves an Rnw file (<LocalLeader>kp), renders an Rmd file and renders a
#      qmd file, and asserts on the command the plugin sent to R, on the file
#      that R produced and, for the Rnw file, on the arguments with which
#      SyncTeX forward search invokes the PDF viewer,
#   7. asserts that Quarto chunk-option completion is populated from quarto's
#      yaml-intelligence-resources.json, which the test locates itself and
#      hands to the plugin through R_quarto_intel.
#
# Steps 3-7 are the point of the test: they only succeed if the whole chain
# vimcom -> vimrserver -> editor is alive. An editor that starts and does
# nothing fails.
#
# What it deliberately does NOT test: opening the PDF in a viewer, raising the
# viewer's window, and reverse SyncTeX. Those paths have known defects that are
# the same in both editors, so a failure there would say nothing about the
# editor. Step 6 asserts the *invocation* of the forward search, not its
# effect.
#
# How to run it:
#
#   ./test/smoke_test.sh            # from anywhere; no arguments
#
# Set VIMR_SMOKE_KEEP=1 to keep the scratch directory for inspection.
# Set VIMR_SMOKE_QUARTO_INTEL=/path/to/yaml-intelligence-resources.json to
# point the test at a Quarto installation it cannot find by itself.
#
# Exit status is 0 only if every assertion passed in *both* editors. Assertions
# whose external tool is missing are reported as SKIP; a SKIP is never counted
# as a PASS, and the number of skips is printed in the verdict.
#
# Requirements: bash, tmux, R (with a C compiler), vim, nvim.
# Optional, detected at run time: latexmk and xelatex (Rnw), pandoc and the
# rmarkdown package (Rmd), the quarto command and the quarto package (qmd),
# and quarto's editor/tools/yaml/yaml-intelligence-resources.json (completion).
#
# Isolation guarantees (see also check_isolation below):
#
#   * $HOME, the XDG directories and $TMPDIR are redirected to a scratch
#     directory under /tmp, so the user's vimrc, ~/.config/nvim, ~/.Rprofile
#     and ~/.cache/Vim-R are never read nor written.
#   * $R_LIBS_USER points to a fresh, empty library under /tmp. The script
#     refuses to run unless that directory exists *and* R reports it as
#     .libPaths()[1]; otherwise an install would silently land in the real
#     library. The real libraries are fingerprinted before and after the run
#     and the test fails if any of them changed.
#   * The user's real libraries are appended to the *end* of .libPaths() by a
#     scratch Rprofile, so that knitr, rmarkdown and quarto can be loaded from
#     them. They are only ever read: .libPaths()[1] is the scratch library, so
#     that is where any install would go, and the fingerprint covers every
#     file of every real library, not just vimcom.
#   * vimcom is installed from a *copy* of R/vimcom, so no build artifact is
#     ever written into the repository.
#   * Tmux runs on a private socket with unique session names, so the user's
#     sessions (e.g. "main") are never touched. The private server is killed
#     on exit, including on failure.
#==============================================================================

set -u -o pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK="vimr-smoke-$$"
WORK=""
FAILURES=0
SKIPS=0

# ---------------------------------------------------------------- reporting --

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }
head1()  { printf '\n== %s ==\n' "$*"; }

pass() { green  "  PASS  $*"; }
fail() { red    "  FAIL  $*"; FAILURES=$((FAILURES + 1)); }
skip() { yellow "  SKIP  $*"; SKIPS=$((SKIPS + 1)); }

die() { red "ABORT: $*"; exit 2; }

cleanup() {
    tmux -L "$SOCK" kill-server >/dev/null 2>&1
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        if [ -n "${VIMR_SMOKE_KEEP:-}" ]; then
            info "scratch directory kept: $WORK"
        else
            rm -rf "$WORK"
        fi
    fi
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------- dependencies --

for dep in tmux R Rscript vim nvim; do
    command -v "$dep" >/dev/null 2>&1 || die "$dep not found in \$PATH"
done

head1 "Environment"
info "repository:  $REPO"
info "vim:         $(vim --version | head -1)"
info "nvim:        $(nvim --version | head -1)"
info "R:           $(R --version | head -1)"
info "tmux:        $(tmux -V)"

# --------------------------------------------------- real R library snapshot --

# Taken *before* any environment variable is overridden.
mapfile -t REAL_LIBS < <(Rscript -e 'cat(.libPaths(), sep="\n")' 2>/dev/null)
[ "${#REAL_LIBS[@]}" -gt 0 ] || die "could not read .libPaths() from R"

# Every file of every real library is fingerprinted, not just vimcom: the run
# makes those libraries readable, so anything that changed in them has to be
# noticed.
fingerprint_real_libs() {
    local lib
    for lib in "${REAL_LIBS[@]}"; do
        if [ -d "$lib" ]; then
            printf '%s\t%s\n' "$lib" \
                "$(find "$lib" -printf '%P %s %T@\n' 2>/dev/null |
                   sort | sha256sum | cut -d' ' -f1)"
        else
            printf '%s\tABSENT\n' "$lib"
        fi
    done
}

REAL_LIBS_BEFORE="$(fingerprint_real_libs)"

# ------------------------------------------------------------ scratch layout --

WORK="$(mktemp -d /tmp/vimr-smoke.XXXXXXXX)" || die "mktemp failed"
FAKE_HOME="$WORK/home"
R_LIB="$WORK/Rlib"
OUT="$WORK/out"
mkdir -p "$FAKE_HOME" "$R_LIB" "$OUT" "$WORK/tmp" \
         "$FAKE_HOME/.config" "$FAKE_HOME/.local/share" \
         "$FAKE_HOME/.local/state" "$FAKE_HOME/.cache"

mkdir -p "$WORK/run" && chmod 700 "$WORK/run"

export HOME="$FAKE_HOME"
export XDG_CONFIG_HOME="$FAKE_HOME/.config"
export XDG_DATA_HOME="$FAKE_HOME/.local/share"
export XDG_STATE_HOME="$FAKE_HOME/.local/state"
export XDG_CACHE_HOME="$FAKE_HOME/.cache"
export XDG_RUNTIME_DIR="$WORK/run"
export NVIM_LOG_FILE="$WORK/nvim.log"
export TMPDIR="$WORK/tmp"
export R_LIBS_USER="$R_LIB"
export R_PROFILE_USER="$WORK/Rprofile"  # ignore the user's ~/.Rprofile
unset R_LIBS R_LIBS_SITE R_ENVIRON_USER 2>/dev/null || true

# The only thing the scratch Rprofile does is make the user's libraries
# readable, *after* the scratch library, so that knitr, rmarkdown and quarto
# can be loaded without being reinstalled. R_LIBS cannot be used for this: it
# takes precedence over R_LIBS_USER, which would make the real library
# .libPaths()[1] and turn it into the target of any install.
{
    printf '%s\n' 'local({'
    printf '    ro <- c(\n'
    for lib in "${REAL_LIBS[@]}"; do
        printf '        "%s",\n' "$lib"
    done
    printf '        NULL)\n'
    printf '%s\n' '    .libPaths(c(.libPaths(), ro))'
    printf '%s\n' '})'
} > "$WORK/Rprofile"

info "scratch dir: $WORK"

# ---------------------------------------------------------------- isolation --

check_isolation() {
    head1 "Isolation checks"

    case "$R_LIBS_USER" in
        /tmp/vimr-smoke.*) ;;
        *) die "R_LIBS_USER ($R_LIBS_USER) is not under /tmp/vimr-smoke.*" ;;
    esac
    pass "R_LIBS_USER is a scratch directory under /tmp"

    local lib
    for lib in "${REAL_LIBS[@]}"; do
        if [ "$lib" = "$R_LIBS_USER" ]; then
            die "R_LIBS_USER collides with a real library ($lib)"
        fi
    done
    pass "R_LIBS_USER does not collide with any real library"

    [ -d "$R_LIBS_USER" ] || die "R_LIBS_USER does not exist"
    # R only prepends R_LIBS_USER to .libPaths() if the directory exists. If
    # this check is skipped, a failing install lands in the real library --
    # which is how a previous run destroyed the user's installed vimcom.
    local first
    first="$(Rscript -e 'cat(.libPaths()[1])' 2>/dev/null)"
    if [ "$first" != "$R_LIBS_USER" ]; then
        die ".libPaths()[1] is '$first', expected '$R_LIBS_USER'"
    fi
    pass ".libPaths()[1] is the scratch library"

    if tmux -L "$SOCK" has-session -t main 2>/dev/null; then
        die "unexpected session 'main' on the private Tmux socket"
    fi
    pass "Tmux runs on the private socket '$SOCK'"
}

check_isolation

# ------------------------------------------------------------ install vimcom --

head1 "Installing vimcom into the scratch library"
cp -r "$REPO/R/vimcom" "$WORK/vimcom-src" || die "could not copy R/vimcom"
if ! R CMD INSTALL --library="$R_LIB" "$WORK/vimcom-src" \
        > "$OUT/install.log" 2>&1; then
    tail -30 "$OUT/install.log"
    die "R CMD INSTALL of vimcom failed (see above)"
fi
[ -d "$R_LIB/vimcom" ] || die "vimcom not found in the scratch library"
VIMCOM_VERSION="$(sed -n 's/^Version: //p' "$REPO/R/vimcom/DESCRIPTION")"
pass "vimcom $VIMCOM_VERSION installed in $R_LIB"

# The real libraries are readable now, and one of them holds the user's own
# vimcom. before_nrs.R aborts if it finds more than one, so make sure the
# scratch copy is the one that wins.
FOUND_VIMCOM="$(Rscript -e 'cat(find.package("vimcom", quiet = TRUE))' 2>/dev/null)"
if [ "$FOUND_VIMCOM" = "$R_LIB/vimcom" ]; then
    pass "find.package(\"vimcom\") resolves inside the scratch library"
else
    die "find.package(\"vimcom\") is '$FOUND_VIMCOM', expected '$R_LIB/vimcom'"
fi

# ----------------------------------------------------------------- toolchain --

# Everything below is optional: what is missing makes an assertion SKIP.

has_r_pkg() {
    [ "$(Rscript -e "cat(requireNamespace('$1', quietly = TRUE))" 2>/dev/null)" \
      = "TRUE" ]
}

find_quarto_intel() {
    local rel='share/editor/tools/yaml/yaml-intelligence-resources.json'
    if [ -n "${VIMR_SMOKE_QUARTO_INTEL:-}" ]; then
        [ -f "$VIMR_SMOKE_QUARTO_INTEL" ] &&
            { printf '%s' "$VIMR_SMOKE_QUARTO_INTEL"; return 0; }
        return 1
    fi
    command -v quarto >/dev/null 2>&1 || return 1
    local qb d
    qb="$(command -v quarto)"
    for d in "$(dirname "$(dirname "$(readlink -f "$qb")")")" \
             "$(dirname "$(dirname "$qb")")"; do
        [ -f "$d/$rel" ] && { printf '%s' "$d/$rel"; return 0; }
    done
    return 1
}

head1 "Optional toolchain"

HAVE_RNW=1; WHY_RNW=""
for t in latexmk xelatex; do
    command -v "$t" >/dev/null 2>&1 ||
        { HAVE_RNW=0; WHY_RNW="$t not found in \$PATH"; }
done
if [ "$HAVE_RNW" -eq 1 ] && ! has_r_pkg knitr; then
    HAVE_RNW=0; WHY_RNW="the R package 'knitr' is not installed"
fi

HAVE_RMD=1; WHY_RMD=""
if ! has_r_pkg rmarkdown; then
    HAVE_RMD=0; WHY_RMD="the R package 'rmarkdown' is not installed"
elif [ "$(Rscript -e 'cat(rmarkdown::pandoc_available())' 2>/dev/null)" != "TRUE" ]; then
    HAVE_RMD=0; WHY_RMD="pandoc is not available to rmarkdown"
fi

HAVE_QMD=1; WHY_QMD=""
if ! command -v quarto >/dev/null 2>&1; then
    HAVE_QMD=0; WHY_QMD="the 'quarto' command is not in \$PATH"
elif ! has_r_pkg quarto; then
    HAVE_QMD=0; WHY_QMD="the R package 'quarto' is not installed"
fi

QUARTO_INTEL="$(find_quarto_intel || true)"

printf '  %-22s %s\n' "Rnw -> pdf:" \
    "$([ "$HAVE_RNW" -eq 1 ] && echo "available ($(latexmk --version 2>/dev/null | head -1))" || echo "SKIP: $WHY_RNW")"
printf '  %-22s %s\n' "Rmd -> html:" \
    "$([ "$HAVE_RMD" -eq 1 ] && echo "available (pandoc $(pandoc --version 2>/dev/null | head -1 | awk '{print $2}'))" || echo "SKIP: $WHY_RMD")"
printf '  %-22s %s\n' "qmd -> html:" \
    "$([ "$HAVE_QMD" -eq 1 ] && echo "available (quarto $(quarto --version 2>/dev/null))" || echo "SKIP: $WHY_QMD")"
printf '  %-22s %s\n' "Quarto completion:" \
    "$([ -n "$QUARTO_INTEL" ] && echo "$QUARTO_INTEL" || echo "SKIP: yaml-intelligence-resources.json not found")"

# ------------------------------------------------------------------ fixtures --

# Written into a per-editor directory, so that a file produced by the first
# editor can never be mistaken for a file produced by the second.
make_fixtures() { # make_fixtures <dir>
    local d="$1"
    mkdir -p "$d"

    cat > "$d/smoke.R" <<'EOF'
cat("VIMR_SMOKE_SUM:", sum(1:100), "\n")
smoke_df <- data.frame(alpha = 1:3, beta = c("x", "y", "z"))
smoke_chr <- "VIMR_SMOKE_CHR"
EOF

    cat > "$d/smoke_rnw.Rnw" <<'EOF'
\documentclass{article}
\begin{document}

\section{Vim-R smoke test}

<<smoke-chunk>>=
cat("VIMR_SMOKE_RNW_CHUNK:", 6 * 7, "\n")
@

Some text before the target.

VIMRSMOKESYNCTEXTARGET is on this line and nowhere else.

Some text after the target.

\end{document}
EOF

    cat > "$d/smoke_rmd.Rmd" <<'EOF'
---
title: "Vim-R smoke test"
---

```{r}
cat("VIMR_SMOKE_RMD_CHUNK:", 6 * 7, "\n")
```

VIMRSMOKERMDTEXT.
EOF

    cat > "$d/smoke_qmd.qmd" <<'EOF'
---
title: "Vim-R smoke test"
format: html
---

```{r}
#| label: smoke
cat("VIMR_SMOKE_QMD_CHUNK:", 6 * 7, "\n")
```

VIMRSMOKEQMDTEXT.
EOF
}

# The line the SyncTeX assertion jumps from. Taken from the fixture itself, so
# that editing the fixture cannot silently invalidate the assertion.
make_fixtures "$WORK/fixtures"
SYNCTEX_RNW_LINE="$(grep -n 'VIMRSMOKESYNCTEXTARGET' \
    "$WORK/fixtures/smoke_rnw.Rnw" | cut -d: -f1)"
[ -n "$SYNCTEX_RNW_LINE" ] || die "could not find the SyncTeX marker in the fixture"
info "SyncTeX marker is on line $SYNCTEX_RNW_LINE of smoke_rnw.Rnw"

# ------------------------------------------------------------ editor config --

# Minimal editor configuration: only this repository, no swap/undo/shada
# files, no user configuration. No document is ever handed to a viewer:
# R_openpdf and R_openhtml are 0, and ROpenDoc is replaced by a recorder.
cat > "$WORK/rc.vim" <<EOF
set nocompatible
set noswapfile nobackup nowritebackup noundofile
set shortmess+=A
set runtimepath^=$REPO
set runtimepath+=$REPO/after
syntax on
filetype plugin indent on
let R_auto_start = 0
let R_objbr_auto_start = 0
let R_external_term = 0
let R_wait = 60
let R_openpdf = 0
let R_openhtml = 0
$(if [ -n "$QUARTO_INTEL" ]; then
    # Point the completion at the resource the harness found, instead of
    # letting the plugin look for it with system('which quarto'). What is
    # under test here is that the resource is read and turned into completion
    # candidates, in both editors; making that depend on a shell call would
    # make the gate flaky.
    printf "let R_quarto_intel = '%s'" "$QUARTO_INTEL"
fi)

" Move to a window that is not the R Console: an ex command such as :edit
" cannot run in a terminal buffer whose job is alive.
function! SmokeGoToEditorWin()
    let l:rb = get(g:rplugin, 'R_bufnr', -1)
    for l:w in range(1, winnr('\$'))
        if winbufnr(l:w) != l:rb
            exe l:w . 'wincmd w'
            return
        endif
    endfor
endfunction
EOF

make_wrapper() { # make_wrapper <name> <proj-dir> <editor-command...>
    local name="$1" proj="$2"; shift 2
    cat > "$WORK/run_$name.sh" <<EOF
#!/usr/bin/env bash
export HOME='$HOME'
export XDG_CONFIG_HOME='$XDG_CONFIG_HOME'
export XDG_DATA_HOME='$XDG_DATA_HOME'
export XDG_STATE_HOME='$XDG_STATE_HOME'
export XDG_CACHE_HOME='$XDG_CACHE_HOME'
export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'
export NVIM_LOG_FILE='$NVIM_LOG_FILE'
export TMPDIR='$TMPDIR'
export R_LIBS_USER='$R_LIBS_USER'
export R_PROFILE_USER='$R_PROFILE_USER'
cd '$proj' || exit 1
exec $* 'smoke.R'
EOF
    chmod +x "$WORK/run_$name.sh"
}

# Sourced repeatedly to copy the editor's state out to files. Everything the
# assertions look at comes from here or from the recorders in act_hooks.vim.
cat > "$WORK/dump.vim" <<EOF
let s:o = '$OUT/'
call writefile([string(exists('g:rplugin'))], s:o . 'loaded')
if exists('g:rplugin')
    call writefile([string(get(g:rplugin, 'nrs_running', 0))], s:o . 'server')
    call writefile([string(get(g:rplugin, 'R_pid', -1))], s:o . 'r_pid')
endif
" g:SendCmdToR is SendCmdToR_fake before R starts and SendCmdToR_NotYet until
" vimcom connects; anything else means the plugin can talk to R.
if exists('g:SendCmdToR')
    call writefile([string(string(g:SendCmdToR) !~# 'fake\\|NotYet')],
                \\ s:o . 'ready')
endif
if exists('g:rplugin') && has_key(g:rplugin, 'R_bufnr')
    let s:l = getbufline(g:rplugin.R_bufnr, 1, '\$')
    if len(s:l) == 0 && exists('*term_getline')
        let s:l = map(range(1, term_getsize(g:rplugin.R_bufnr)[0]),
                    \\ 'term_getline(g:rplugin.R_bufnr, v:val)')
    endif
    call writefile(s:l, s:o . 'rconsole.txt')
endif
if bufnr('Object_Browser') > 0
    call writefile(getbufline(bufnr('Object_Browser'), 1, '\$'),
                \\ s:o . 'objbrowser.txt')
endif
call writefile(split(execute('messages'), "\n"), s:o . 'messages.txt')
EOF

# Recorders. Sourced once R is running, so that they override the plugin's own
# definitions instead of being overridden by them.
#
#   * SmokeSendCmdToR wraps g:SendCmdToR: it records the command and then
#     forwards it, so what is asserted is exactly what R receives.
#   * ROpenDoc would hand the produced file to a PDF viewer or a browser.
#   * SyncTeX_forward2 is the PDF viewer's forward-search entry point. Its
#     arguments are the file and the line the search resolved to.
cat > "$WORK/act_hooks.vim" <<EOF
let s:o = '$OUT/'
if !exists('g:SmokeRealSendCmdToR')
    let g:SmokeRealSendCmdToR = g:SendCmdToR
    function! SmokeSendCmdToR(...) abort
        call writefile([a:1], '$OUT/sentcmds.txt', 'a')
        return call(g:SmokeRealSendCmdToR, a:000)
    endfunction
    let g:SendCmdToR = function('SmokeSendCmdToR')
endif
function! ROpenDoc(fullpath, browser)
    call writefile([a:fullpath], '$OUT/opendoc.txt', 'a')
endfunction
function! SyncTeX_forward2(tpath, ppath, texln, tryagain)
    call writefile([a:tpath, a:ppath, string(a:texln)], '$OUT/synctex.txt')
endfunction
EOF

cat > "$WORK/act_startr.vim" <<EOF
call StartR("R")
EOF

cat > "$WORK/act_sendfile.vim" <<EOF
if bufwinnr('smoke.R') > 0
    exe bufwinnr('smoke.R') . 'wincmd w'
endif
call SendFileToR("echo")
EOF

cat > "$WORK/act_objbr.vim" <<EOF
if bufwinnr('smoke.R') > 0
    exe bufwinnr('smoke.R') . 'wincmd w'
endif
call RObjBrowser()
EOF

cat > "$WORK/act_openrnw.vim" <<EOF
call SmokeGoToEditorWin()
edit smoke_rnw.Rnw
call writefile([&filetype], '$OUT/ft_rnw')
EOF

cat > "$WORK/act_rnw.vim" <<EOF
call SmokeGoToEditorWin()
" <LocalLeader>kp: knit and build the pdf
call RWeave("nobib", 1, 1)
EOF

cat > "$WORK/act_synctex.vim" <<EOF
call SmokeGoToEditorWin()
call cursor($SYNCTEX_RNW_LINE, 1)
call SyncTeX_forward()
EOF

cat > "$WORK/act_rmd.vim" <<EOF
call SmokeGoToEditorWin()
edit smoke_rmd.Rmd
call writefile([&filetype], '$OUT/ft_rmd')
call RMakeRmd("html_document")
EOF

cat > "$WORK/act_qmd.vim" <<EOF
call SmokeGoToEditorWin()
edit smoke_qmd.qmd
call writefile([&filetype], '$OUT/ft_qmd')
call RQuarto("render")
EOF

cat > "$WORK/act_qcompl.vim" <<EOF
call SmokeGoToEditorWin()
call writefile(map(copy(CompleteQuartoCellOptions('fig-')), 'v:val["abbr"]'),
            \\ '$OUT/qcompl_fig.txt')
call writefile(map(copy(CompleteQuartoCellOptions('label')), 'v:val["abbr"]'),
            \\ '$OUT/qcompl_label.txt')
EOF

cat > "$WORK/act_quit.vim" <<EOF
if exists('*RQuit')
    call RQuit('nosave')
endif
EOF

# ------------------------------------------------------------- tmux driving --

SESSION=""

ex() { # ex <ex-command>: leave Terminal mode, then run an ex command
    tmux -L "$SOCK" send-keys -t "$SESSION" 'C-\' 'C-n' 2>/dev/null
    tmux -L "$SOCK" send-keys -t "$SESSION" ":$1" Enter 2>/dev/null
}

act() { ex "source $WORK/act_$1.vim"; }

refresh_dump() {
    ex "source $WORK/dump.vim"
    sleep 0.5
}

# wait_until <timeout-seconds> <predicate> [action-to-repeat-every-~10s]
#
# Gives up early if the editor reported a hard Vimscript error (E117 is what
# Neovim raises when it is made to source the Vim job layer: job_start() does
# not exist there), so a broken build fails in seconds instead of minutes.
wait_until() {
    local timeout="$1" predicate="$2" retry="${3:-}"
    local deadline=$((SECONDS + timeout))
    local n=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        refresh_dump
        if eval "$predicate" >/dev/null 2>&1; then
            return 0
        fi
        if [ -f "$OUT/messages.txt" ] &&
                grep -qE 'E1(17|21|29):' "$OUT/messages.txt"; then
            return 1
        fi
        n=$((n + 1))
        if [ -n "$retry" ] && [ $((n % 18)) -eq 0 ]; then
            act "$retry"
        fi
    done
    refresh_dump
    eval "$predicate" >/dev/null 2>&1
}

file_is()  { [ "$(cat "$OUT/$1" 2>/dev/null)" = "$2" ]; }
file_has() { [ -f "$OUT/$1" ] && grep -qF -- "$2" "$OUT/$1"; }

# ------------------------------------------------- document format assertions --

# Asserts the layer that depends on the editor: the command the plugin builds
# and sends to R, and the file R produces as a result. Called with R running.
run_document_checks() { # run_document_checks <name> <proj-dir>
    local name="$1" proj="$2"

    act hooks
    sleep 1

    # -------------------------------------------------------------- Rnoweb --
    if [ "$HAVE_RNW" -eq 1 ]; then
        act openrnw
        sleep 2
        if file_is ft_rnw rnoweb; then
            pass "$name: smoke_rnw.Rnw has filetype 'rnoweb'"
        else
            fail "$name: filetype of smoke_rnw.Rnw is '$(cat "$OUT/ft_rnw" 2>/dev/null)', expected 'rnoweb'"
        fi

        act rnw
        local want_rnw="vim.interlace.rnoweb(\"smoke_rnw.Rnw\", rnwdir = \"$proj\", view = FALSE)"
        if wait_until 30 "file_has sentcmds.txt '$want_rnw'"; then
            pass "$name: sent to R: $want_rnw"
        else
            fail "$name: the command sent to R is not '$want_rnw'"
            info "recorded: $(grep -F 'interlace.rnoweb' "$OUT/sentcmds.txt" 2>/dev/null | tail -1)"
        fi

        if wait_until 300 "[ -f '$proj/smoke_rnw.tex' ]"; then
            pass "$name: knitr produced smoke_rnw.tex"
        else
            fail "$name: smoke_rnw.tex was not produced"
        fi
        if wait_until 300 "[ -f '$proj/smoke_rnw.pdf' ]"; then
            pass "$name: latexmk produced smoke_rnw.pdf"
        else
            fail "$name: smoke_rnw.pdf was not produced"
        fi
        if [ -f "$proj/smoke_rnw.synctex.gz" ]; then
            pass "$name: latexmk produced smoke_rnw.synctex.gz"
        else
            fail "$name: smoke_rnw.synctex.gz was not produced"
        fi

        # SyncTeX forward search: assert the invocation, not the viewer.
        if [ -f "$proj/smoke_rnw.pdf" ] && [ -f "$proj/smoke_rnw.tex" ]; then
            rm -f "$OUT/synctex.txt"
            act synctex
            if wait_until 30 "[ -f '$OUT/synctex.txt' ]"; then
                local stex spdf sln
                stex="$(sed -n 1p "$OUT/synctex.txt")"
                spdf="$(sed -n 2p "$OUT/synctex.txt")"
                sln="$(sed -n 3p "$OUT/synctex.txt")"

                if [ "$stex" = "$proj/smoke_rnw.tex" ]; then
                    pass "$name: SyncTeX forward resolved the master to $stex"
                else
                    fail "$name: SyncTeX forward passed tex file '$stex', expected '$proj/smoke_rnw.tex'"
                fi
                # SetPDFdir() resolves "." to the master's own directory.
                if [ "$spdf" = "$proj/smoke_rnw.pdf" ]; then
                    pass "$name: SyncTeX forward passed the pdf as $spdf"
                else
                    fail "$name: SyncTeX forward passed pdf '$spdf', expected '$proj/smoke_rnw.pdf'"
                fi
                # Ground truth: the marker is on the Rnw line the cursor is on
                # and, verbatim, on the tex line the concordance resolves to.
                if [ -n "$sln" ] && sed -n "${sln}p" "$proj/smoke_rnw.tex" |
                        grep -qF 'VIMRSMOKESYNCTEXTARGET'; then
                    pass "$name: SyncTeX forward resolved Rnw line $SYNCTEX_RNW_LINE to tex line $sln, which holds the marker"
                else
                    fail "$name: SyncTeX forward resolved to tex line '$sln', which does not hold the marker"
                    info "tex line $sln: $(sed -n "${sln}p" "$proj/smoke_rnw.tex" 2>/dev/null)"
                    info "marker is on tex line(s): $(grep -n 'VIMRSMOKESYNCTEXTARGET' "$proj/smoke_rnw.tex" | cut -d: -f1 | tr '\n' ' ')"
                fi
            else
                fail "$name: SyncTeX_forward() did not invoke the forward search"
            fi
        else
            skip "$name: SyncTeX forward search (no pdf to search in)"
        fi
    else
        skip "$name: Rnw weave, pdf and SyncTeX forward search ($WHY_RNW)"
    fi

    # ---------------------------------------------------------- R Markdown --
    if [ "$HAVE_RMD" -eq 1 ]; then
        act rmd
        sleep 2
        if file_is ft_rmd rmd; then
            pass "$name: smoke_rmd.Rmd has filetype 'rmd'"
        else
            fail "$name: filetype of smoke_rmd.Rmd is '$(cat "$OUT/ft_rmd" 2>/dev/null)', expected 'rmd'"
        fi

        local want_rmd="vim.interlace.rmd(\"smoke_rmd.Rmd\", outform = \"html_document\", rmddir = \"$proj\", envir = .GlobalEnv)"
        if wait_until 30 "file_has sentcmds.txt '$want_rmd'"; then
            pass "$name: sent to R: $want_rmd"
        else
            fail "$name: the command sent to R is not '$want_rmd'"
            info "recorded: $(grep -F 'interlace.rmd' "$OUT/sentcmds.txt" 2>/dev/null | tail -1)"
        fi

        if wait_until 300 "[ -f '$proj/smoke_rmd.html' ]"; then
            pass "$name: rmarkdown produced smoke_rmd.html"
        else
            fail "$name: smoke_rmd.html was not produced"
        fi
        if wait_until 60 "file_has opendoc.txt 'smoke_rmd.html'"; then
            pass "$name: vimcom told the editor to open smoke_rmd.html"
        else
            fail "$name: vimcom never told the editor to open smoke_rmd.html"
        fi
    else
        skip "$name: Rmd render ($WHY_RMD)"
    fi

    # -------------------------------------------------------------- Quarto --
    if [ "$HAVE_QMD" -eq 1 ]; then
        act qmd
        sleep 2
        if file_is ft_qmd quarto; then
            pass "$name: smoke_qmd.qmd has filetype 'quarto'"
        else
            fail "$name: filetype of smoke_qmd.qmd is '$(cat "$OUT/ft_qmd" 2>/dev/null)', expected 'quarto'"
        fi

        local want_qmd='quarto::quarto_render("smoke_qmd.qmd")'
        if wait_until 30 "file_has sentcmds.txt '$want_qmd'"; then
            pass "$name: sent to R: $want_qmd"
        else
            fail "$name: the command sent to R is not '$want_qmd'"
            info "recorded: $(grep -F 'quarto_render' "$OUT/sentcmds.txt" 2>/dev/null | tail -1)"
        fi

        if wait_until 420 "[ -f '$proj/smoke_qmd.html' ]"; then
            pass "$name: quarto produced smoke_qmd.html"
        else
            fail "$name: smoke_qmd.html was not produced"
        fi
    else
        skip "$name: qmd render ($WHY_QMD)"
        # The completion assertion still needs a quarto buffer.
        act qmd
        sleep 2
    fi

    # Chunk-option completion, which reads quarto's yaml intelligence file.
    if [ -n "$QUARTO_INTEL" ]; then
        act qcompl
        if wait_until 30 "file_has qcompl_fig.txt 'fig-cap' && file_has qcompl_label.txt 'label'"; then
            pass "$name: Quarto chunk-option completion offers fig-cap and label"
        else
            fail "$name: Quarto chunk-option completion is empty or wrong"
            info "fig-: $(tr '\n' ' ' < "$OUT/qcompl_fig.txt" 2>/dev/null)"
            info "label: $(tr '\n' ' ' < "$OUT/qcompl_label.txt" 2>/dev/null)"
        fi
    else
        skip "$name: Quarto chunk-option completion (editor/tools/yaml/yaml-intelligence-resources.json not found; set VIMR_SMOKE_QUARTO_INTEL)"
    fi
}

# --------------------------------------------------------------- editor run --

run_editor() { # run_editor <name> <editor-command...>
    local name="$1"; shift
    local proj="$WORK/proj-$name"
    SESSION="vimr-smoke-$name-$$"
    rm -f "$OUT"/*
    make_fixtures "$proj"
    make_wrapper "$name" "$proj" "$@"

    head1 "Editor: $name"

    tmux -L "$SOCK" new-session -d -s "$SESSION" -x 140 -y 45 \
        "$WORK/run_$name.sh" || { fail "$name: could not start Tmux session"; return; }
    sleep 2   # do not type into the pane before the editor reads from it

    if wait_until 30 'file_is loaded 1'; then
        pass "$name: plugin loaded (g:rplugin exists)"
    else
        fail "$name: plugin did not load"
        tmux -L "$SOCK" capture-pane -p -t "$SESSION" > "$OUT/pane.txt" 2>/dev/null
        sed -n '1,25p' "$OUT/pane.txt" | sed 's/^/      | /'
        tmux -L "$SOCK" kill-session -t "$SESSION" 2>/dev/null
        return
    fi

    # Once a step fails there is no point in waiting out the timeout of every
    # step that depends on it: report them as failures right away.
    local broken=0

    # vimrserver prints "let g:rplugin.nrs_running = 1" on its stdout, which
    # the editor executes: this alone proves the job layer is wired up.
    if wait_until 120 'file_is server 1'; then
        pass "$name: vimrserver is running and drives the editor"
    else
        fail "$name: vimrserver never reported itself as running"
        broken=1
    fi

    if [ "$broken" -eq 0 ]; then
        act startr
        if wait_until 120 'file_is ready 1' startr; then
            pass "$name: R started and vimcom connected (R pid $(cat "$OUT/r_pid"))"
        else
            fail "$name: R did not start / vimcom never connected"
            broken=1
        fi
    else
        fail "$name: R did not start (skipped: vimrserver is not running)"
    fi

    if [ "$broken" -eq 0 ]; then
        act sendfile
        if wait_until 90 'file_has rconsole.txt "VIMR_SMOKE_SUM: 5050"' sendfile; then
            pass "$name: R Console shows the output of the file sent to R"
        else
            fail "$name: 'VIMR_SMOKE_SUM: 5050' not found in the R Console buffer"
            broken=1
        fi

        act objbr
        wait_until 90 'file_has objbrowser.txt "#smoke_df"' objbr
    else
        fail "$name: file not sent to R (skipped: R is not running)"
    fi

    # In the Object Browser every object name is preceded by a type marker and
    # a '#', so "#smoke_df" cannot be matched by anything else (e.g. the file
    # name shown in a status line). "[3, 2]" are the dimensions of the
    # data.frame, so vimcom really did inspect the object in R's workspace.
    local want
    for want in '#smoke_df' '[3, 2]' '#alpha' '#beta' '#smoke_chr'; do
        if file_has objbrowser.txt "$want"; then
            pass "$name: Object Browser shows '$want'"
        else
            fail "$name: '$want' not found in the Object_Browser buffer"
        fi
    done

    if [ "$broken" -eq 0 ]; then
        run_document_checks "$name" "$proj"
    else
        fail "$name: document formats not tested (skipped: R is not running)"
    fi

    # Diagnostics, printed only when something went wrong.
    if [ "$FAILURES" -gt 0 ]; then
        info "--- Vimscript errors ($name) ---"
        if [ -f "$OUT/messages.txt" ]; then
            grep -E 'E[0-9]+:' "$OUT/messages.txt" | sort -u |
                sed 's/^/      | /'
        fi
        info "--- last messages ($name) ---"
        [ -f "$OUT/messages.txt" ] &&
            sort -u "$OUT/messages.txt" | tail -12 | sed 's/^/      | /'
        info "--- commands sent to R ($name) ---"
        [ -f "$OUT/sentcmds.txt" ] &&
            sed 's/^/      | /' "$OUT/sentcmds.txt"
        info "--- Object Browser ($name) ---"
        [ -f "$OUT/objbrowser.txt" ] &&
            sed -n '1,15p' "$OUT/objbrowser.txt" | sed 's/^/      | /'
        info "--- R Console tail ($name) ---"
        [ -f "$OUT/rconsole.txt" ] &&
            grep -v '^$' "$OUT/rconsole.txt" | tail -12 | sed 's/^/      | /'
    fi

    act quit
    sleep 1
    ex "qa!"
    sleep 1
    tmux -L "$SOCK" kill-session -t "$SESSION" 2>/dev/null
    SESSION=""
}

FAILURES_BEFORE_VIM=0
run_editor vim  vim -u "$WORK/rc.vim" -i NONE
VIM_FAILURES=$((FAILURES - FAILURES_BEFORE_VIM))
FAILURES_BEFORE_NVIM="$FAILURES"
run_editor nvim nvim -u "$WORK/rc.vim"
NVIM_FAILURES=$((FAILURES - FAILURES_BEFORE_NVIM))

# ------------------------------------------------------------- post-mortem ---

head1 "Post-run checks"

if [ "$REAL_LIBS_BEFORE" = "$(fingerprint_real_libs)" ]; then
    pass "the real R libraries were not modified"
else
    fail "a real R library changed during the test"
    diff <(printf '%s\n' "$REAL_LIBS_BEFORE") \
         <(fingerprint_real_libs) | sed 's/^/      | /'
fi

STRAY="$(find "$REPO" -path "$REPO/.git" -prune -o \
    \( -name '*.swp' -o -name '*.swo' -o -name 'nvim.log' -o -name '.netrwhist' \
       -o -name '*.tmp.R' -o -name '*.aux' -o -name '*.synctex.gz' \) \
    -print 2>/dev/null)"
if [ -z "$STRAY" ]; then
    pass "no editor leftovers in the repository working tree"
else
    fail "editor leftovers in the repository working tree"
    printf '%s\n' "$STRAY" | sed 's/^/      | /'
fi

if tmux -L "$SOCK" list-sessions >/dev/null 2>&1; then
    fail "sessions left on the private Tmux socket"
    tmux -L "$SOCK" list-sessions | sed 's/^/      | /'
else
    pass "no sessions left on the private Tmux socket"
fi

# ----------------------------------------------------------------- verdict ----

head1 "Result"
printf '  vim:   %s\n'  "$([ "$VIM_FAILURES"  -eq 0 ] && echo PASS || echo "FAIL ($VIM_FAILURES assertion(s))")"
printf '  nvim:  %s\n'  "$([ "$NVIM_FAILURES" -eq 0 ] && echo PASS || echo "FAIL ($NVIM_FAILURES assertion(s))")"
[ "$SKIPS" -gt 0 ] && printf '  %s\n' "$(yellow "skipped: $SKIPS assertion(s) -- see the SKIP lines above")"

if [ "$FAILURES" -eq 0 ]; then
    green "SMOKE TEST PASSED"
    exit 0
fi
red "SMOKE TEST FAILED ($FAILURES assertion(s))"
exit 1
