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
#      Object_Browser buffer.
#
# Steps 3-5 are the point of the test: they only succeed if the whole chain
# vimcom -> vimrserver -> editor is alive. An editor that starts and does
# nothing fails.
#
# How to run it:
#
#   ./test/smoke_test.sh            # from anywhere; no arguments
#
# Set VIMR_SMOKE_KEEP=1 to keep the scratch directory for inspection.
#
# Exit status is 0 only if every assertion passed in *both* editors.
#
# Requirements: bash, tmux, R (with a C compiler), vim, nvim.
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

# ---------------------------------------------------------------- reporting --

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
head1() { printf '\n== %s ==\n' "$*"; }

pass() { green "  PASS  $*"; }
fail() { red   "  FAIL  $*"; FAILURES=$((FAILURES + 1)); }

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

fingerprint_real_libs() {
    local lib
    for lib in "${REAL_LIBS[@]}"; do
        if [ -e "$lib/vimcom" ]; then
            printf '%s\t%s\n' "$lib/vimcom" \
                "$(find "$lib/vimcom" -type f -printf '%P %s %T@\n' 2>/dev/null |
                   sort | sha256sum | cut -d' ' -f1)"
        else
            printf '%s\tABSENT\n' "$lib/vimcom"
        fi
    done
}

REAL_LIBS_BEFORE="$(fingerprint_real_libs)"

# ------------------------------------------------------------ scratch layout --

WORK="$(mktemp -d /tmp/vimr-smoke.XXXXXXXX)" || die "mktemp failed"
FAKE_HOME="$WORK/home"
R_LIB="$WORK/Rlib"
OUT="$WORK/out"
PROJ="$WORK/proj"
mkdir -p "$FAKE_HOME" "$R_LIB" "$OUT" "$PROJ" "$WORK/tmp" \
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
export R_PROFILE_USER="$WORK/Rprofile"  # empty: ignore the user's ~/.Rprofile
: > "$WORK/Rprofile"
unset R_LIBS R_LIBS_SITE R_ENVIRON_USER 2>/dev/null || true

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

# ------------------------------------------------------------ fixture & init --

cat > "$PROJ/smoke.R" <<'EOF'
cat("VIMR_SMOKE_SUM:", sum(1:100), "\n")
smoke_df <- data.frame(alpha = 1:3, beta = c("x", "y", "z"))
smoke_chr <- "VIMR_SMOKE_CHR"
EOF

# Minimal editor configuration: only this repository, no swap/undo/shada
# files, no user configuration.
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
EOF

make_wrapper() { # make_wrapper <name> <editor-command...>
    local name="$1"; shift
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
export R_PROFILE_USER='$WORK/Rprofile'
cd '$PROJ' || exit 1
exec $* '$PROJ/smoke.R'
EOF
    chmod +x "$WORK/run_$name.sh"
}

make_wrapper vim  "vim -u '$WORK/rc.vim' -i NONE"
make_wrapper nvim "nvim -u '$WORK/rc.vim'"

# Sourced repeatedly to copy the editor's state out to files. Everything the
# assertions look at comes from here.
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

run_editor() { # run_editor <name>
    local name="$1"
    SESSION="vimr-smoke-$name-$$"
    rm -f "$OUT"/*

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
run_editor vim
VIM_FAILURES=$((FAILURES - FAILURES_BEFORE_VIM))
FAILURES_BEFORE_NVIM="$FAILURES"
run_editor nvim
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
       -o -name '*.tmp.R' \) -print 2>/dev/null)"
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

if [ "$FAILURES" -eq 0 ]; then
    green "SMOKE TEST PASSED"
    exit 0
fi
red "SMOKE TEST FAILED ($FAILURES assertion(s))"
exit 1
