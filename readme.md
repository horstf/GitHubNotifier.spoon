# Hammerspoon GitHub inbox notifier

Check your GitHub notification inbox periodically via the
[`gh`](https://cli.github.com) CLI and show it in a menubar app.

The number is how many notifications are **unread**, and the GitHub mark is
solid while any are. When nothing is unread the mark fades, and no number is
ever shown as a zero. The item always stays in the menu bar, so a quiet menu
bar never looks the same as a crashed spoon.

| Unread | Menu bar |
| --- | --- |
| 1 or more | solid mark + count |
| none | faded mark, no number |
| error | faded mark + `?` |

### Why this tracks unread, not "anything in the inbox"

It would be nicer to keep the mark solid while anything is still sitting in the
inbox, read or not, and fade it only once you have actually cleared everything.
The REST API cannot support that, because it has no concept of GitHub's
**Done**.

`GET /notifications?all=true` means "include notifications I have read". It is
not inbox membership. Marking a notification Done removes it from
github.com/notifications, but the API keeps returning it indefinitely — the
response's `Last-Modified` does not even change, so it is not a caching delay.
A mark driven by that list would go solid on your first read notification and
never fade again.

Unread is the only state the API reports reliably, so that is what this tracks.

The dropdown lists each notification, unread first and most recent first within
that, marked with a filled or hollow dot. Clicking one opens it in your
browser; pull requests, issues and commits resolve to the exact page, and other
subject types fall back to the repository.

Below the list, **Mark all as read** clears the unread state of the whole
inbox in one go. That is GitHub's *read*, not *Done*: the notifications stay in
the web inbox, they just stop being bold. With the default `includeRead = false`
the list empties out and the mark fades. The item is greyed out when nothing is
unread. GitHub applies this asynchronously, so the spoon refreshes right away
and once more a few seconds later.

## Requirements

The `gh` CLI, installed and authenticated:

```sh
brew install gh
gh auth login
```

The spoon calls `gh api notifications`, so it reuses whatever credentials
`gh auth status` reports — there is no token to configure here. The `repo`
scope is enough for repository notifications. If you find the count lower than
what github.com/notifications shows, widen it with:

```sh
gh auth refresh -s notifications
```

## Loading the spoon

Clone or symlink this repo into `~/.hammerspoon/Spoons/`, then:

```lua
hs.loadSpoon('GitHubNotifier')
spoon.GitHubNotifier:start()
```

# Configuration

- `interval`: Interval in seconds to refresh (default 120).
- `limit`: Maximum notifications to fetch (default 100).
- `ghPath`: Path to the `gh` binary. Autodetected from the usual Homebrew and
  MacPorts locations; set it explicitly if `gh` lives somewhere else.
- `hideWhenEmpty`: Remove the menubar item entirely when the inbox is empty
  (default `false`, i.e. a faded mark stays visible).
- `includeRead`: Also count notifications you have already read (default
  `false`). Off by default for the reason above — read notifications never
  leave `notifications?all=true`, even after you mark them Done, so turning
  this on means the mark goes solid and stays that way:

  ```lua
  spoon.GitHubNotifier:start({ includeRead = true })
  ```

## The icon

The menubar artwork is `github-mark.svg` in this directory, loaded at startup.
It is kept as SVG so it stays crisp at any menu bar size and in any display
scaling. Replace that file to use different artwork — anything `hs.image` can
load will do, and a single-colour silhouette works best because macOS renders
it as a template image and tints it to match the menu bar.

## Notes

- `gh` stores its token in the macOS keychain. The first time Hammerspoon runs
  `gh`, macOS may ask you to allow keychain access — choose "Always Allow" so
  the background refreshes work unattended.
- `GitHubNotifier:refresh()` fetches immediately, and the dropdown has a
  "Refresh now" item that does the same.
- `GitHubNotifier:markAllAsRead()` marks the whole inbox read, the same as the
  "Mark all as read" dropdown item. It calls `gh api --method PUT
  notifications`, which needs the `notifications` scope — if it errors with a
  permission message, run `gh auth refresh -s notifications`.
