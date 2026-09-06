# Changelog

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
