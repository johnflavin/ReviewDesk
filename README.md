# Review Desk

A macOS app that watches GitHub for pull requests requesting your review, reviews them with your
local `claude` CLI, and lets you edit, post, or discard each draft.

- Polls GitHub using personal access tokens kept in the keychain, or optionally your `gh` login (Settings → GitHub).
- Can also list every open pull request in organizations or repositories you watch, and any pull request
  you add by URL.
- Review settings (model, limits, instructions, automatic reviews, and what happens to a finished review)
  apply to all repositories and can be overridden per organization and per repository (Settings → Reviews).
- Runs reviews with `claude -p`, using your existing Claude login (subscription, not API billing).
- Discuss a draft with the Claude session that wrote it, in the app or in a terminal. Claude can revise the
  draft either way; in a terminal it does so by editing the draft's `draft.json`, which the app watches.
- Reviews in a temporary worktree of your existing local clone; repositories without one are cloned
  into `~/Library/Application Support/ReviewDesk/clones`.
- The agent can only read the checkout. The PR's own `.claude` settings, hooks, and MCP servers are ignored.
- Review instructions come from a scope preset (what to look for) and a voice preset (how to write).
  Any preset can be duplicated and edited.

## Build and run

Requires macOS 15, the Xcode command-line tools, and `claude`.

```
./build.sh            # or: ./build.sh release
open build/ReviewDesk.app
```

## Command line

```
build/ReviewDesk.app/Contents/MacOS/ReviewDesk --list
build/ReviewDesk.app/Contents/MacOS/ReviewDesk --review owner/repo#123 --model sonnet
```

`--review` prints the draft and the payload it would post. It never posts.
