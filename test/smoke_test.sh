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
#      Object_Browser buffer, and on the highlighting, the navigation, the
#      outline and the folding of the note comments,
#   6. weaves an Rnw file (<LocalLeader>kp), renders an Rmd file and renders a
#      qmd file, and asserts on the command the plugin sent to R, on the file
#      that R produced and, for the Rnw file, on the arguments with which
#      SyncTeX forward search invokes the PDF viewer,
#   7. asserts that Quarto chunk-option completion is populated from quarto's
#      yaml-intelligence-resources.json, both when the plugin has to find that
#      file by itself, starting from the quarto command on $PATH, and when it
#      is handed the path through R_quarto_intel,
#   8. asserts the citation keys, the authors and the years that bibliographic
#      completion returns for an Rmd, a qmd and an Rnw document, both through
#      RCompleteBib() and through the omni completion function the user
#      triggers.
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
# How it waits (see do_act and r_is_idle below): the editor is driven by Tmux,
# which says nothing about when the editor is done, so nothing here is asserted
# after a delay. A file written by the editor is asserted after the act_*.vim
# that writes it has written its sentinel, and a file written by R, or by a
# program R called, is asserted after R has printed a marker sent to it *after*
# the command that produces the file. Every wait has a timeout, and a timeout is
# reported as a failure of its own.
#
# How to run it:
#
#   ./test/smoke_test.sh            # from anywhere; no arguments
#
# Set VIMR_SMOKE_KEEP=1 to keep the scratch directory for inspection.
# Set VIMR_SMOKE_QUARTO_INTEL=/path/to/yaml-intelligence-resources.json to
# point the R_quarto_intel assertion at a Quarto installation the harness
# cannot find by itself. It does not affect the auto-discovery assertion,
# which is about what the plugin finds on its own.
#
# Exit status is 0 only if every assertion passed in *both* editors. Assertions
# whose external tool is missing are reported as SKIP; a SKIP is never counted
# as a PASS, and the number of skips is printed in the verdict.
#
# Requirements: bash, tmux, R (with a C compiler), vim, nvim.
# Optional, detected at run time: latexmk and xelatex (Rnw), pandoc and the
# rmarkdown package (Rmd), the quarto command and the quarto package (qmd),
# quarto's editor/tools/yaml/yaml-intelligence-resources.json (completion), and
# a Python 3 whose PyBTeX can parse a .bib file (bibliographic completion).
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
# R/bibtex.py imports R/vimr.py, and byte-compiling it would write a
# __pycache__ into the repository.
export PYTHONDONTWRITEBYTECODE=1
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

# The interpreter Vim-R would resolve to with R_python3 unset: the first of
# 'python3' and 'python' on $PATH that is Python 3, as s:HasPython3() picks it.
find_bib_python() {
    local py
    for py in python3 python; do
        command -v "$py" >/dev/null 2>&1 || continue
        if "$py" --version 2>&1 | grep -q '^Python 3'; then
            printf '%s' "$py"
            return 0
        fi
    done
    return 1
}

# Whether that interpreter can really deliver a completion, asked of R/bibtex.py
# itself and not of an import: a PyBTeX that imports and then fails to parse --
# one installed without the PyYAML it declares, for instance -- has to be
# reported as missing instead of failing the assertions. Prints why it cannot.
probe_pybtex() { # probe_pybtex <interpreter>
    local py="$1" why
    mkdir -p "$WORK/pybtex-probe"
    printf '%s\n' '@book{smokeprobe, author = {Probe, P}, title = {T},' \
                  '  year = {2000}}' > "$WORK/pybtex-probe/probe.bib"
    rm -f "$WORK/pybtex-probe/bibcompl"
    printf '\003\005%s\n' "$WORK/pybtex-probe/probe.qmd" |
        VIMR_TMPDIR="$WORK/pybtex-probe" "$py" "$REPO/R/bibtex.py" \
            "$WORK/pybtex-probe/probe.qmd" "$WORK/pybtex-probe/probe.bib" \
            >/dev/null 2>"$WORK/pybtex-probe/err"
    grep -q smokeprobe "$WORK/pybtex-probe/bibcompl" 2>/dev/null && return 0
    # What bibtex.py says when PyBTeX is there and the parse fails, and
    # otherwise the last line, which of a traceback is the exception itself.
    why="$(grep -m1 'Error parsing' "$WORK/pybtex-probe/err" 2>/dev/null)"
    [ -n "$why" ] || why="$(grep -v '^[[:space:]]*$' \
        "$WORK/pybtex-probe/err" 2>/dev/null | tail -1)"
    printf 'the PyBTeX library of %s cannot parse a .bib file: %s' \
        "$py" "${why:-it returned no completion and said nothing}"
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

# Auto-discovery is what the plugin does with nothing but the quarto command on
# $PATH, so the quarto command is the only thing that may make it SKIP. If
# quarto is there and the resource is not reachable from it, that is a failure
# of the code under test, not a missing dependency, and it must not be a SKIP.
HAVE_QCOMPL=1; WHY_QCOMPL=""
if ! command -v quarto >/dev/null 2>&1; then
    HAVE_QCOMPL=0; WHY_QCOMPL="the 'quarto' command is not in \$PATH"
fi

HAVE_BIB=1; WHY_BIB=""; BIB_PY=""
BIB_PY="$(find_bib_python || true)"
if [ -z "$BIB_PY" ]; then
    HAVE_BIB=0
    WHY_BIB="neither 'python3' nor 'python' in \$PATH is Python 3"
else
    WHY_BIB="$(probe_pybtex "$BIB_PY")" || HAVE_BIB=0
fi

# Only for the R_quarto_intel assertion: the path the harness finds by itself,
# with its own logic, so that the option is asserted against a known-good file
# instead of against whatever the plugin happened to discover.
QUARTO_INTEL="$(find_quarto_intel || true)"

printf '  %-22s %s\n' "Rnw -> pdf:" \
    "$([ "$HAVE_RNW" -eq 1 ] && echo "available ($(latexmk --version 2>/dev/null | head -1))" || echo "SKIP: $WHY_RNW")"
printf '  %-22s %s\n' "Rmd -> html:" \
    "$([ "$HAVE_RMD" -eq 1 ] && echo "available (pandoc $(pandoc --version 2>/dev/null | head -1 | awk '{print $2}'))" || echo "SKIP: $WHY_RMD")"
printf '  %-22s %s\n' "qmd -> html:" \
    "$([ "$HAVE_QMD" -eq 1 ] && echo "available (quarto $(quarto --version 2>/dev/null))" || echo "SKIP: $WHY_QMD")"
printf '  %-22s %s\n' "Quarto completion:" \
    "$([ "$HAVE_QCOMPL" -eq 1 ] && echo "auto-discovery from $(command -v quarto)" || echo "SKIP: $WHY_QCOMPL")"
printf '  %-22s %s\n' "R_quarto_intel:" \
    "$([ -n "$QUARTO_INTEL" ] && echo "$QUARTO_INTEL" || echo "SKIP: the harness did not find yaml-intelligence-resources.json")"
printf '  %-22s %s\n' "Bib completion:" \
    "$([ "$HAVE_BIB" -eq 1 ] && echo "PyBTeX usable by $BIB_PY" || echo "SKIP: $WHY_BIB")"

# ------------------------------------------------------------------ fixtures --

# The level of every line of smoke.R: three lines of code, then the notes,
# with the RStudio section of line 14 as a sibling of the level 1 notes.
SMOKE_NOTE_LEVELS='00010203020101030'

# The fold level of every line of smoke.R, which is the level of the deepest
# note above it: a fold begins on the title line and ends before the next
# title of the same or of a lesser level.
SMOKE_NOTE_FOLDLEVELS='00011223322111133'

# Written into a per-editor directory, so that a file produced by the first
# editor can never be mistaken for a file produced by the second.
make_fixtures() { # make_fixtures <dir>
    local d="$1"
    mkdir -p "$d"

    # The note comments are what the highlighting, the folding, the navigation
    # and the outline are asserted on. They are comments, so neither R nor the
    # assertions on the R Console and on the Object Browser are affected. The
    # line numbers matter: see SMOKE_NOTE_LEVELS.
    cat > "$d/smoke.R" <<'EOF'
cat("VIMR_SMOKE_SUM:", sum(1:100), "\n")
smoke_df <- data.frame(alpha = 1:3, beta = c("x", "y", "z"))
smoke_chr <- "VIMR_SMOKE_CHR"
#. Section one
sec1 <- 1
#.. Subsection 1.1
sub11 <- 2
#... Sub-sub 1.1.1
subsub <- 3
#.. Subsection 1.2
sub12 <- 4
#. Section two
sec2 <- 5
# Section three ----
sec3 <- 6
#.... Four dots are still a note of level 3
deep <- 7
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

    # Bibliographic completion. The keys hold none of the authors and none of
    # the words of the titles, so a match can only have come from the field the
    # assertion says it came from.
    cat > "$d/smoke_refs.bib" <<'EOF'
@article{smokebibone2001,
  author = {Alpha, Ana and Beta, Bruno},
  title = {A study of alphabetic things},
  year = {2001},
  journal = {Journal of Alpha}
}
@book{smokebibtwo1998,
  author = {Gamma, Gustavo},
  title = {Delta and the art of gamma},
  year = {1998},
  publisher = {Delta Press}
}
EOF

    # Never rendered: a 'bibliography:' would make pandoc and quarto run
    # citeproc, and the assertions of step 6 are not about that. The path is
    # relative, as it is written in practice, and is read as relative to the
    # document. The Rnw file names no bib file: there, the plugin globs *.bib
    # in the directory of the document.
    cat > "$d/smoke_bib.Rmd" <<'EOF'
---
title: "Vim-R smoke test"
bibliography: smoke_refs.bib
---

VIMRSMOKEBIBRMD.
EOF

    cat > "$d/smoke_bib.qmd" <<'EOF'
---
title: "Vim-R smoke test"
bibliography: smoke_refs.bib
---

VIMRSMOKEBIBQMD.
EOF

    cat > "$d/smoke_bib.Rnw" <<'EOF'
\documentclass{article}
\begin{document}
VIMRSMOKEBIBRNW.
\bibliography{smoke_refs}
\end{document}
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
" Bibliographic completion is enabled for rnoweb alone by default.
let R_bib_compl = ['rnoweb', 'rmd', 'quarto']

" R_quarto_intel is deliberately left unset here: the completion assertion
" exercises the plugin's own search for yaml-intelligence-resources.json. The
" option is asserted separately, by setting it at run time.

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
export PYTHONDONTWRITEBYTECODE='$PYTHONDONTWRITEBYTECODE'
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

# The marker R prints when it has finished everything sent to it so far. The
# arguments are separate so that the line R echoes when it reads the command
# cannot be mistaken for the line R prints when it runs it.
cat > "$WORK/act_ridle.vim" <<EOF
call g:SendCmdToR('cat("VIMR_SMOKE_IDLE:", "' . g:smoke_idle_tag . '", "\n")')
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

# The branch of SyncTeX_forward() that runs when the .synctex.gz is missing.
# R_latexcmd is deliberately left without "-synctex=1" so that the note about
# it is reached, which is where the comparison of the list with a string used
# to raise E691.
cat > "$WORK/act_synctex_missing.vim" <<EOF
call SmokeGoToEditorWin()
let s:cmd = g:R_latexcmd
let g:R_latexcmd = ['xelatex', '-file-line-error']
call cursor($SYNCTEX_RNW_LINE, 1)
call SyncTeX_forward()
let g:R_latexcmd = s:cmd
call writefile(split(execute('messages'), nr2char(10)),
            \\ '$OUT/synctex_missing.txt')
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

# Auto-discovery: g:R_quarto_intel must not exist, otherwise the assertion
# would be about the option and not about the search. FillQuartoComplMenu() is
# called explicitly so that the search runs even if the list was already built.
cat > "$WORK/act_qcompl.vim" <<EOF
call SmokeGoToEditorWin()
call writefile([string(exists('g:R_quarto_intel'))], '$OUT/qintel_set.txt')
call FillQuartoComplMenu()
call writefile(map(copy(CompleteQuartoCellOptions('fig-')), 'v:val["abbr"]'),
            \\ '$OUT/qcompl_fig.txt')
call writefile(map(copy(CompleteQuartoCellOptions('label')), 'v:val["abbr"]'),
            \\ '$OUT/qcompl_label.txt')
EOF

# The documented option, given as a '~' path to also cover its expansion. The
# link lives in the scratch HOME, so nothing outside /tmp is written.
cat > "$WORK/act_qcompl_opt.vim" <<EOF
call SmokeGoToEditorWin()
let g:R_quarto_intel = '~/quarto-intel.json'
call FillQuartoComplMenu()
call writefile(map(copy(CompleteQuartoCellOptions('fig-')), 'v:val["abbr"]'),
            \\ '$OUT/qcompl_opt.txt')
unlet g:R_quarto_intel
EOF

# Note comments: the highlight groups the syntax resolves to, the colors
# derived from a light and from a dark colorscheme, and what happens to a
# definition of the user's when the colorscheme changes.
cat > "$WORK/act_notehl.vim" <<EOF
call SmokeGoToEditorWin()
edit! smoke.R
let s:l = []
for s:ln in range(1, line('\$'))
    if getline(s:ln) !~ '^#'
        continue
    endif
    let s:id = synID(s:ln, 1, 1)
    let s:tr = synIDtrans(s:id)
    let s:at = []
    if synIDattr(s:tr, 'bold') == 1
        call add(s:at, 'bold')
    endif
    if synIDattr(s:tr, 'underline') == 1
        call add(s:at, 'underline')
    endif
    call add(s:l, printf('%s -> %s [%s] | %s', synIDattr(s:id, 'name'),
                \\ synIDattr(s:tr, 'name'), join(s:at, ','), getline(s:ln)))
endfor
call writefile(s:l, '$OUT/note_syn.txt')

let s:l = []
for s:cs in ['morning', 'desert']
    exe 'colorscheme ' . s:cs
    let s:d = g:rplugin.note_hl
    call add(s:l, printf('%s %s %s %d %d', s:cs, s:d.fg_1, s:d.fg_3,
                \\ s:d.ctermfg_1, s:d.ctermfg_3))
endfor
call writefile(s:l, '$OUT/note_colors.txt')

highlight Note_1 guifg=#b73e30 gui=bold,underline
let s:l = []
for s:cs in ['morning', 'habamax', 'desert']
    exe 'colorscheme ' . s:cs
    call add(s:l, s:cs . ' ' .
                \\ matchstr(execute('highlight Note_1'), 'guifg=\zs\S\+'))
endfor
call RNoteHlReset('Note_1')
call add(s:l, 'reset ' .
            \\ matchstr(execute('highlight Note_1'), 'guifg=\zs\S\+'))
call writefile(s:l, '$OUT/note_user_hl.txt')

" A 'Comment' that the terminal paints gray, which is what jellybeans leaves on
" a terminal of eight colors: ANSI 7 and the blue gui color of Vim's own
" defaults. The three levels have to stay inside the grayscale ramp, 232-255,
" and the level 3 has to remain apart from the levels 1 and 2.
highlight Normal ctermfg=7 ctermbg=NONE guifg=NONE guibg=NONE
highlight Comment ctermfg=7 guifg=#80a0ff
call RNoteHlReset()
let s:d = g:rplugin.note_hl
call writefile([printf('gray %d %d %d ramp %d apart %d',
            \\ s:d.ctermfg_base, s:d.ctermfg_1, s:d.ctermfg_3,
            \\ min([s:d.ctermfg_base, s:d.ctermfg_1, s:d.ctermfg_3]) >= 232
            \\ && max([s:d.ctermfg_base, s:d.ctermfg_1, s:d.ctermfg_3]) <= 255,
            \\ s:d.ctermfg_1 != s:d.ctermfg_3)], '$OUT/note_gray.txt')
colorscheme desert
call RNoteHlReset()
EOF

# Note comments: that the maps are bound, where the cursor lands with and
# without a count, and the outline the location list is filled with. The local
# leader is written as nr2char(92) so that no backslash has to survive the
# heredoc.
cat > "$WORK/act_notenav.vim" <<EOF
call SmokeGoToEditorWin()
edit! smoke.R
let s:ll = nr2char(92)
let s:l = []
for s:k in ['gs', 'gS', 'go']
    call add(s:l, s:k . ' ' . maparg(s:ll . s:k, 'n'))
endfor
call add(s:l, 'plug ' . maparg('<Plug>RNextNote', 'n'))
call add(s:l, 'levels ' . join(map(range(1, line('\$')),
            \\ 'RNoteLevel(getline(v:val))'), ''))
for [s:tag, s:cnt, s:key, s:from, s:times] in [['next', '', 'gs', 1, 7],
            \\ ['next1', '1', 'gs', 1, 3],
            \\ ['prev1', '1', 'gS', line('\$'), 3]]
    call cursor(s:from, 1)
    let s:seq = []
    for s:i in range(1, s:times)
        execute 'normal ' . s:cnt . s:ll . s:key
        call add(s:seq, line('.'))
    endfor
    call add(s:l, s:tag . ' ' . join(s:seq, ' '))
endfor
call writefile(s:l, '$OUT/note_nav.txt')

call cursor(1, 1)
call RNoteOutline()
call writefile(['lnums ' . join(map(getloclist(0), 'v:val.lnum'), ' '),
            \\ 'qflist ' . len(getqflist())] + getline(1, '\$'),
            \\ '$OUT/note_outline.txt')
close
EOF

# Note comments: that 'foldmethod' is untouched until the option is set, the
# fold level of every line, and the text of the closed folds. The option is
# put back to its default so that no later assertion runs in a folded buffer.
cat > "$WORK/act_notefold.vim" <<EOF
call SmokeGoToEditorWin()
edit! smoke.R
let s:l = ['default ' . &l:foldmethod]
let g:R_note_folding = ['r']
edit! smoke.R
call add(s:l, printf('set %s %s %s', &l:foldmethod, &l:foldexpr, &l:foldtext))
call add(s:l, 'levels ' . join(map(range(1, line('\$')),
            \\ 'foldlevel(v:val)'), ''))
for s:ln in [4, 6, 14, 16]
    call add(s:l, printf('text %d %s', s:ln, foldtextresult(s:ln)))
endfor
let g:R_note_folding = []
edit! smoke.R
call add(s:l, 'restored ' . &l:foldmethod)
call writefile(s:l, '$OUT/note_fold.txt')
EOF

# Bibliographic completion, for the three file types that can have it.
#
# CheckPyBTeX() is called explicitly, as FillQuartoComplMenu() is above, so that
# the search for the bib file and the start of the BibComplete job do not depend
# on the timer the ftplugin arms. Every base is asked for through
# RCompleteBib(), which blocks until the job has answered, and one of them also
# through CompleteR(), which is the 'omnifunc' the user triggers: the cursor is
# put on the space that follows the half typed citation, which is where it would
# be, so that the base CompleteR() is handed is the one Vim would hand it. The
# buffer is reloaded on every pass, so the script is repeatable.
cat > "$WORK/act_bib.vim" <<EOF
call SmokeGoToEditorWin()
for [s:f, s:tag] in [['smoke_bib.Rmd', 'rmd'], ['smoke_bib.qmd', 'quarto'],
            \\ ['smoke_bib.Rnw', 'rnoweb']]
    exe 'edit! ' . s:f
    call CheckPyBTeX()
    let s:l = ['ft ' . &filetype, 'bibf ' . b:rplugin_bibf]
    for [s:btag, s:base] in [['all', ''], ['key', 'smokebibtwo'],
                \\ ['author', 'gamma'], ['none', 'zzznomatch']]
        let s:r = RCompleteBib(s:base)
        call add(s:l, printf('%s n=%d %s', s:btag, len(s:r),
                    \\ join(map(copy(s:r), 'v:val["word"]'), ' ')))
        for s:it in s:r
            call add(s:l, printf('item %s | %s | %s',
                        \\ s:it['word'], s:it['abbr'], s:it['menu']))
        endfor
    endfor
    let s:cite = (&filetype == 'rnoweb' ? 'A ' . nr2char(92) . 'cite{'
                \\ : 'A [@') . 'smokebibtwo '
    call append(line('\$'), s:cite)
    call cursor(line('\$'), len(s:cite))
    let s:st = CompleteR(1, '')
    let s:r = CompleteR(0, strpart(getline('.'), s:st, col('.') - 1 - s:st))
    call add(s:l, printf('omni n=%d %s', len(s:r),
                \\ join(map(copy(s:r), 'v:val["word"]'), ' ')))
    call writefile(s:l, '$OUT/bib_' . s:tag . '.txt')
endfor
edit! smoke.R
EOF

cat > "$WORK/act_quit.vim" <<EOF
if exists('*RQuit')
    call RQuit('nosave')
endif
EOF

# The sentinel that sentinel() blocks on. It has to be the last line of every
# one of these scripts, and appending it here is what keeps it so: a Vimscript
# error does not abort the rest of a sourced file, so the sentinel is written
# whatever happened above it, and an assertion that fails is reported as an
# assertion that failed instead of as a timeout.
for f in "$WORK"/act_*.vim; do
    printf "call writefile(['%s'], '%s')\n" \
        "$(basename "$f" .vim | sed 's/^act_//')" "$OUT/act_done" >> "$f"
done

# ------------------------------------------------------------- tmux driving --

SESSION=""

ex() { # ex <ex-command>: leave Terminal mode, then run an ex command
    tmux -L "$SOCK" send-keys -t "$SESSION" 'C-\' 'C-n' 2>/dev/null
    # A pending prompt of the editor's would swallow the ':' and everything
    # typed after it. Sent after Terminal mode has been left, so that it cannot
    # reach R instead of the editor.
    tmux -L "$SOCK" send-keys -t "$SESSION" Escape 2>/dev/null
    tmux -L "$SOCK" send-keys -t "$SESSION" ":$1" Enter 2>/dev/null
}

act() { rm -f "$OUT/act_done"; ex "source $WORK/act_$1.vim"; }

refresh_dump() {
    ex "source $WORK/dump.vim"
    sleep 0.5
}

hard_errors() {
    if [ -f "$OUT/messages.txt" ]; then
        grep -cE 'E1(17|21|29):' "$OUT/messages.txt" || true
    else
        printf '0\n'
    fi
}

# wait_until <timeout-seconds> <predicate> [action-to-repeat-every-~10s]
#
# Gives up early if the editor reported a *new* hard Vimscript error (E117 is
# what Neovim raises when it is made to source the Vim job layer: job_start()
# does not exist there), so a broken build fails in seconds instead of minutes.
# Only new errors count: ':messages' is a history, and an error left in it by
# an earlier step would otherwise make every later wait return at once and
# report whatever it was waiting for as missing.
wait_until() {
    local timeout="$1" predicate="$2" retry="${3:-}"
    local deadline=$((SECONDS + timeout))
    local n=0
    local errors_before
    errors_before="$(hard_errors)"
    while [ "$SECONDS" -lt "$deadline" ]; do
        refresh_dump
        if eval "$predicate" >/dev/null 2>&1; then
            return 0
        fi
        if [ "$(hard_errors)" != "$errors_before" ]; then
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

# sentinel <act-name> <timeout-seconds>
#
# Every act_*.vim writes its own name into $OUT/act_done as its last line, so
# the sentinel naming the script that was sourced means that every writefile()
# of that script has already returned: an assertion that runs afterwards cannot
# read a file the editor has not written yet, nor half of one. A fixed delay
# cannot promise that, however long it is. The sentinel is written by the
# editor itself, so waiting for it needs no round trip through dump.vim.
sentinel() {
    local act="$1" deadline=$((SECONDS + $2))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if file_is act_done "$act"; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# do_act <editor> <act-name>
#
# Sources act_<name>.vim and blocks until it has run. Keys typed into a Tmux
# pane are not acknowledged by the editor, and one of these scripts is now and
# then never sourced at all: without the sentinel that is reported as whatever
# the script was supposed to produce -- an empty file, a command the plugin
# never sent -- and the plugin is blamed for it. Sourcing a script twice is
# harmless, every one of them is written to be repeatable, and the sentinel
# appears within milliseconds of the keys arriving, so a resend can only ever
# hit a script that really did not run.
do_act() {
    local name="$1" act="$2" try=0
    while [ "$try" -lt 3 ]; do
        act "$act"
        try=$((try + 1))
        if sentinel "$act" 20; then
            return 0
        fi
    done
    fail "$name: the editor did not source act_$act.vim ($try attempts)"
    tmux -L "$SOCK" capture-pane -p -t "$SESSION" > "$OUT/pane.txt" 2>/dev/null
    [ -f "$OUT/pane.txt" ] && sed -n '1,25p' "$OUT/pane.txt" | sed 's/^/      | /'
    return 1
}

# do_act_until <editor> <act-name> <predicate> <timeout-seconds>
#
# What an act_*.vim writes is complete as soon as its sentinel is there, but not
# necessarily populated: RCompleteBib() waits for the BibComplete job itself,
# and only for as long as it is willing to, so the first call can honestly come
# back empty while the Python interpreter is still importing PyBTeX. Sourcing
# the script again is what waits for that, and every pass is still synchronised
# by its own sentinel, so the predicate is never evaluated against a file that
# is being written. A sleep here would be a guess at how long an import takes.
do_act_until() {
    local name="$1" act="$2" predicate="$3" deadline=$((SECONDS + $4))
    while :; do
        do_act "$name" "$act" || return 1
        if eval "$predicate" >/dev/null 2>&1; then
            return 0
        fi
        [ "$SECONDS" -lt "$deadline" ] || return 1
    done
}

# r_is_idle <editor> <tag> <timeout-seconds>
#
# R runs what it is sent in the order it is sent, so a marker sent after a
# document command only reaches the R Console once that command has returned,
# and with it knitr, latexmk, pandoc or quarto. Nothing else says that: an
# output file appears while the tool that writes it is still running, and
# latexmk writes the pdf in its first pass and then starts a second one.
r_is_idle() {
    local name="$1" tag="$2" timeout="$3"
    ex "let g:smoke_idle_tag = '$tag'"
    do_act "$name" ridle || return 1
    if wait_until "$timeout" "file_has rconsole.txt 'VIMR_SMOKE_IDLE: $tag'"; then
        return 0
    fi
    fail "$name: R was still busy ${timeout}s after the $tag command"
    return 1
}

# ------------------------------------------------- document format assertions --

# Asserts the layer that depends on the editor: the command the plugin builds
# and sends to R, and the file R produces as a result. Called with R running.
run_document_checks() { # run_document_checks <name> <proj-dir>
    local name="$1" proj="$2"

    do_act "$name" hooks || return

    # -------------------------------------------------------------- Rnoweb --
    if [ "$HAVE_RNW" -eq 1 ]; then
        do_act "$name" openrnw || return
        if file_is ft_rnw rnoweb; then
            pass "$name: smoke_rnw.Rnw has filetype 'rnoweb'"
        else
            fail "$name: filetype of smoke_rnw.Rnw is '$(cat "$OUT/ft_rnw" 2>/dev/null)', expected 'rnoweb'"
        fi

        do_act "$name" rnw || return
        local want_rnw="vim.interlace.rnoweb(\"smoke_rnw.Rnw\", rnwdir = \"$proj\", view = FALSE)"
        if wait_until 30 "file_has sentcmds.txt '$want_rnw'"; then
            pass "$name: sent to R: $want_rnw"
        else
            fail "$name: the command sent to R is not '$want_rnw'"
            info "recorded: $(grep -F 'interlace.rnoweb' "$OUT/sentcmds.txt" 2>/dev/null | tail -1)"
        fi

        # Every file below is written by latexmk, which runs *latex twice: the
        # first pass writes the pdf and the .synctex.gz, the second one writes
        # them again. Asserting as soon as a file exists therefore asserts in
        # the middle of the build, and what comes next -- moving the
        # .synctex.gz aside -- would race with a pass that puts it back.
        if r_is_idle "$name" rnw 300; then
            if [ -f "$proj/smoke_rnw.tex" ]; then
                pass "$name: knitr produced smoke_rnw.tex"
            else
                fail "$name: smoke_rnw.tex was not produced"
            fi
            if [ -f "$proj/smoke_rnw.pdf" ]; then
                pass "$name: latexmk produced smoke_rnw.pdf"
            else
                fail "$name: smoke_rnw.pdf was not produced"
            fi
            if [ -f "$proj/smoke_rnw.synctex.gz" ]; then
                pass "$name: latexmk produced smoke_rnw.synctex.gz"
            else
                fail "$name: smoke_rnw.synctex.gz was not produced"
                info "latexmk: $(grep -F "Exit status of 'latexmk'" "$OUT/rconsole.txt" 2>/dev/null | tail -1)"
            fi
        fi

        # SyncTeX forward search: assert the invocation, not the viewer.
        if [ -f "$proj/smoke_rnw.pdf" ] && [ -f "$proj/smoke_rnw.tex" ]; then
            rm -f "$OUT/synctex.txt"
            if do_act "$name" synctex; then
                if [ -f "$OUT/synctex.txt" ]; then
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
                    # Ground truth: the marker is on the Rnw line the cursor is
                    # on and, verbatim, on the tex line the concordance
                    # resolves to.
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
                    refresh_dump
                    info "warning: $(grep -F 'SyncTeX' "$OUT/messages.txt" 2>/dev/null | tail -1)"
                fi
            fi

            # The file is moved aside, and not deleted, because latexmk would
            # not write it again: it does not treat the .synctex.gz as a target
            # of its own, so with an up to date pdf it has nothing to do.
            local finished=0
            rm -f "$OUT/synctex_missing.txt"
            mv "$proj/smoke_rnw.synctex.gz" "$proj/kept.synctex.gz"
            do_act "$name" synctex_missing || finished=1
            mv "$proj/kept.synctex.gz" "$proj/smoke_rnw.synctex.gz"
            if [ "$finished" -eq 0 ]; then
                if file_has synctex_missing.txt \
                        'The string "-synctex=1" is not in your R_latexcmd' &&
                        ! file_has synctex_missing.txt 'E691'; then
                    pass "$name: SyncTeX forward notes a R_latexcmd without -synctex=1"
                else
                    fail "$name: SyncTeX forward did not note a R_latexcmd without -synctex=1"
                    info "recorded: $(grep -E 'synctex|E691' "$OUT/synctex_missing.txt" 2>/dev/null | tail -3 | tr '\n' '/')"
                fi
            fi
        else
            skip "$name: SyncTeX forward search (no pdf to search in)"
        fi
    else
        skip "$name: Rnw weave, pdf and SyncTeX forward search ($WHY_RNW)"
    fi

    # ---------------------------------------------------------- R Markdown --
    if [ "$HAVE_RMD" -eq 1 ]; then
        do_act "$name" rmd || return
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

        if r_is_idle "$name" rmd 300; then
            if [ -f "$proj/smoke_rmd.html" ]; then
                pass "$name: rmarkdown produced smoke_rmd.html"
            else
                fail "$name: smoke_rmd.html was not produced"
            fi
        fi
        # vimcom sends the request through the server, so the editor writes the
        # recorded path a moment after R has returned.
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
        do_act "$name" qmd || return
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

        # quarto writes the html and then removes what it used to build it, so
        # the assertions that follow have to wait for it to be done with the
        # directory and not for the html to appear in it.
        if r_is_idle "$name" qmd 420; then
            if [ -f "$proj/smoke_qmd.html" ]; then
                pass "$name: quarto produced smoke_qmd.html"
            else
                fail "$name: smoke_qmd.html was not produced"
            fi
        fi
    else
        skip "$name: qmd render ($WHY_QMD)"
        # The completion assertion still needs a quarto buffer.
        do_act "$name" qmd || return
    fi

    # Chunk-option completion, which reads quarto's yaml intelligence file.
    # First from the plugin's own search, then from R_quarto_intel.
    if [ "$HAVE_QCOMPL" -eq 1 ]; then
        act qcompl
        if wait_until 30 "file_has qcompl_fig.txt 'fig-cap' && file_has qcompl_label.txt 'label'"; then
            if file_is qintel_set.txt 0; then
                pass "$name: Quarto completion found yaml-intelligence-resources.json by itself"
            else
                fail "$name: R_quarto_intel was set, so auto-discovery was not exercised"
            fi
        else
            fail "$name: Quarto chunk-option completion is empty or wrong (auto-discovery)"
            info "fig-: $(tr '\n' ' ' < "$OUT/qcompl_fig.txt" 2>/dev/null)"
            info "label: $(tr '\n' ' ' < "$OUT/qcompl_label.txt" 2>/dev/null)"
            info "warning: $(grep -F 'yaml-intelligence-resources' "$OUT/messages.txt" 2>/dev/null | tail -1)"
        fi
    else
        skip "$name: Quarto chunk-option completion, auto-discovery ($WHY_QCOMPL)"
    fi

    if [ -n "$QUARTO_INTEL" ]; then
        ln -sfn "$QUARTO_INTEL" "$HOME/quarto-intel.json"
        act qcompl_opt
        if wait_until 30 "file_has qcompl_opt.txt 'fig-cap'"; then
            pass "$name: Quarto completion honours R_quarto_intel"
        else
            fail "$name: Quarto chunk-option completion is empty or wrong (R_quarto_intel)"
            info "fig-: $(tr '\n' ' ' < "$OUT/qcompl_opt.txt" 2>/dev/null)"
            info "warning: $(grep -F 'yaml-intelligence-resources' "$OUT/messages.txt" 2>/dev/null | tail -1)"
        fi
        rm -f "$HOME/quarto-intel.json"
    else
        skip "$name: Quarto chunk-option completion, R_quarto_intel (the harness did not find yaml-intelligence-resources.json; set VIMR_SMOKE_QUARTO_INTEL)"
    fi
}

# ----------------------------------------------- note comment assertions -----

# Asserts what does not depend on R: the highlighting of the note comments.
# The expected colors are what the documented formula produces out of the
# color of Comment and the foreground of Normal of each colorscheme, and they
# are the same in Vim and in Neovim and with and without 'termguicolors'.
run_note_checks() { # run_note_checks <name>
    local name="$1"

    do_act "$name" notehl || return

    local want
    for want in 'rNote1 -> Note_1 [bold,underline] | #. Section one' \
                'rNote2 -> Note_2 [bold] | #.. Subsection 1.1' \
                'rNote3 -> Note_3 [] | #... Sub-sub 1.1.1' \
                'rNote3 -> Note_3 [] | #.... Four dots' \
                'rComment -> Comment [] | # Section three'; do
        if file_has note_syn.txt "$want"; then
            pass "$name: $want"
        else
            fail "$name: the syntax of the notes is not '$want'"
            info "recorded: $(tr '\n' '/' < "$OUT/note_syn.txt" 2>/dev/null)"
        fi
    done

    for want in 'morning #00008c #0000d1 19 20' \
                'desert #afe4f4 #87d7ef 195 117'; do
        if file_has note_colors.txt "$want"; then
            pass "$name: colors derived from the colorscheme: $want"
        else
            fail "$name: the colors derived from the colorscheme are not '$want'"
            info "recorded: $(tr '\n' '/' < "$OUT/note_colors.txt" 2>/dev/null)"
        fi
    done

    # ':colorscheme' runs ':highlight clear' before triggering ColorScheme, so
    # this fails unless the plugin noted the user's definition beforehand.
    if file_has note_user_hl.txt 'morning #b73e30' &&
            file_has note_user_hl.txt 'habamax #b73e30' &&
            file_has note_user_hl.txt 'desert #b73e30'; then
        pass "$name: a ':hi Note_1' of the user's survives a colorscheme change"
    else
        fail "$name: a ':hi Note_1' of the user's did not survive a colorscheme change"
        info "recorded: $(tr '\n' '/' < "$OUT/note_user_hl.txt" 2>/dev/null)"
    fi

    if file_has note_user_hl.txt 'reset #afe4f4'; then
        pass "$name: RNoteHlReset() hands Note_1 back to Vim-R"
    else
        fail "$name: RNoteHlReset() did not hand Note_1 back to Vim-R"
        info "recorded: $(tr '\n' '/' < "$OUT/note_user_hl.txt" 2>/dev/null)"
    fi

    # An achromatic Comment has no hue to keep: a shift along the axes of the
    # 6x6x6 cube would round them unevenly and invent one.
    if file_has note_gray.txt 'gray 254 255 250 ramp 1 apart 1'; then
        pass "$name: an achromatic base stays achromatic, apart on the ramp"
    else
        fail "$name: an achromatic base did not stay achromatic"
        info "recorded: $(tr '\n' '/' < "$OUT/note_gray.txt" 2>/dev/null)"
    fi

    do_act "$name" notenav || return

    # The level of every line of the fixture, and where the cursor lands. A
    # count is the deepest level to stop at, so 'next1' walks the level 1
    # titles alone: lines 4, 12 and the RStudio section on line 14.
    for want in 'gs :call RNoteGoTo(1)<CR>' \
                'gS :call RNoteGoTo(-1)<CR>' \
                'go :call RNoteOutline()<CR>' \
                'plug :call RNoteGoTo(1)<CR>' \
                "levels $SMOKE_NOTE_LEVELS" \
                'next 4 6 8 10 12 14 16' \
                'next1 4 12 14' \
                'prev1 14 12 4'; do
        if file_has note_nav.txt "$want"; then
            pass "$name: note navigation: $want"
        else
            fail "$name: note navigation is not '$want'"
            info "recorded: $(tr '\n' '/' < "$OUT/note_nav.txt" 2>/dev/null)"
        fi
    done

    # The quickfix window strips the leading whitespace of the text field, so
    # the indentation only survives through a 'quickfixtextfunc'.
    for want in 'lnums 4 6 8 10 12 14 16' \
                'qflist 0' \
                '    4  Section one' \
                '    6      Subsection 1.1' \
                '    8          Sub-sub 1.1.1' \
                '   14  Section three'; do
        if file_has note_outline.txt "$want"; then
            pass "$name: note outline: $want"
        else
            fail "$name: the note outline has no line '$want'"
            info "recorded: $(tr '\n' '/' < "$OUT/note_outline.txt" 2>/dev/null)"
        fi
    done

    do_act "$name" notefold || return

    for want in 'default manual' \
                'set expr RNoteFoldExpr(v:lnum) RNoteFoldText()' \
                "levels $SMOKE_NOTE_FOLDLEVELS" \
                'text 4 #. Section one  [8 lines]' \
                'text 6 #.. Subsection 1.1  [6 lines]' \
                'text 14 # Section three ----  [4 lines]' \
                'text 16 #.... Four dots are still a note of level 3  [2 lines]' \
                'restored manual'; do
        if file_has note_fold.txt "$want"; then
            pass "$name: note folding: $want"
        else
            fail "$name: note folding is not '$want'"
            info "recorded: $(tr '\n' '/' < "$OUT/note_fold.txt" 2>/dev/null)"
        fi
    done
}

# ------------------------------------------- bibliographic completion checks --

# Asserts the citation keys, the authors and the years that completion returns.
# Nothing here goes through R: the bib entries come from the BibComplete job,
# which is R/bibtex.py driven by the editor, so this is asserted before R is
# started and a failure of R's cannot hide a failure of this.
run_bib_checks() { # run_bib_checks <name> <proj-dir>
    local name="$1" proj="$2"

    if [ "$HAVE_BIB" -eq 0 ]; then
        skip "$name: bibliographic completion in Rmd, Quarto and Rnoweb ($WHY_BIB)"
        return
    fi

    if ! do_act_until "$name" bib \
            "file_has bib_rmd.txt 'all n=2' &&
             file_has bib_quarto.txt 'all n=2' &&
             file_has bib_rnoweb.txt 'all n=2'" 60; then
        fail "$name: the BibComplete job never returned the bib entries"
        local t
        for t in rmd quarto rnoweb; do
            info "bib_$t: $(tr '\n' '/' < "$OUT/bib_$t.txt" 2>/dev/null)"
        done
        info "warning: $(grep -F 'BibComplete' "$OUT/messages.txt" 2>/dev/null | tail -1)"
        return
    fi

    # The keys are ordered as the bib file orders them. 'key' matches the
    # citation key, 'author' the last name of an author of the other entry, and
    # 'omni' is the same match reached through 'omnifunc'. The bib file is
    # asserted by its full path: a 'bibliography:' of a YAML header is written
    # relative to the document.
    local t want
    for t in rmd quarto rnoweb; do
        for want in "bibf $proj/smoke_refs.bib" \
                    'all n=2 smokebibone2001 smokebibtwo1998' \
                    'item smokebibone2001 | Alpha, Beta | (2001) A study of alphabetic things' \
                    'item smokebibtwo1998 | Gamma | (1998) Delta and the art of gamma' \
                    'key n=1 smokebibtwo1998' \
                    'author n=1 smokebibtwo1998' \
                    'none n=0' \
                    'omni n=1 smokebibtwo1998'; do
            if file_has "bib_$t.txt" "$want"; then
                pass "$name: bib completion ($t): $want"
            else
                fail "$name: bib completion ($t) has no line '$want'"
                info "recorded: $(tr '\n' '/' < "$OUT/bib_$t.txt" 2>/dev/null)"
            fi
        done
    done
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

    # Nothing below depends on R, so it is asserted before R is started.
    run_note_checks "$name"
    run_bib_checks "$name" "$proj"

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
       -o -name '*.tmp.R' -o -name '*.aux' -o -name '*.synctex.gz' \
       -o -name 'objlist' \) \
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
