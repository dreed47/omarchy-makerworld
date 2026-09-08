"""Shared helpers for the MakerWorld plugin CLI tools.

No third-party dependencies - stdlib only, so this runs on a stock Omarchy
box. All of this talks to the *unofficial* Bambu Cloud account API (the same
endpoints the Bambu Handy app uses); there is no documented API.
"""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
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


# ---- Import a token from Bambu Studio / Orca Slicer ------------------
#
# Both slicers log in to the *same* Bambu Cloud backend and cache the access
# token + refresh token on disk after you sign in. If we can find it, the user
# never has to type a password here. Everything about where and how it is
# stored is undocumented and version-dependent, so this is best-effort: it
# searches the known config dirs, parses whatever it finds, and reports what it
# saw if it can't pick out a token.

SLICER_DIRS = [
    ("Bambu Studio", "~/.config/BambuStudio"),
    ("Bambu Studio (Flatpak)", "~/.var/app/com.bambulab.BambuStudio/config/BambuStudio"),
    ("Orca Slicer", "~/.config/OrcaSlicer"),
    ("Orca Slicer (Flatpak)", "~/.var/app/io.github.softfever.OrcaSlicer/config/OrcaSlicer"),
    ("Orca Slicer (SoftFever)", "~/.config/SoftFever/OrcaSlicer"),
]
_PREFERRED_FILES = [
    "BambuNetworkEngine.conf", "BambuNetworkEngine.json",
    "BambuStudio.conf", "OrcaSlicer.conf",
    "login.json", "user.json", "config.json", "BambuStudio.json",
]
_ACCESS_KEYS = {
    "accesstoken", "access_token", "token", "bambu_token", "cloud_token",
    "user_token", "usertoken", "bearer",
}
_REFRESH_KEYS = {"refreshtoken", "refresh_token", "refreshtokenstr"}
_REGION_KEYS = {"region", "bambu_region", "cloud_region", "loginregion"}


def _looks_like_token(v) -> bool:
    if not isinstance(v, str):
        return False
    v = v.strip()
    if len(v) < 40 or " " in v or "\n" in v:
        return False
    if v.startswith(("http://", "https://", "/", "~/")):
        return False
    return bool(re.match(r"^[A-Za-z0-9_.\-+/=]+$", v))


def _flatten_strings(obj, out, depth=0):
    """Collect {lowercased key: string value} pairs from nested dict/list."""
    if depth > 8:
        return
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str):
                out.setdefault(str(k).lower(), v)
            else:
                _flatten_strings(v, out, depth + 1)
    elif isinstance(obj, list):
        for v in obj:
            _flatten_strings(v, out, depth + 1)


def _parse_maybe_json(text: str) -> dict:
    text = text.strip()
    try:
        d = json.loads(text)
        if isinstance(d, (dict, list)):
            flat = {}
            _flatten_strings(d, flat)
            return flat
    except ValueError:
        pass
    # Fall back to scraping "key": "value" / key = "value" pairs.
    flat = {}
    for m in re.finditer(r'["\']?([A-Za-z0-9_.\-]+)["\']?\s*[:=]\s*["\']([^"\']+)["\']', text):
        flat.setdefault(m.group(1).lower(), m.group(2))
    return flat


def _keyring_token() -> str | None:
    if not shutil.which("secret-tool"):
        return None
    attempts = [
        ["service", "Bambu Studio"],
        ["application", "BambuStudio"],
        ["service", "com.bambulab.BambuStudio"],
        ["service", "OrcaSlicer"],
    ]
    for attr in attempts:
        try:
            r = subprocess.run(["secret-tool", "lookup", *attr],
                               capture_output=True, text=True, timeout=5)
            if r.returncode == 0 and _looks_like_token((r.stdout or "").strip()):
                return r.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
    return None


def find_slicer_token(explicit: str | None = None) -> dict | None:
    """Return {accessToken, refreshToken, region, source} or None.

    On a partial find (a config file but no recognizable token) returns a dict
    with an 'error' key plus 'seen_files'/'seen_keys' so the caller can ask the
    user to report them.
    """
    dirs: list[tuple[str, str]] = []
    if explicit:
        p = os.path.expanduser(explicit)
        dirs.append(("(given)", os.path.dirname(p) if os.path.isfile(p) else p))
    else:
        for name, d in SLICER_DIRS:
            dirs.append((name, os.path.expanduser(d)))

    seen_files: list[str] = []
    seen_keys: set[str] = set()
    encrypted_files: list[str] = []

    for name, d in dirs:
        if not os.path.isdir(d):
            continue
        try:
            names = sorted(set(_PREFERRED_FILES) & set(os.listdir(d)),
                           key=_PREFERRED_FILES.index)
            names += sorted(f for f in os.listdir(d)
                            if f.endswith((".conf", ".json")) and f not in names)
        except OSError:
            continue
        for fn in names[:40]:
            fp = os.path.join(d, fn)
            if not os.path.isfile(fp) or os.path.getsize(fp) > 5_000_000:
                continue
            try:
                raw = open(fp, "rb").read()
            except OSError:
                continue
            # A file that is mostly non-printable is the network agent's
            # encrypted token store - nothing we can do with it.
            nonprint = sum(1 for b in raw[:512] if b < 9 or (13 < b < 32) or b >= 127)
            if raw and nonprint > len(raw[:512]) * 0.3:
                encrypted_files.append(fp)
                continue
            flat = _parse_maybe_json(raw.decode("utf-8", "replace"))
            if not flat:
                continue
            seen_files.append(fp)
            seen_keys.update(flat.keys())

            access = next((flat[k] for k in _ACCESS_KEYS
                           if k in flat and _looks_like_token(flat[k])), None)
            if not access:
                continue
            refresh = next((flat[k] for k in _REFRESH_KEYS if flat.get(k)), "")
            region = "global"
            for k in _REGION_KEYS:
                if flat.get(k):
                    region = norm_region("china" if "china" in flat[k].lower() else "global")
                    break
            return {
                "accessToken": access,
                "refreshToken": refresh,
                "region": region,
                "source": f"{name}: {fp}",
            }

    kr = _keyring_token()
    if kr:
        return {"accessToken": kr, "refreshToken": "", "region": "global",
                "source": "system keyring (secret-tool)"}

    if encrypted_files and not seen_files:
        return {
            "error": "the slicer stores its Bambu Cloud token in an encrypted file "
                     "this tool cannot read",
            "encrypted_files": encrypted_files,
            "seen_files": [],
            "seen_keys": [],
        }
    if seen_files or encrypted_files:
        return {
            "error": "found slicer config but no readable token",
            "seen_files": seen_files,
            "encrypted_files": encrypted_files,
            "seen_keys": sorted(seen_keys)[:60],
        }
    return None


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

# These calls carry the Bambu account password or the access/refresh token and
# hit fixed api.bambulab.com / bambulab.com endpoints. Responses are small
# JSON, so cap hard and refuse redirects outright - a redirect on a
# token-bearing request could leak the credential to an unintended origin, and
# an unbounded body could exhaust memory.
MAX_RESPONSE_BYTES = 2_000_000


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # noqa: D401 - suppress the redirect
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _read_capped(source) -> bytes:
    content_length = source.headers.get("Content-Length") if source.headers else None
    if content_length is not None:
        try:
            if int(content_length) > MAX_RESPONSE_BYTES:
                raise SystemExit(f"response too large ({content_length} bytes)")
        except ValueError:
            pass
    data = source.read(MAX_RESPONSE_BYTES + 1)
    if len(data) > MAX_RESPONSE_BYTES:
        raise SystemExit("response exceeded the size cap")
    return data


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
        with _OPENER.open(req, timeout=timeout) as resp:
            return HttpResult(resp.status, _read_capped(resp), dict(resp.headers))
    except urllib.error.HTTPError as exc:
        # A blocked redirect surfaces here as a 3xx; callers treat non-200 as
        # failure and never see a body from the redirect target.
        return HttpResult(exc.code, _read_capped(exc), dict(exc.headers or {}))
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
