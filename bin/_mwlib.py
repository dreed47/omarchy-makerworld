"""Shared helpers for the MakerWorld plugin CLI tools.

No third-party dependencies - stdlib only, so this runs on a stock Omarchy
box. All of this talks to the *unofficial* Bambu Cloud account API (the same
endpoints the Bambu Handy app uses); there is no documented API.
"""

from __future__ import annotations

import base64
import json
import os
import time
import urllib.error
import urllib.request

CONF_DIR = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "omarchy", "makerworld",
)
TOKEN_FILE = os.path.join(CONF_DIR, "token.json")
CONFIG_FILE = os.path.join(CONF_DIR, "config.json")

# A Handy-ish User-Agent. api.bambulab.com is not Cloudflare-gated the way
# makerworld.com/api is, but sending something app-like avoids surprises.
USER_AGENT = "bambu_network_agent/01.09.05.01"

DEFAULT_CONFIG = {
    "region": "global",
    "pollSeconds": 300,
    "profileMinutes": 15,
    "notify": True,
    "notifyTypes": ["comment", "reply", "like", "follow", "system", "points"],
    "notifyTimeoutSeconds": 0,
    "notifySound": "",
    "maxBurst": 5,
    "openOnClick": True,
    "debug": False,
}


def api_base(region: str) -> str:
    r = (region or "").strip().lower()
    return "https://api.bambulab.cn" if r in ("china", "cn") else "https://api.bambulab.com"


def tfa_base(region: str) -> str:
    r = (region or "").strip().lower()
    return "https://bambulab.cn" if r in ("china", "cn") else "https://bambulab.com"


def norm_region(region: str) -> str:
    r = (region or "").strip().lower()
    return "china" if r in ("china", "cn") else "global"


# ---- token.json --------------------------------------------------------

def load_token() -> dict:
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_token(data: dict) -> None:
    os.makedirs(CONF_DIR, exist_ok=True)
    data = dict(data)
    data["savedAt"] = int(time.time())
    # QML's JS engine has no atob(), so the service can't decode the JWT
    # itself. Stash the expiry (epoch seconds, 0 if unreadable) here for it.
    data["accessTokenExp"] = jwt_exp(data.get("accessToken", ""))
    tmp = TOKEN_FILE + ".tmp"
    old_umask = os.umask(0o077)
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, TOKEN_FILE)
    finally:
        os.umask(old_umask)


def scaffold_config() -> bool:
    """Write a default config.json if none exists. Returns True if created."""
    if os.path.exists(CONFIG_FILE):
        return False
    os.makedirs(CONF_DIR, exist_ok=True)
    with open(CONFIG_FILE, "w", encoding="utf-8") as fh:
        json.dump(DEFAULT_CONFIG, fh, indent=2)
        fh.write("\n")
    return True


# ---- JWT -------------------------------------------------------------

def jwt_exp(token: str) -> int:
    parts = (token or "").split(".")
    if len(parts) < 2:
        return 0
    seg = parts[1].replace("-", "+").replace("_", "/")
    seg += "=" * (-len(seg) % 4)
    try:
        payload = json.loads(base64.b64decode(seg).decode("utf-8", "replace"))
        return int(payload.get("exp", 0))
    except (ValueError, TypeError):
        return 0


def exp_human(token: str) -> str:
    exp = jwt_exp(token)
    if not exp:
        return "unknown"
    left = exp - int(time.time())
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(exp))
    if left <= 0:
        return f"{when} (EXPIRED)"
    days = left / 86400.0
    return f"{when} ({days:.1f} days left)"


def mask(token: str) -> str:
    t = token or ""
    return (t[:6] + "…" + t[-4:]) if len(t) > 12 else ("set" if t else "(none)")


# ---- HTTP ----------------------------------------------------------

class HttpResult:
    def __init__(self, status: int, body: bytes, headers):
        self.status = status
        self.body = body
        self.headers = headers or {}

    def json(self):
        try:
            return json.loads(self.body.decode("utf-8", "replace"))
        except ValueError:
            return None


def http(method: str, url: str, token: str | None = None, payload: dict | None = None,
         timeout: int = 20) -> HttpResult:
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
    }
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return HttpResult(resp.status, resp.read(), dict(resp.headers))
    except urllib.error.HTTPError as exc:
        return HttpResult(exc.code, exc.read(), dict(exc.headers or {}))
    except urllib.error.URLError as exc:
        raise SystemExit(f"network error talking to {url}: {exc}")


def unwrap(obj):
    d = obj
    for _ in range(4):
        if isinstance(d, dict) and "data" in d and (d["data"] is None or isinstance(d["data"], (dict, list))):
            d = d["data"]
        else:
            break
    return d
