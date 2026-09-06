# MakerWorld for Omarchy

Your [MakerWorld](https://makerworld.com) (Bambu Lab) account in the Omarchy
bar and as desktop notifications — new comments and replies, likes, new
followers, system messages, and point-balance changes.

- **Bar pill** — point balance and an unread badge, with a warning triangle if
  the sign-in lapses.
- **Popup** — point balance, unread-by-category chips, a list of recent activity
  (click a row to open it on makerworld.com), "Mark all read", "Open
  MakerWorld", and a settings gear.
- **Notifications** — a headless service polls on an interval and raises an
  `omarchy-notification-send` notification for anything new; clicking it opens
  the page.

The pill/popup and the notifier are one plugin; you can mount just the service
(no bar widget) if you only want notifications.

## Unofficial API — read this first

MakerWorld / Bambu Lab publish **no public API**. This plugin calls the same
`api.bambulab.com` endpoints the Bambu Handy mobile app uses, learned from
community reverse-engineering. Consequences:

- It can break whenever Bambu changes the app's backend. When a payload shape
  shifts, the fix is almost always one line in `Model.js` (all endpoints and
  parsers live there).
- You sign in with your real Bambu Cloud account. The access token is stored
  in `~/.config/omarchy/makerworld/token.json` (mode `600`).
- Polling is deliberately infrequent (default 5 min, floor 2 min) to stay
  courteous to an unofficial service.

**Sources:** [Doridian/OpenBambuAPI](https://github.com/Doridian/OpenBambuAPI/blob/main/cloud-makerworld.md),
[maziggy/bambuddy](https://github.com/maziggy/bambuddy),
[forum: public API for MakerWorld](https://forum.bambulab.com/t/public-api-for-makerworld/52699).

## Install

Install via the Omarchy plugin manager, or clone into
`~/.config/omarchy/plugins/io.github.dreed47.makerworld/`.

Then sign in once:

```sh
~/.config/omarchy/plugins/io.github.dreed47.makerworld/bin/makerworld-login
```

It asks for your Bambu account, password, and region, and handles the emailed
verification code or authenticator (TFA) prompt if your account uses one. On
success it writes `token.json` and a default `config.json`, then enable the
plugin (or restart `omarchy-shell`).

If automated login fails for your account, grab a token from browser dev tools
(the `Authorization: Bearer …` header on any `makerworld.com/api` request while
logged in) and paste it:

```sh
bin/makerworld-token --paste
```

## Configuration

Two layers, highest priority first:

1. **The bar widget's settings** — the popup's gear, or `omarchy-bar set
   io.github.dreed47.makerworld <key> <value>`. Stored in `shell.json`.
2. **`~/.config/omarchy/makerworld/config.json`** — live-reloaded, used for any
   key the widget entry doesn't set (and the only option surface if you don't
   mount the bar widget). See `config.example.json`.

Both accept booleans and `"on"`/`"off"`.

| Key | Default | Meaning |
|---|---|---|
| `region` | `"global"` | `"global"` (api.bambulab.com) or `"china"` (api.bambulab.cn) |
| `pollSeconds` | `300` | unread-count poll interval; floored at 120 |
| `profileMinutes` | `15` | point-balance poll interval; floored at 5 |
| `notify` | `on` | desktop notifications for new activity |
| `notifyTypes` | all | any of `comment`, `reply`, `like`, `follow`, `system`, `points` (or `"all"`) |
| `notifyTimeoutSeconds` | `0` | auto-dismiss after N seconds (0 = notification-daemon default) |
| `notifySound` | `""` | path to a sound file played on each notification (blank = silent) |
| `maxBurst` | `5` | cap notifications raised per poll, so a backlog can't flood you |
| `openOnClick` | `on` | clicking a notification runs `xdg-open` on the model/message URL |
| `showPoints` | `on` | show the point balance in the bar pill |
| `debug` | `off` | log raw API responses to the shell log to help adjust parsers |

## How it works

- `Service.qml` — headless. `Timer` → `curl` (via Quickshell `Process`) →
  parse → notify. First poll after start is adopted as a **silent baseline**,
  so enabling the plugin doesn't replay your existing unread backlog. Notified
  message IDs live in a bounded ring buffer in `PersistentProperties` so a
  shell reload doesn't re-notify. Publishes `points`, `unreadByType`,
  `unreadTotal`, `profileName`, `connState` for the pill/popup.
- `BarWidget.qml` / `Panel.qml` — the pill and its popup. The popup makes its
  own `/my/messages` fetch for the activity list (when opened, then every 2
  min while open); the service owns the count poll and notifications.
- On HTTP 401/403 the service runs `bin/makerworld-refresh`. If that fails it
  raises one "sign-in expired — run `makerworld-login`" notification, shows a
  warning triangle on the pill, and waits for `token.json` to change.
- `Model.js` — all URLs, response parsing, message classification, config
  normalisation, and notify/seen bookkeeping. Pure functions, covered by
  `tests/`.

### CLI tools

| Tool | Purpose |
|---|---|
| `bin/makerworld-login` | interactive one-time Bambu Cloud sign-in |
| `bin/makerworld-refresh` | non-interactive access-token refresh (run by the service) |
| `bin/makerworld-token` | `--status` (default), `--check`, `--path`, `--paste` |

### Manual poke (testing)

```sh
qs -p /usr/share/omarchy/shell ipc call makerworld status    # dump service state as JSON
qs -p /usr/share/omarchy/shell ipc call makerworld refresh   # poll now, keep the baseline
qs -p /usr/share/omarchy/shell ipc call makerworld poll      # re-baseline then poll now
qs -p /usr/share/omarchy/shell ipc call makerworld markRead  # mark all messages read
```

## Development

```sh
npm run check     # node --check + tests + py_compile + manifest validation
npm test          # Model.js unit tests only
```

Requires `python3` and `curl` (both ship with Omarchy).

## License

MIT © 2026 David Reed
