# Contributing

After cloning the repository, run the following commands from a terminal:

```bash
# Create a local git hooks directory
mkdir -p .git/hooks

# Create a symlink for the pre-commit hook
cd .git/hooks
ln -sf ../../hooks/pre-commit
```

Currently, the pre-commit hook checks whether all staged C files in the
repository are formatted correctly.

Make sure `clang-format` is installed on your system.

## Smoke test

Before opening a pull request, run the end-to-end smoke test, which starts R
in both Vim and Neovim and checks that the plugin can send code to R and
update the Object Browser:

```bash
./test/smoke_test.sh
```

It needs `tmux`, `R` with a C compiler, `vim` and `nvim`, takes about half a
minute, and exits non-zero on any failure. It runs in a scratch directory
under `/tmp` with its own `$HOME` and `$R_LIBS_USER`, so it never touches your
R library nor your editor configuration.
