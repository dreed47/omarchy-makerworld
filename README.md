# MakerWorld notifications for Omarchy

Desktop notifications for activity on your [MakerWorld](https://makerworld.com)
(Bambu Lab) models — new comments and replies, likes, new followers, system
messages, and point-balance increases. A headless Omarchy shell service polls
your Bambu Cloud account on an interval and raises an `omarchy-notification-send`
notification for anything new. Click a notification to open the model page.

> **Phase 1 — notifications only.** A bar pill showing the point balance and
> unread count, an in-panel message list, and "mark all read" are planned for
> 0.2. See `CHANGELOG.md`.

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

`~/.config/omarchy/makerworld/config.json` (live-reloaded — no restart needed).
See `config.example.json`.

| Key | Default | Meaning |
|---|---|---|
| `region` | `"global"` | `"global"` (api.bambulab.com) or `"china"` (api.bambulab.cn) |
| `pollSeconds` | `300` | unread-count poll interval; floored at 120 |
| `profileMinutes` | `15` | point-balance poll interval; floored at 5 |
| `notify` | `true` | master switch; `false` stops all polling |
| `notifyTypes` | all | any of `comment`, `reply`, `like`, `follow`, `system`, `points` (or `"all"`) |
| `notifyTimeoutSeconds` | `0` | auto-dismiss after N seconds (0 = notification-daemon default) |
| `notifySound` | `""` | path to a sound file played on each notification (blank = silent) |
| `maxBurst` | `5` | cap notifications raised per poll, so a backlog can't flood you |
| `openOnClick` | `true` | clicking a notification runs `xdg-open` on the model/message URL |
| `debug` | `false` | log raw API responses to the shell log to help adjust parsers |

## How it works

- `Service.qml` — the headless service. `Timer` → `curl` (via Quickshell
  `Process`) → parse → notify. First poll after start is adopted as a **silent
  baseline**, so enabling the plugin doesn't replay your existing unread
  backlog. Notified message IDs are kept in a bounded ring buffer in
  `PersistentProperties` so a shell reload doesn't re-notify.
- On HTTP 401/403 the service runs `bin/makerworld-refresh`. If that fails it
  raises one "sign-in expired — run `makerworld-login`" notification and stops
  until `token.json` changes.
- `Model.js` — all URLs, response parsing, message classification, and the
  notify/seen bookkeeping. Pure functions, covered by `tests/`.

### CLI tools

| Tool | Purpose |
|---|---|
| `bin/makerworld-login` | interactive one-time Bambu Cloud sign-in |
| `bin/makerworld-refresh` | non-interactive access-token refresh (run by the service) |
| `bin/makerworld-token` | `--status` (default), `--check`, `--path`, `--paste` |

### Manual poke (testing)

```sh
qs -c omarchy ipc call makerworld status    # dump service state as JSON
qs -c omarchy ipc call makerworld poll      # re-baseline then poll now
```

## Development

```sh
npm run check     # node --check + tests + py_compile + manifest validation
npm test          # Model.js unit tests only
```

Requires `python3` and `curl` (both ship with Omarchy).

## License

MIT © 2026 David Reed
