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
