# Changelog

## 0.2.0 — unreleased

Phase 2: bar pill + popup.

- **Bar pill** (`bar-widget` kind): point balance plus an unread badge; a
  warning triangle when the sign-in has lapsed. Hidden until there's something
  to show. Left-click opens the popup, middle-click refreshes, right-click
  fires a status notification.
- **Popup** (`Panel.qml`): point balance, unread-by-category chips, a scrollable
  list of recent comments/replies/likes/follows/system messages (click a row to
  open it on makerworld.com), "Mark all read", and "Open MakerWorld". A gear
  toggles a compact settings form (region, notify on/off, notify categories,
  check interval, show-points) persisted to the widget's `shell.json` entry via
  `omarchy-bar set`.
- Settings now resolve **shell.json widget entry → config.json → defaults**, so
  the popup's form and a hand-edited `config.json` both work. `"on"`/`"off"`
  strings and booleans are both accepted.
- `Service.qml` publishes `points`, `unreadByType`, `unreadTotal`,
  `profileName`, and `connState` for the pill/popup, polls the profile on its
  own timer regardless of the points-notification setting, and gained IPC
  `refresh` / `markRead`.
- The point-balance poll no longer requires `notify` to be on (the pill wants
  it); notifications are still gated by `notify` + `notifyTypes`.

## 0.1.0 — unreleased

Phase 1: headless notification service.

- Polls the (unofficial) Bambu Cloud account API for unread-count changes and
  raises an omarchy desktop notification for new comments, replies, likes,
  followers, system messages, and point-balance increases on your MakerWorld
  models. Clicking a notification opens the relevant page.
- `bin/makerworld-login` — one-time interactive Bambu Cloud sign-in (handles
  password, emailed verification code, and authenticator/TFA accounts).
- `bin/makerworld-refresh` — non-interactive access-token refresh, run
  automatically by the service on a 401.
- `bin/makerworld-token` — show token status, verify it, or paste one in by
  hand.
- Settings in `~/.config/omarchy/makerworld/config.json` (no bar widget yet).
- First poll after start is adopted as a silent baseline, so enabling the
  plugin does not replay your existing unread backlog.

Not in this release: bar pill with point balance / unread badge, in-panel
message list, "mark all read". Planned for 0.2.
