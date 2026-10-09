# review.nvim

**English** · [日本語](README_ja.md)

A Neovim plugin to review branch (git ref) and PR diffs the way GitHub's Files changed page does — collect comments and export them as a **prompt for your AI agent**.

Diffs open in a dedicated tabpage with three windows (file panel │ base │ head). Added files have no base side, so the base window is closed and only the head is shown, full width. The head window is the real file, so editing and LSP keep working while you review. Diffs are colored GitHub-style through window-local 'winhl' (same mechanism as diffview.nvim's `enhanced_diff_hl`): changed words are tinted green (head) / red (base), deleted lines show in the delete color on the old side, and filler lines are dimmed. Comments are persisted to disk automatically and a Neovim restart is recovered with one `:Review`. Zero runtime dependencies (Neovim core API only).

## Requirements

| Requirement       | Scope                    |
| ----------------- | ------------------------ |
| Neovim >= 0.10    | everything               |
| git               | everything               |
| GitHub CLI (`gh`) | `:Review pr` only        |

## Install

```lua
{
  'skanehira/review.nvim',
  lazy = false,
  opts = {},
}
```

`setup()` is optional (it works as-is with the defaults). Add it only to change keys or appearance. Available options: `:h review-setup`.

If you add the repo to `rtp` without a plugin manager, run `:helptags <repo>/doc` once to make `:h review` available.

## Try it

Four steps from zero to reviewing the current branch against `main`:

**1. Open the diff**

```vim
:Review start main
```

The `main..current branch` diff opens in three windows (added files close the base window and show only the head). The review target is the working tree of the current checkout, so uncommitted changes are included. To state the head explicitly use `:Review start main feature` (review `feature` against `main`). For a PR: `:Review pr 42` (the PR's base branch is compared as the remote-tracking ref, e.g. `origin/main`, so it need not exist locally; the base, and for a fork PR the PR head, are fetched only when they are behind GitHub; a head branch that exists in this repository is used as is). While a review is starting, the message area shows the current step (resolving the PR, fetching, creating the worktree, loading the diff).

**2. Write comments**

Move between files with `<Tab>` / `<S-Tab>` and press `c` on a changed line to enter the body (select lines in visual-line for a range comment). Confirmed comments show as a thread box under the line; edit with `e`, delete with a confirmation double-press of `d` (when several comments share the line — e.g. a thread root and a reply — pick one with a prompt and it is deleted right away). Every comment is saved when confirmed.

`:w` in the head window refetches the diff and updates the ±counts, comment positions and the prompt against the saved content.

**3. (PR) Comment, reply and submit like GitHub's review screen**

In a PR session (`:Review pr`) the existing review comments are fetched and shown
in the threads — each comment prefixed by its author, unsubmitted ones with a ⚠
marker; file-level comments appear in a box above line 1 of the file and the PR
conversation opens with `p` (or `:Review pr-chat`). `r` on a thread replies to
it (kept in the same thread on GitHub), `c` adds a new comment; all of these
accumulate as local pending. `s` (or `:Review submit`) pushes them and finishes
the review with an event (Comment / Approve / Request changes) plus an optional
summary (`:h review-pr-comments`).

**4. Export the prompt to your AI agent**

`:Review prompt` formats the collected comments and copies them to the clipboard (falls back to the `"0` register without a clipboard provider). A successful copy shows «copied %d comments to the clipboard» (`y` does the same per line):

```text
Review the changes in main..feature. Please address the comments below.

@lua/review/diff.lua#L42-L48
route this line calculation through the conversion logic in core/diff

@lua/review/init.lua#L10
setup should be idempotent
```

Paste it straight into your AI agent. `@path#L<line>` points at the real file under review, so the agent can follow the path and read the code. To copy a single comment, go to its line in the review window and press `y`; for one file only, `:Review prompt lua/foo.lua`. outdated comments (positions no longer resolvable after diff drift) are excluded from the default output (`:h review-sessions`).

Comments you no longer need after copying can be removed with `:Review clear` (or pressing `D` twice in the review window / comments list): a cleanup pass for the leftovers after handing the prompt to the AI — everything disappears, outdated included. Nothing is deleted automatically after a copy — that would leave you stranded after a mis-copy — so deletion always goes through an explicit action plus confirmation (`[y/N]` for the command, an arming double-press for the key). The double-press can also be aborted with `<Esc>` (no 2s wait).

**5. Close**

`q` (or `:Review close`) saves the comments and closes. Worktrees created by `:Review pr` are kept (so a closed session reopens quickly, reusing the same worktree, including any uncommitted edits). To remove a worktree, delete the session with `:Review delete {id}` (or `d` in `:Review list`); it asks for confirmation and a `--force` confirmation if the worktree has uncommitted changes.

## Keymaps

The minimum touched by the flow above:

| Where          | Key                       | Action                                                       |
| -------------- | ------------------------- | ------------------------------------------------------------ |
| review window  | `c` (visual-line = range) | add a comment (head window only)                             |
| review window  | `e` / `d`                 | edit / delete (d is a confirmation double-press)             |
| review window  | `D`                       | delete all comments (double-press; same as `:Review clear`)  |
| review window  | `<Esc>`                   | cancel the d / D arming                                      |
| review window  | `<Tab>` / `<S-Tab>`       | next / previous file                                         |
| review window  | `[c` / `]c`               | previous / next comment in this file (head window only)      |
| review window  | `<leader>e` / `<leader>b` | go to the file panel / toggle it                             |
| review window  | `<leader>c`               | cross-file comments list                                     |
| review window  | `r`                       | reply to the thread on the cursor line (head window only)    |
| review window  | `s`                       | submit the review (push pending + event; PR sessions only)   |
| review window  | `p`                       | open the PR conversation (general comments; PR sessions only)|
| review window  | `q`                       | save and close the session                                   |
| review window  | `<F1>` / `g?`             | help float listing the keys available in that window         |

All keys are buffer-local and which keys are live depends on the window. The full list and defaults per window: `:h review-keymaps` (during a review, `<F1>` / `g?` opens the help float for that window). Override defaults via `keymaps` in `setup`:

```lua
require('review').setup({ keymaps = { diff = { add_comment = 'gc' } } })
```

folds (`za` / `zo` / `zR`) stay Neovim defaults — the plugin maps nothing there. In the review windows `[c` / `]c` are bound to comment navigation (previous / next comment; the built-in hunk movement remains in your own windows). Review-window keymaps fire only when the window role matches at press time, so the same real file opened in your own window never mis-fires.

## Commands

| Command                         | Action                                                       |
| ------------------------------- | ------------------------------------------------------------ |
| `:Review start {base} [{head}]` | start a branch review (head omitted = current branch)        |
| `:Review pr {number\|URL}`      | start a PR review (head expanded in a worktree)              |
| `:Review`                       | resume a saved session (open status only)                    |
| `:Review list`                  | open from the saved-session list                             |
| `:Review comments`              | open the cross-file comments list (same as `<leader>c`)      |
| `:Review pr-chat`               | open the PR conversation (general comments; same as `p`)     |
| `:Review submit`                | submit the review (push pending + event; same as `s`)        |
| `:Review close`                 | save and close                                               |
| `:Review delete {id}`           | delete a saved session (includes worktree cleanup)           |
| `:Review prompt [file]`         | copy the prompt to the clipboard (optionally one file)       |
| `:Review clear`                 | delete all comments ([y/N] confirm; same as `D` twice)       |

The ref for `start`, the number for `pr` and the id for `delete` are `<Tab>`-completable. Recovery after an abnormal Neovim exit, the difference between `q` and `:tabclose`, and other session-management details: `:h review-sessions`.

## Design behaviors (selected)

- When an explicit head points at a commit other than the current checkout, the plugin offers `git switch` to that branch with a confirmation; on refusal or failure it degrades to a read-only review (`:h review-usage`)
- Comments whose position is no longer resolvable after diff drift are surfaced as outdated (outdated id prefixes in warning color, aggregated at line 1 of the head window) (`:h review-sessions`)
- The winbar shows `base..head · path · +a -d · N comments`; line numbers are hidden by default. Both can be toggled via `winbar` / `number` in `setup` (`:h review-display`)
- Runtime messages (notifications, [y/N] prompts, help float) are English only — there is no message-locale option

## Documentation

- Help contents: `:h review` (Usage / API / Setup / Keymaps / Sessions / PR Comments / Display)
- Japanese help: `:h review_ja` (a translation of this help; `set helplang=ja` makes `:h review-*` resolve to it)
- Public Lua API: `:h review-api`
- Design: [docs/design/DESIGN.md](docs/design/DESIGN.md) and [docs/design/features/](docs/design/features/)
- Development / verification: `make check` (test / lint / format / plugin-check) and `make e2e` (real headless nvim + real git golden path). Tests need plenary.nvim (set via `PLENARY_PATH`)

## License

[MIT](LICENSE)
