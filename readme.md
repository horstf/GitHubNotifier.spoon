# GitHubNotifier

A Hammerspoon menu bar app that shows how many unread GitHub notifications you
have. The dropdown lists them, and clicking one opens it in your browser. It
also has a "Mark all as read" item.

## Setup

Install and log in to the [`gh`](https://cli.github.com) CLI. The spoon uses
its credentials, so there's no token to configure:

```sh
brew install gh
gh auth login
gh auth refresh -s notifications
```

Clone this repo into `~/.hammerspoon/Spoons/`, then add to your Hammerspoon
config:

```lua
hs.loadSpoon('GitHubNotifier')
spoon.GitHubNotifier:start()
```

Optional settings: `interval` (seconds, default 120), `limit` (default 100),
`ghPath`, `hideWhenEmpty` and `includeRead`.

If macOS asks whether Hammerspoon may use the keychain, choose "Always Allow".
