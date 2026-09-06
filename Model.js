// Pure helpers for the MakerWorld plugin. No QML imports, so this file is also
// exercised from plain Node in tests/. Service.qml wraps these with its own
// polling, notification queue, and persisted state.
//
// IMPORTANT: MakerWorld / Bambu Cloud publishes no official API. The response
// shapes below are inferred from community reverse-engineering of the Bambu
// Handy app (see README "Sources"), not from documentation. Every parser here
// is deliberately defensive and tries several field names. If Bambu changes a
// payload, the fix is almost always a one-line addition in this file.

// ---- Regions -------------------------------------------------------------

// Global vs China accounts live on different hosts. `region` comes from the
// login helper (stored in token.json) or config.json; anything that is not an
// explicit "china"/"cn" is treated as global.
function normalizedRegion(value) {
  var v = String(value || "").trim().toLowerCase();
  return (v === "china" || v === "cn") ? "china" : "global";
}

function apiBase(region) {
  return normalizedRegion(region) === "china"
    ? "https://api.bambulab.cn"
    : "https://api.bambulab.com";
}

function siteBase(region) {
  return normalizedRegion(region) === "china"
    ? "https://makerworld.com.cn"
    : "https://makerworld.com";
}

// ---- Endpoints ---------------------------------------------------------
//
// Paths are centralised here so a shift in the unofficial API is one edit.

var PATHS = {
  messageCount: "/v1/user-service/my/message/count",
  messages: "/v1/user-service/my/messages",
  messageRead: "/v1/user-service/my/message/read",
  profile: "/v1/design-user-service/my/profile",
  refreshToken: "/v1/user-service/user/refreshtoken"
};

function urlMessageCount(region) {
  return apiBase(region) + PATHS.messageCount;
}

function urlMessages(region, limit, offset) {
  var q = "?limit=" + encodeURIComponent(String(limit || 20))
    + "&offset=" + encodeURIComponent(String(offset || 0));
  return apiBase(region) + PATHS.messages + q;
}

function urlProfile(region) {
  return apiBase(region) + PATHS.profile;
}

function messagesPageUrl(region) {
  return siteBase(region) + "/en/my/messages";
}

function modelUrl(region, id, locale) {
  return siteBase(region) + "/" + (locale || "en") + "/models/" + String(id);
}

// ---- JWT --------------------------------------------------------------

// Decode a base64url segment to a UTF-8 string. Works in both QML's JS engine
// and Node (both provide atob).
function b64urlDecode(seg) {
  var s = String(seg || "").replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  try {
    return decodeURIComponent(escape(atob(s)));
  } catch (e) {
    try { return atob(s); } catch (e2) { return ""; }
  }
}

// Expiry (epoch SECONDS) embedded in the Bambu access token, or 0 if it cannot
// be read. Never throws.
function jwtExp(token) {
  var parts = String(token || "").split(".");
  if (parts.length < 2) return 0;
  try {
    var payload = JSON.parse(b64urlDecode(parts[1]));
    var exp = parseInt(payload && payload.exp, 10);
    return isNaN(exp) ? 0 : exp;
  } catch (e) {
    return 0;
  }
}

// True when the token is missing an expiry, already expired, or within
// `marginDays` of expiring - i.e. refresh now.
function tokenNeedsRefresh(expSec, nowSec, marginDays) {
  var margin = (marginDays === undefined ? 7 : marginDays) * 86400;
  if (!expSec || expSec <= 0) return true;
  return (expSec - nowSec) < margin;
}

function maskToken(token) {
  var t = String(token || "");
  if (t.length <= 12) return t ? "set" : "";
  return t.slice(0, 6) + "…" + t.slice(-4);
}

// ---- Config normalisation -------------------------------------------

var KNOWN_TYPES = ["comment", "reply", "like", "follow", "system", "points"];

var DEFAULT_CONFIG = {
  region: "global",
  pollSeconds: 300,
  profileMinutes: 15,
  notify: true,
  notifyTypes: KNOWN_TYPES.slice(),
  notifyTimeoutSeconds: 0,
  notifySound: "",
  maxBurst: 5,
  openOnClick: true,
  debug: false
};

function pickNotifyTypes(value) {
  var arr;
  if (Array.isArray(value)) arr = value;
  else if (value === undefined || value === null || value === "") return KNOWN_TYPES.slice();
  else arr = String(value).split(",");
  var out = [];
  for (var i = 0; i < arr.length; i++) {
    var v = String(arr[i]).trim().toLowerCase();
    if (v === "" ) continue;
    if (v === "all" || v === "*") return KNOWN_TYPES.slice();
    if (v === "comments") v = "comment";
    if (v === "replies") v = "reply";
    if (v === "likes") v = "like";
    if (v === "follows" || v === "followers" || v === "fan" || v === "fans") v = "follow";
    if (v === "point" || v === "credits" || v === "credit") v = "points";
    if (out.indexOf(v) === -1) out.push(v);
  }
  return out.length ? out : KNOWN_TYPES.slice();
}

// Merge a parsed config.json over the defaults. Clamps the poll intervals to
// values that stay polite to an unofficial API.
function normalizedConfig(raw) {
  var c = {};
  var src = (raw && typeof raw === "object") ? raw : {};
  for (var k in DEFAULT_CONFIG) c[k] = DEFAULT_CONFIG[k];
  if (src.region !== undefined) c.region = normalizedRegion(src.region);
  if (src.pollSeconds !== undefined) c.pollSeconds = Math.max(120, parseInt(src.pollSeconds, 10) || 300);
  if (src.profileMinutes !== undefined) c.profileMinutes = Math.max(5, parseInt(src.profileMinutes, 10) || 15);
  if (src.notify !== undefined) c.notify = !!src.notify;
  if (src.notifyTypes !== undefined) c.notifyTypes = pickNotifyTypes(src.notifyTypes);
  if (src.notifyTimeoutSeconds !== undefined) c.notifyTimeoutSeconds = Math.max(0, parseInt(src.notifyTimeoutSeconds, 10) || 0);
  if (src.notifySound !== undefined) c.notifySound = String(src.notifySound || "");
  if (src.maxBurst !== undefined) c.maxBurst = Math.max(1, Math.min(20, parseInt(src.maxBurst, 10) || 5));
  if (src.openOnClick !== undefined) c.openOnClick = !!src.openOnClick;
  if (src.debug !== undefined) c.debug = !!src.debug;
  return c;
}

// ---- Response unwrapping ------------------------------------------

// Bambu services usually wrap the useful payload in `data` (sometimes twice),
// and sometimes report an error in `code`/`message`. Return the innermost
// object/array we can find.
function unwrap(json) {
  var d = json;
  for (var i = 0; i < 4; i++) {
    if (d && typeof d === "object" && !Array.isArray(d) && d.data !== undefined
        && (d.data === null || typeof d.data === "object")) {
      d = d.data;
    } else break;
  }
  return d;
}

function isAuthError(json) {
  if (!json || typeof json !== "object") return false;
  var code = json.code !== undefined ? json.code : (json.error !== undefined ? json.error : null);
  var n = parseInt(code, 10);
  if (n === 401 || n === 403) return true;
  var msg = String(json.message || json.error_description || "").toLowerCase();
  return msg.indexOf("unauthor") !== -1 || msg.indexOf("token") !== -1 && msg.indexOf("expire") !== -1;
}

// ---- Unread counts --------------------------------------------------

// Map many spellings of a per-category unread count into our canonical keys.
var COUNT_ALIASES = {
  comment: ["comment", "commentandrating", "rating"],
  reply: ["reply", "replies"],
  like: ["like", "praise", "heart"],
  follow: ["follow", "fan", "follower", "newfan", "subscribe", "subscriber"],
  system: ["system", "notice", "notification", "official", "announcement"],
  points: ["point", "credit", "boost", "boosttoken", "reward"]
};

function canonCountKey(rawKey) {
  var k = String(rawKey || "").toLowerCase().replace(/[_\s-]/g, "");
  // Peel common count/plural suffixes so "fansCount" -> "fan", "likes" -> "like".
  var stems = [k];
  var trimmed = k.replace(/(unread|count|num|total|number)$/, "");
  if (trimmed !== k && trimmed !== "") stems.push(trimmed);
  for (var s = 0; s < stems.length; s++) {
    var base = stems[s].replace(/s$/, "");
    var cand = [stems[s], base];
    for (var canon in COUNT_ALIASES) {
      var al = COUNT_ALIASES[canon];
      for (var i = 0; i < al.length; i++) {
        for (var c = 0; c < cand.length; c++) {
          if (al[i] === cand[c] || al[i].replace(/s$/, "") === cand[c]) return canon;
        }
      }
    }
  }
  return null;
}

// parseCounts(json) -> { byType: {comment:N,...}, total:N }
// Accepts: {commentCount:1,...}, {counts:{...}}, {list:[{type,count}]},
// {data:{...}}, or a bare {total: N}.
function parseCounts(json) {
  var d = unwrap(json) || {};
  var byType = {};
  var total = 0;
  var sawType = false;

  function addPair(key, val) {
    var n = parseInt(val, 10);
    if (isNaN(n)) return;
    var canon = canonCountKey(key);
    if (canon) { byType[canon] = (byType[canon] || 0) + n; sawType = true; }
    if (String(key).toLowerCase().replace(/[_\s-]/g, "").indexOf("total") !== -1) total = n;
  }

  function walk(obj, depth) {
    if (!obj || typeof obj !== "object" || depth > 3) return;
    if (Array.isArray(obj)) {
      for (var i = 0; i < obj.length; i++) {
        var it = obj[i];
        if (it && typeof it === "object") {
          var t = it.type !== undefined ? it.type : (it.bizType !== undefined ? it.bizType : it.name);
          var c = it.count !== undefined ? it.count : (it.unread !== undefined ? it.unread : it.num);
          if (t !== undefined && c !== undefined) addPair(t, c);
          else walk(it, depth + 1);
        }
      }
      return;
    }
    for (var k in obj) {
      var v = obj[k];
      if (typeof v === "number" || (typeof v === "string" && /^\d+$/.test(v))) addPair(k, v);
      else if (v && typeof v === "object") walk(v, depth + 1);
    }
  }

  walk(d, 0);

  var sum = 0;
  for (var key in byType) sum += byType[key];
  if (!total) total = sum || parseInt((d && (d.total || d.totalUnread || d.unread)) , 10) || 0;
  return { byType: byType, total: total, sawType: sawType };
}

// Which canonical categories went up between two parseCounts().byType maps.
// A rise in `total` with no per-type data yields ["system"] as a catch-all so
// something is still surfaced.
function diffCounts(prevByType, curByType, prevTotal, curTotal) {
  var prev = prevByType || {};
  var cur = curByType || {};
  var up = [];
  for (var k in cur) {
    if ((cur[k] || 0) > (prev[k] || 0)) up.push(k);
  }
  if (!up.length && prevTotal !== undefined && curTotal !== undefined
      && curTotal > prevTotal && Object.keys(cur).length === 0) {
    up.push("system");
  }
  return up;
}

// ---- Message list -------------------------------------------------

// Find the array of message records in a /my/messages response.
function extractMessages(json) {
  var d = unwrap(json);
  if (Array.isArray(d)) return d;
  if (!d || typeof d !== "object") return [];
  var keys = ["list", "records", "items", "messages", "hits", "rows", "content", "result"];
  for (var i = 0; i < keys.length; i++) {
    if (Array.isArray(d[keys[i]])) return d[keys[i]];
  }
  // Sometimes nested one deeper, e.g. { messages: { list: [...] } }
  for (var k in d) {
    if (d[k] && typeof d[k] === "object") {
      for (var j = 0; j < keys.length; j++) {
        if (Array.isArray(d[k][keys[j]])) return d[k][keys[j]];
      }
    }
  }
  return [];
}

function firstDefined(obj, names) {
  for (var i = 0; i < names.length; i++) {
    if (obj && obj[names[i]] !== undefined && obj[names[i]] !== null && obj[names[i]] !== "") {
      return obj[names[i]];
    }
  }
  return undefined;
}

function stripHtml(s) {
  return String(s || "").replace(/<[^>]*>/g, "").replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/\s+/g, " ").trim();
}

// Epoch MILLISECONDS from whatever timestamp field a message carries.
function messageTs(m) {
  var raw = firstDefined(m, ["createTime", "createdAt", "ctime", "gmtCreate", "time", "timestamp", "date", "sendTime"]);
  if (raw === undefined) return 0;
  if (typeof raw === "number") return raw < 1e12 ? raw * 1000 : raw;
  if (/^\d+$/.test(String(raw))) {
    var n = parseInt(raw, 10);
    return n < 1e12 ? n * 1000 : n;
  }
  var t = Date.parse(String(raw));
  return isNaN(t) ? 0 : t;
}

function messageId(m) {
  var id = firstDefined(m, ["id", "messageId", "msgId", "notificationId", "noticeId", "uuid", "key"]);
  if (id !== undefined) return String(id);
  // Stable-ish fallback so we don't renotify the same item every poll.
  return String(messageTs(m)) + ":" + stripHtml(firstDefined(m, ["content", "text", "title", "body"]) || "").slice(0, 40);
}

// Classify a raw message into one of KNOWN_TYPES (+ "other").
function classifyMessage(m) {
  var hay = [
    firstDefined(m, ["type", "bizType", "category", "msgType", "messageType", "subType", "action", "event", "templateCode"]),
    firstDefined(m, ["title", "content", "text", "body", "summary"])
  ].map(function (x) { return String(x || "").toLowerCase(); }).join(" ");

  if (/repl(y|ies|ied)/.test(hay)) return "reply";
  if (/comment|rating|review/.test(hay)) return "comment";
  if (/like|favou?rit|praise|heart/.test(hay)) return "like";
  if (/follow|\bfans?\b|subscrib/.test(hay)) return "follow";
  if (/point|credit|boost.?token|payout|reward/.test(hay)) return "points";
  if (/system|official|announc|notice|policy/.test(hay)) return "system";
  return "other";
}

// Human-facing headline for a class.
var CLASS_TITLE = {
  comment: "New comment",
  reply: "New reply",
  like: "New like",
  follow: "New follower",
  system: "MakerWorld",
  points: "MakerWorld points",
  other: "MakerWorld"
};

// Nerd Font glyphs (match the vocabulary Omarchy's own widgets use).
var CLASS_GLYPH = {
  comment: String.fromCharCode(0xf075), // nf-fa-comment
  reply: String.fromCharCode(0xf3e5),   // nf-md-reply
  like: String.fromCharCode(0xf004),    // nf-fa-heart
  follow: String.fromCharCode(0xf234),  // nf-fa-user_plus
  system: String.fromCharCode(0xf0f3),  // nf-fa-bell
  points: String.fromCharCode(0xf51e),  // nf-fa-coins
  other: String.fromCharCode(0xf0f3)
};

function glyphFor(cls) {
  return CLASS_GLYPH[cls] || CLASS_GLYPH.other;
}

// formatMessage(m, region) -> { id, ts, cls, title, body, url }
function formatMessage(m, region) {
  var cls = classifyMessage(m);
  var actor = firstDefined(m, ["senderName", "fromUserName", "fromName", "userName", "nickName", "nickname", "authorName", "creatorName"]);
  var subject = firstDefined(m, ["designTitle", "modelTitle", "subjectName", "designName", "targetTitle", "resourceName"]);
  var text = stripHtml(firstDefined(m, ["content", "text", "body", "message", "summary", "title"]) || "");

  var body = "";
  if (actor) body += String(actor);
  if (subject) body += (body ? " on " : "") + "“" + String(subject) + "”";
  if (text) body += (body ? ": " : "") + text;
  if (body.length > 220) body = body.slice(0, 217) + "…";

  var designId = firstDefined(m, ["designId", "modelId", "designID", "resourceId", "targetId"]);
  var link = firstDefined(m, ["url", "link", "jumpUrl", "redirectUrl", "targetUrl"]);
  var url;
  if (designId !== undefined && /^\d+$/.test(String(designId))) url = modelUrl(region, designId);
  else if (link && /^https?:\/\//.test(String(link))) url = String(link);
  else if (link && String(link).charAt(0) === "/") url = siteBase(region) + String(link);
  else url = messagesPageUrl(region);

  return {
    id: messageId(m),
    ts: messageTs(m),
    cls: cls,
    title: CLASS_TITLE[cls] || CLASS_TITLE.other,
    body: body || "New activity on MakerWorld",
    url: url
  };
}

// Given raw messages + the set of already-notified ids + allowed classes,
// return the ones to notify now: unseen, allowed class, newest last, capped.
function selectFresh(rawList, seenIds, allowedClasses, maxBurst, region) {
  var seen = {};
  var arr = seenIds || [];
  for (var i = 0; i < arr.length; i++) seen[String(arr[i])] = true;
  var allowAll = !allowedClasses || allowedClasses.indexOf("all") !== -1;

  var out = [];
  for (var j = 0; j < (rawList || []).length; j++) {
    var f = formatMessage(rawList[j], region);
    if (seen[f.id]) continue;
    if (!allowAll && allowedClasses.indexOf(f.cls) === -1) continue;
    out.push(f);
  }
  out.sort(function (a, b) { return a.ts - b.ts; });
  if (maxBurst && out.length > maxBurst) out = out.slice(out.length - maxBurst);
  return out;
}

// Keep the id ring buffer bounded; newest kept.
function mergeSeen(seenIds, newIds, cap) {
  var lim = cap || 300;
  var merged = (seenIds || []).concat(newIds || []);
  if (merged.length > lim) merged = merged.slice(merged.length - lim);
  return merged;
}

// ---- Profile / points ---------------------------------------------

// Pull a points/credits balance out of /my/profile. Returns a number or null.
function parsePoints(json) {
  var d = unwrap(json) || {};
  var names = ["point", "points", "pointCount", "pointNum", "credit", "credits",
    "creditPoint", "balance", "totalPoint", "totalPoints", "availablePoint",
    "availablePoints", "boostToken", "boostTokens"];
  var v = firstDefined(d, names);
  if (v === undefined && d.wallet && typeof d.wallet === "object") v = firstDefined(d.wallet, names);
  if (v === undefined && d.account && typeof d.account === "object") v = firstDefined(d.account, names);
  if (v === undefined) return null;
  var n = parseFloat(v);
  return isNaN(n) ? null : n;
}

// ---- Small utilities --------------------------------------------

function relTime(tsMs, nowMs) {
  var s = Math.max(0, Math.floor(((nowMs || Date.now()) - tsMs) / 1000));
  if (s < 60) return s + "s ago";
  var m = Math.floor(s / 60);
  if (m < 60) return m + "m ago";
  var h = Math.floor(m / 60);
  if (h < 24) return h + "h ago";
  var d = Math.floor(h / 24);
  return d + "d ago";
}

// Split a `curl -w '\n__HTTP__%{http_code}'` stdout blob into body + status.
function splitHttp(blob, marker) {
  var mk = marker || "__HTTP__";
  var s = String(blob || "");
  var idx = s.lastIndexOf(mk);
  if (idx === -1) return { body: s.trim(), status: 0 };
  return {
    body: s.slice(0, idx).trim(),
    status: parseInt(s.slice(idx + mk.length).trim(), 10) || 0
  };
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizedRegion: normalizedRegion,
    apiBase: apiBase,
    siteBase: siteBase,
    PATHS: PATHS,
    urlMessageCount: urlMessageCount,
    urlMessages: urlMessages,
    urlProfile: urlProfile,
    messagesPageUrl: messagesPageUrl,
    modelUrl: modelUrl,
    b64urlDecode: b64urlDecode,
    jwtExp: jwtExp,
    tokenNeedsRefresh: tokenNeedsRefresh,
    maskToken: maskToken,
    KNOWN_TYPES: KNOWN_TYPES,
    DEFAULT_CONFIG: DEFAULT_CONFIG,
    pickNotifyTypes: pickNotifyTypes,
    normalizedConfig: normalizedConfig,
    unwrap: unwrap,
    isAuthError: isAuthError,
    parseCounts: parseCounts,
    diffCounts: diffCounts,
    extractMessages: extractMessages,
    stripHtml: stripHtml,
    messageTs: messageTs,
    messageId: messageId,
    classifyMessage: classifyMessage,
    glyphFor: glyphFor,
    formatMessage: formatMessage,
    selectFresh: selectFresh,
    mergeSeen: mergeSeen,
    parsePoints: parsePoints,
    relTime: relTime,
    splitHttp: splitHttp
  };
}
