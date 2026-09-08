# Changelog

## 0.3.0 — unreleased

- **Self-update check** — the service reads its own `manifest.json` version and,
  every `updateCheckHours` (default 12), fetches `manifest.json` from the repo's
  default branch to compare. When a newer version is out, the popup shows an
  "Update available: vX.Y.Z" banner with an Update button (runs
  `omarchy plugin update`) and a link to the release notes. `checkForUpdates`
  opts out of the periodic GitHub request.

- Security review follow-up: every network call now enforces a response-size
  cap and refuses redirects on the bearer-token request. QML `curl` fetches
  pass `--max-filesize` / `--max-redirs 0` and the collectors drop an over-cap
  body; `_mwlib.http()` validates `Content-Length`, reads at most
  `MAX_RESPONSE_BYTES`, and blocks redirects so a token-bearing request can
  never reach an unintended origin.
- Fix: popup settings toggles (show-points, notify, poll interval) now take
  effect live instead of only after a shell restart.

- **"Something new" pill state** — the bar pill tracks what you'd seen the last
  time the popup was open (separate from MakerWorld's server read-state). When
  unread notifications, point balance, or follower count have risen since then,
  the cube mark + number turn the theme accent colour, the unread badge is a
  filled dot, and a `▲` shows next to the points. Opening the popup clears it;
  the hover tooltip breaks down what's new. Nothing needs marking read on the
  MakerWorld site.

- **"My models" popup tab** — lists your published designs from
  `/v1/design-service/my/design/published` with per-model downloads, likes,
  prints and comment counts; sort by downloads / likes / prints; click a row
  to open the model. Fetched lazily the first time the tab is opened. The
  popup now has an Activity / My models tab strip.

- **Download / like milestones** — the profile poll tracks lifetime downloads
  and likes received across your models; crossing a round number fires a
  "Your models passed N downloads" notification. Cadence scales with size
  (250s below 1k, 1,000s in the thousands, 5,000s past 10k, …). Toggle with
  `notifyMilestones` (default on). Popup shows the running totals.

- **Follower alerts** — the profile poll now tracks `fanCount`; a rise fires a
  "N new followers" notification (gated by the `follow` notify type). This is
  the follow path, since no message-API category surfaces new followers.
- **Boost-token expiry warnings** — when you hold a boost token, the service
  reads MakerWorld's own `pointBoostingRightExpireRemind` message (and the
  grant's `expireAt`) and warns once, `boostExpiryWarnDays` (default 5) before
  it lapses. Also notifies when a new boost token becomes available. Both
  gated by the `points` notify type; dormant while you have zero tokens.
- Popup shows boost-token count and follower count next to the points hero;
  right-click status notification includes them.
- Parses `newBadgeReceived` messages ("New badge: …") and links boost/points
  messages to the creator-center boost page.

- `makerworld-login --from-slicer` — import an existing Bambu Cloud token from
  a signed-in Bambu Studio / Orca Slicer config, skipping the password. Also
  offered automatically by bare `makerworld-login` when a slicer config is
  found. Detects and explains the common case where the slicer encrypts its
  token (modern builds) and can't be imported.
- README setup section rewritten around three token routes: slicer import,
  Bambu account login, browser paste.

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
