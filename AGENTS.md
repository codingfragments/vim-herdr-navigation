# vim-herdr-navigation: agent conventions (Claude Code, pi, …)

Seamless `Ctrl+h/j/k/l` across Vim/Neovim splits and multiplexer panes,
like `vim-tmux-navigator`:
- **herdr side:** the Rust `navigate` binary in `src/`.
- **Editor side:** `editor/nvim.lua` and `editor/vim.vim`.
- **Rex side (planned):** `rex/vim_nav.lua`.

## Current work

- **[rex-migration.md](rex-migration.md)**: pure-Lua support for Rex,
  with no Rust involved.
  - Read it first and work its phases in order, one `phase/rex-N-…`
    branch and PR each.
  - Update its Status lines, checkboxes and spike table as you go.
  - Phase 0 (spikes) comes first.
- **herdr behaviour must not regress:** the herdr and tmux branches in
  `editor/*` stay intact, and `src/` stays as it is.

## Gitflow

- **Always create a branch before making any change or commit**, even for
  one-line fixes.
- Branch prefixes:
  - `bug/`: bug fixes
  - `feature/`: new features
  - `phase/`: larger multi-commit work, e.g. each phase in rex-migration.md
  - `docs/`: documentation only
  - `release/<version>`: release prep (version bump and CHANGELOG)
- If the type is unclear, ask before creating the branch.
- Every branch lands via a squash-merged PR to `main`. No direct commits
  to `main`.
- Stay on the working branch until the PR is explicitly merged; switch
  back to `main` only after the merge.

## Workflow

- Commit frequently within a branch as work progresses.
- Do not push, open a PR or merge without the user's approval. Summarise
  what's testable and wait for "push" or "looks good".
- End each phase with what to test, how to trigger it, and what works
  versus what's still a stub.
- Tests: `just test` (the herdr dry-run harness). The Rex Lua core is
  tested through `rex do` in a throwaway selftest session (see
  rex-migration.md).

## Release process

1. Code PRs (`bug/`, `feature/`, `phase/`) contain code changes only;
   merge them first.
2. The release PR (`release/<x.y.z>`) contains the version bump in
   `herdr-plugin.toml` and `Cargo.toml` plus the CHANGELOG / release
   notes.
3. Merge the release PR, then tag the merge commit
   (`git tag v<x.y.z> && git push origin v<x.y.z>`) and publish the
   GitHub release.

> Never push a `v*.*.*` tag from a feature branch or before the release
> PR is merged.
