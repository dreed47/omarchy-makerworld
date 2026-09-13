# Changelog

## 0.3.0 — unreleased

- Self-review follow-up (same argv/shell/symlink classes as the marketplace
  rounds below, caught by re-auditing after they landed): `makerworld-token
  --refresh-token RT` put a refresh token in argv/`ps`/`/proc/<pid>/cmdline`
  and shell history — it's now prompted for via `getpass` alongside the
  access token instead. `bin/_mwlib.py`'s slicer-config import
  (`find_slicer_token`) read candidate files with a plain `open()`; it now
  goes through the same fd-bound, `O_NOFOLLOW`, owner-checked read as our own
  `token.json`/`config.json`, so a symlink planted in a slicer's config dir
  can't redirect the scan at an arbitrary file. `BarWidget.qml`'s right-click
  notification (`notify()`) was the one remaining call into `bar.run()` →
  `bash -lc`; it now execs `omarchy-notification-send` directly as an argv
  array via `Quickshell.execDetached`, matching every other notification path
  in the plugin.

- Security review follow-up: the bearer token no longer travels as a `curl`
  command-line argument. Every authenticated request (`Service.qml`'s five
  requests, `Panel.qml`'s two) now feeds curl its headers/method/body/URL as
  a config file over `curl -q -K -`'s stdin via `AuthedRequest.qml`, so `ps` /
  `/proc/<pid>/cmdline` never show the token - verified with a live
  canary-token check. Config values are escaped against curl-config injection
  and stripped of CR/LF (header injection); `--max-filesize` and no-redirect
  hardening still apply.

- Security review follow-up: removed the `bash -c "curl -K - | head -c …"`
  pipeline that carried the token to curl's stdin — an inherited `BASH_ENV`
  runs before the command, and bare `bash`/`curl`/`head` were PATH-resolved,
  so a substituted program or startup file on the path could have read the
  credential stream. `AuthedRequest.qml` now execs `/usr/bin/curl` directly
  (no shell, `command:` is a literal argv array) with `clearEnvironment: true`
  and an explicit `{PATH, LC_ALL}` environment, and replaces `head -c` with a
  streamed byte-count in a `SplitParser` that SIGTERMs (then SIGKILLs) curl
  the instant the budget is crossed — a cap that, unlike `--max-filesize`,
  also holds against chunked responses with no declared `Content-Length`.
  Verified live: 387 `/proc/<pid>/{cmdline,environ}` samples across a real
  authenticated request showed only `curl -q -K -` / `PATH`, `LC_ALL` — no
  token, no inherited `HOME`, no shell. Also moved every other bare-name
  `Process` exec in the repo (`omarchy-launch-browser`, `omarchy-bar`,
  `pw-play`, `xdg-open`, `python3`) to its absolute path, and
  `makerworld-refresh`'s `python3` now also runs with `-I` (isolated mode)
  and a minimal `clearEnvironment` environment; `bin/_mwlib.py`'s keyring
  lookup resolves `secret-tool`'s absolute path once via `shutil.which` and
  reuses it instead of letting each `subprocess.run` re-resolve the bare name
  through `PATH`.

- Security review follow-up: `token.json` / `config.json` are now written with
  `O_CREAT | O_EXCL | O_NOFOLLOW` on a unique same-directory temp name at mode
  0600, then atomically renamed — a pre-planted symlink at the temp or
  destination path fails the write instead of redirecting it. The Python token
  read is fd-bound (`O_NOFOLLOW`, regular-file + owner + size checks).

- **Update check (read-only)** — the service reads its own `manifest.json`
  version and, every `updateCheckHours` (default 12), fetches `manifest.json`
  from the repo's default branch to compare. When a newer version is out the
  popup shows a note with the version and a link to the release notes; applying
  it is a manual `omarchy plugin update`. The plugin never fetches or runs
  code. `checkForUpdates` opts out of the periodic GitHub request.

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
