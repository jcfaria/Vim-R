# Comment and uncomment code

This is a feature that might be removed in the near future because it is
better to use a plugin that (un)comments code in many languages than to have
different key bindings just for R. Anyway, below is the old
documentation on this feature.

Vim-R can comment and uncomment code, but this feature is turned off by
default because most people use a comment plugin for this task. To turn it on,
put in your `vimrc`:

```vim
let R_enable_comment = 1
```

Then, you can toggle the state of a line as either commented or uncommented by
typing <LocalLeader>xx. The string used to comment the line will be "# ", "##
" or "### ", depending on the values of `R_indent_commented` and
`r_indent_ess_comments`.

You can also add the string "# " to the beginning of a line by typing
<LocalLeader>xc and remove it with <LocalLeader>xu. In this case, you can set
the value of `R_rcomment_string` to control what string will be added
to the beginning of the line. Example:

```vim
let R_rcomment_string = '# '
```

Finally, you can also add comments to the right of a line with the
<LocalLeader>; shortcut. By default, the comment starts at the 40th column,
which can be changed by setting the value of `r_indent_comment_column`, as
below:

```vim
let r_indent_comment_column = 20
```

If the line is longer than 38 characters, the comment will start two columns
after the last character in the line. If you are running <LocalLeader>; over a
selection of lines, the comments will be aligned according to the longest
line.

Note: While typing comments, the comment leader string is automatically added
to new lines when you reach 'textwidth' but not when you press <Enter>.
Please, read the Vim help about 'formatoptions' and `fo-table`. For example,
you can add the following line to your `vimrc` if you want the comment string
to be added after <Enter>:

```vim
autocmd FileType r setlocal formatoptions-=t formatoptions+=croql
```

To turn off the automatic indentation, put in your `vimrc`:

```vim
let R_indent_commented = 0
```

The string used to comment text with <LocalLeader>xc, <LocalLeader>xu,
<LocalLeader>xx and <LocalLeader>o is defined by `R_rcomment_string`.
Example:

```vim
let R_rcomment_string = '# '
```

If the value of `r_indent_ess_comments` is 1, `R_rcomment_string` will be
overridden and the string used to comment the line will change according to
the value of `R_indent_commented` ("## " if 1 and "### " if 0; see
`ft-r-indent`).

Below is the list of the names for custom key bindings:

   RSimpleComment
   RSimpleUnComment
   RToggleComment
   RRightComment

Note: It seems that, on OS X, if you put the command `syntax enable` in your
`vimrc` (or `init.vim`), file type plugins are sourced immediately.
Consequently, some Vim-R variables, such as `R_enable_comment`, are used with
their default values even if you have set them in the same file. The
workaround is not to include the superfluous command `syntax enable`. For
details, see <https://github.com/jalvesaq/Vim-R/issues/668>.
