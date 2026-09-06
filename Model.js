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

// `category` is the `type=` query param the app uses to page one tab of the
// notification centre: 1 comments/ratings, 2 model activity (boosts, publish),
// 3 system + boost tokens, 4/6 print jobs, 5 community. Omitted = print jobs.
function urlMessages(region, limit, offset, category) {
  var q = "?limit=" + encodeURIComponent(String(limit || 20))
    + "&offset=" + encodeURIComponent(String(offset || 0));
  if (category !== undefined && category !== null && category !== "")
    q += "&type=" + encodeURIComponent(String(category));
  return apiBase(region) + PATHS.messages + q;
}

// The notification categories worth pulling for social activity, and which of
// our classes each can contain. Print jobs (category 4/6) are deliberately not
// here.
var MESSAGE_CATEGORIES = [
  { param: 1, classes: ["comment", "reply"] },
  { param: 2, classes: ["points", "system"] },
  { param: 3, classes: ["system", "points"] },
  { param: 5, classes: ["like"] }
];

// Which single category to page when a given class's unread count went up.
function categoryParamForClass(cls) {
  if (cls === "comment" || cls === "reply") return 1;
  if (cls === "like") return 5;
  if (cls === "points") return 2;
  return 3; // system, follow, anything else
}

function urlProfile(region) {
  return apiBase(region) + PATHS.profile;
}

// The site's notification centre - the fallback target for a message with no
// specific design/model to open.
function messagesPageUrl(region) {
  return siteBase(region) + "/en/my/notification";
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
  showPoints: true,
  boostExpiryWarnDays: 5,
  debug: false
};

// Accept booleans and the "on"/"off", "true"/"false", "yes"/"no", "1"/"0"
// strings the bar's settings schema stores. `undefined` -> fallback.
function truthy(value, fallback) {
  if (value === undefined || value === null || value === "") return !!fallback;
  if (typeof value === "boolean") return value;
  var v = String(value).trim().toLowerCase();
  return !(v === "off" || v === "false" || v === "no" || v === "0" || v === "disabled");
}

// Copy the non-empty keys of `over` onto a shallow clone of `base`. Used to lay
// a bar-widget settings entry (partial, string-typed) over config.json.
function mergeRaw(base, over) {
  var out = {};
  var b = (base && typeof base === "object") ? base : {};
  var o = (over && typeof over === "object") ? over : {};
  for (var k in b) out[k] = b[k];
  for (var j in o) {
    if (o[j] === undefined || o[j] === null || o[j] === "") continue;
    out[j] = o[j];
  }
  return out;
}

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
  if (src.notify !== undefined) c.notify = truthy(src.notify, true);
  if (src.notifyTypes !== undefined) c.notifyTypes = pickNotifyTypes(src.notifyTypes);
  if (src.notifyTimeoutSeconds !== undefined) c.notifyTimeoutSeconds = Math.max(0, parseInt(src.notifyTimeoutSeconds, 10) || 0);
  if (src.notifySound !== undefined) c.notifySound = String(src.notifySound || "");
  if (src.maxBurst !== undefined) c.maxBurst = Math.max(1, Math.min(20, parseInt(src.maxBurst, 10) || 5));
  if (src.openOnClick !== undefined) c.openOnClick = truthy(src.openOnClick, true);
  if (src.showPoints !== undefined) c.showPoints = truthy(src.showPoints, true);
  if (src.boostExpiryWarnDays !== undefined) {
    c.boostExpiryWarnDays = Math.max(0, Math.min(30, parseInt(src.boostExpiryWarnDays, 10) || 5));
  }
  if (src.debug !== undefined) c.debug = truthy(src.debug, false);
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

// parseCounts(json) -> { byType, total, apiUnreadTotal, sawType }
//
//   byType          per-category unread for the categories we surface
//                   (comment/reply/like/follow/system/points). Nothing else.
//   total           SUM of byType - the number the bar badge shows. It is NOT
//                   the API's `unreadTotal`, which on a real account is
//                   dominated by print-job (`deviceCount`) notifications - 674
//                   of them on the author's account at the time of writing.
//   apiUnreadTotal  the API's own grand total, kept for debug only.
//
// Accepts a flat `{commentCount:1,...}` object (the real shape), `{counts:{}}`,
// `{list:[{type,count}]}`, or a `data`-wrapped version of any of those.
function parseCounts(json) {
  var d = unwrap(json) || {};
  var byType = {};
  var apiUnreadTotal = 0;
  var sawType = false;

  function addPair(key, val) {
    var n = parseInt(val, 10);
    if (isNaN(n)) return;
    var norm = String(key).toLowerCase().replace(/[_\s-]/g, "");
    if (norm === "unreadtotal" || norm === "total" || norm === "totalunread") {
      if (n > apiUnreadTotal) apiUnreadTotal = n;
    }
    var canon = canonCountKey(key);
    if (canon) { byType[canon] = (byType[canon] || 0) + n; sawType = true; }
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

  var total = 0;
  for (var key in byType) total += (byType[key] || 0);
  return { byType: byType, total: total, apiUnreadTotal: apiUnreadTotal, sawType: sawType };
}

// Which canonical categories went up between two parseCounts().byType maps.
// Only the categories we map are considered, so a bump in print-job / device
// notifications never triggers anything.
function diffCounts(prevByType, curByType) {
  var prev = prevByType || {};
  var cur = curByType || {};
  var up = [];
  for (var k in cur) {
    if ((cur[k] || 0) > (prev[k] || 0)) up.push(k);
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

// The one payload object on a message envelope (everything else is metadata).
// e.g. { id, type, from, isread, createTime, designCommented: {...} } -> designCommented
var MSG_ENVELOPE = {
  id: 1, type: 1, from: 1, isread: 1, isRead: 1,
  createTime: 1, createdAt: 1, ctime: 1, updateTime: 1
};
function payloadOf(m) {
  if (!m || typeof m !== "object") return { key: "", val: {} };
  for (var k in m) {
    if (MSG_ENVELOPE[k]) continue;
    if (m[k] && typeof m[k] === "object") return { key: k, val: m[k] };
  }
  return { key: "", val: {} };
}

// Recursively find the first design reference under a payload.
function digDesign(obj, depth) {
  if (!obj || typeof obj !== "object" || (depth || 0) > 5) return null;
  if (obj.designInfo && obj.designInfo.id && +obj.designInfo.id > 0) {
    return { id: String(obj.designInfo.id), title: String(obj.designInfo.title || "") };
  }
  if (obj.designId && /^\d+$/.test(String(obj.designId)) && +obj.designId > 0) {
    return { id: String(obj.designId), title: String(obj.designTitle || obj.designName || "") };
  }
  for (var k in obj) {
    if (obj[k] && typeof obj[k] === "object") {
      var r = digDesign(obj[k], (depth || 0) + 1);
      if (r) return r;
    }
  }
  return null;
}

// Recursively find the first non-empty string value for any of `names`.
function deepFindStr(obj, names, depth) {
  if (!obj || typeof obj !== "object" || (depth || 0) > 5) return "";
  for (var i = 0; i < names.length; i++) {
    var v = obj[names[i]];
    if (typeof v === "string" && v.trim() !== "") return v;
  }
  for (var k in obj) {
    if (obj[k] && typeof obj[k] === "object") {
      var r = deepFindStr(obj[k], names, (depth || 0) + 1);
      if (r) return r;
    }
  }
  return "";
}

// Inner numeric event `type` -> our class. Derived from live payloads; unknown
// codes fall through to a name/text guess.
var EVENT_CLASS = {
  6: "print",
  101: "system", 102: "system", 103: "system",          // designPublished etc.
  201: "comment", 251: "comment",                        // designCommented / instRating
  202: "reply", 203: "reply", 252: "reply",              // commentReplied / ratingReplied
  254: "other",                                          // instanceRatingRemind (a nag - hide by default)
  301: "follow", 302: "follow", 303: "follow",           // (new follower - unconfirmed)
  401: "system", 402: "system", 411: "system", 412: "system",
  501: "points", 502: "points", 503: "points",           // boost granted / expiry remind / design boosted
  601: "like", 602: "like", 603: "like",                 // community liked
  815: "system"                                          // newBadgeReceived
};

// Classify a raw message (envelope with a nested payload) into a KNOWN_TYPE
// (+ "print"/"other").
function classifyMessage(m) {
  var inner = parseInt(m && m.type, 10);
  if (!isNaN(inner) && EVENT_CLASS[inner]) return EVENT_CLASS[inner];

  var p = payloadOf(m);
  var hay = (p.key + " " + deepFindStr(p.val, ["title", "content", "detail"])).toLowerCase();
  if (/repl(y|ies|ied)/.test(hay)) return "reply";
  if (/comment|rating|review/.test(hay)) return "comment";
  if (/boost|\bpoint|credit|payout|reward/.test(hay)) return "points";
  if (/like|favou?rit|praise|heart/.test(hay)) return "like";
  if (/follow|\bfans?\b|subscrib/.test(hay)) return "follow";
  if (/task|print/.test(hay)) return "print";
  if (/system|official|announc|notice|policy|publish/.test(hay)) return "system";
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
  print: "Print job",
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
  print: String.fromCharCode(0xf02f),   // nf-fa-print
  other: String.fromCharCode(0xf0f3)
};

function glyphFor(cls) {
  return CLASS_GLYPH[cls] || CLASS_GLYPH.other;
}

// formatMessage(m, region) -> { id, ts, cls, title, body, url, read }
//
// `m` is a notification envelope: { id, type, from, isread, createTime, <one
// payload object> }. The payload key names the event (designCommented,
// instRating, pointDesignBoosted, systemForWeb, communityPostLiked, …); its
// shape varies, so design/actor/text are dug out recursively.
function formatMessage(m, region) {
  var cls = classifyMessage(m);
  var p = payloadOf(m);
  var pv = p.val || {};
  var from = (m && m.from && typeof m.from === "object") ? m.from : null;

  var design = digDesign(pv, 0);
  var designTitle = design ? design.title : "";

  var actor = from && from.name ? String(from.name) : "";
  if (!actor) actor = deepFindStr(pv, ["boostedByUsername", "boostedByUserName", "name", "userName", "nickName", "nickname"]);
  if (!actor && Array.isArray(pv.users) && pv.users[0] && pv.users[0].name) actor = String(pv.users[0].name);

  var text;
  if (p.key === "instanceRatingRemind") {
    text = "Rate the model you printed" + (designTitle ? ": “" + designTitle + "”" : "");
  } else if (p.key === "designPublished") {
    text = "Your design is now live" + (designTitle ? ": “" + designTitle + "”" : "");
  } else if (p.key === "pointDesignBoosted") {
    var cnt = pv.designBoostCnt;
    text = (actor ? actor + " boosted" : "Boost received")
      + (designTitle ? " “" + designTitle + "”" : "")
      + (cnt ? " (" + cnt + " total)" : "");
  } else if (p.key === "pointBoostingRightGet") {
    text = "You received a boost token";
  } else if (p.key === "pointBoostingRightExpireRemind") {
    var exp = messageTs({ createTime: pv.expireAt });
    text = "A boost token expires " + untilTime(exp, Date.now())
      + (exp ? " (" + isoDate(pv.expireAt) + ")" : "") + " — use it before it's gone";
  } else if (p.key === "newBadgeReceived") {
    text = "New badge: " + (pv.badgeTitle || "unlocked");
  } else if (cls === "system") {
    var st = deepFindStr(pv, ["title"]);
    var sb = deepFindStr(pv, ["bio"]);
    text = st + ((sb && sb !== st) ? " — " + sb : "");
    if (!text) text = stripHtml(deepFindStr(pv, ["content", "newContent", "detail"]));
  } else if (cls === "reply") {
    // Prefer the newest reply body over the original comment it answers.
    text = stripHtml(
      deepFindStr(pv.commentReply || {}, ["content"])
      || deepFindStr(pv.commentAtReply || {}, ["content"])
      || deepFindStr(pv, ["content", "newContent", "detail"]));
  } else {
    text = stripHtml(deepFindStr(pv, ["content", "newContent", "detail"]));
  }

  var body = "";
  if (cls !== "system" && p.key !== "pointDesignBoosted" && actor) body += actor;
  if (cls !== "system" && p.key !== "pointDesignBoosted" && designTitle) {
    body += (body ? " on " : "") + "“" + designTitle + "”";
  }
  if (text) body += (body ? ": " : "") + text;
  body = stripHtml(body);
  if (body.length > 240) body = body.slice(0, 237) + "…";

  var url = design ? modelUrl(region, design.id)
    : (p.key.indexOf("pointBoosting") === 0 || p.key === "pointDesignBoosted")
      ? boostPageUrl(region)
      : messagesPageUrl(region);

  return {
    id: messageId(m),
    ts: messageTs(m),
    cls: cls,
    title: p.key === "pointBoostingRightExpireRemind" ? "Boost token expiring"
      : (CLASS_TITLE[cls] || CLASS_TITLE.other),
    body: body || (CLASS_TITLE[cls] || "New activity on MakerWorld"),
    url: url,
    read: !!(m && (m.isread || m.isRead))
  };
}

// Merge + sort formatted messages from several category fetches, newest first,
// optionally dropping print jobs / unclassified noise.
function mergeMessageLists(lists, region, opts) {
  var o = opts || {};
  var seen = {};
  var out = [];
  for (var i = 0; i < (lists || []).length; i++) {
    var arr = lists[i] || [];
    for (var j = 0; j < arr.length; j++) {
      var f = (arr[j] && arr[j].cls !== undefined) ? arr[j] : formatMessage(arr[j], region);
      if (o.dropPrint && (f.cls === "print" || f.cls === "other")) continue;
      if (seen[f.id]) continue;
      seen[f.id] = true;
      out.push(f);
    }
  }
  out.sort(function (a, b) { return b.ts - a.ts; });
  if (o.limit && out.length > o.limit) out = out.slice(0, o.limit);
  return out;
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

// Display name / handle from /my/profile, best effort.
function parseProfileName(json) {
  var d = unwrap(json) || {};
  var v = firstDefined(d, ["name", "nickName", "nickname", "userName", "displayName", "handle"]);
  if (v === undefined && d.user && typeof d.user === "object") {
    v = firstDefined(d.user, ["name", "nickName", "nickname", "userName", "displayName"]);
  }
  return v === undefined ? "" : String(v);
}

// URL handle from /my/profile (for building the followers page link).
function parseProfileHandle(json) {
  var d = unwrap(json) || {};
  var v = firstDefined(d, ["handle", "uidStr"]);
  if (v === undefined && d.user) v = firstDefined(d.user, ["handle"]);
  return v === undefined ? "" : String(v);
}

// Follower ("fans") count from /my/profile. Number or null.
function parseFollowerCount(json) {
  var d = unwrap(json) || {};
  var v = firstDefined(d, ["fanCount", "fansCount", "followerCount", "followersCount"]);
  if (v === undefined) return null;
  var n = parseInt(v, 10);
  return isNaN(n) ? null : n;
}

// Currently-available boost tokens from /my/profile. Number or null.
// (`boostGained` is the lifetime total - not this.)
function parseBoostCount(json) {
  var d = unwrap(json) || {};
  var v = firstDefined(d, ["boost", "boostCount", "boostToken", "boostTokens", "boostAvailable", "availableBoost"]);
  if (v === undefined) return null;
  var n = parseInt(v, 10);
  return isNaN(n) ? null : n;
}

function followersUrl(region, handle) {
  var h = String(handle || "").replace(/^@/, "");
  return h !== "" ? (siteBase(region) + "/en/@" + h) : (siteBase(region) + "/en/my/notification");
}

function boostPageUrl(region) {
  return siteBase(region) + "/en/my/creator-center/boost";
}

// Scan raw notification messages for boost-token expiry info and return the
// soonest *future* expiry: { ms, iso, rightId } or null. Uses both the
// dedicated "expire remind" message and the original "granted" message.
function boostExpirySoonest(rawList, nowMs) {
  var now = nowMs || Date.now();
  var best = null;
  var list = rawList || [];
  for (var i = 0; i < list.length; i++) {
    var m = list[i];
    var pv = null, rid = null;
    if (m && m.pointBoostingRightExpireRemind) { pv = m.pointBoostingRightExpireRemind; }
    else if (m && m.pointBoostingRightGet) { pv = m.pointBoostingRightGet; }
    if (!pv || !pv.expireAt) continue;
    var ms = Date.parse(String(pv.expireAt));
    if (isNaN(ms) || ms <= now) continue;
    rid = pv.boostingRightId !== undefined ? String(pv.boostingRightId) : String(ms);
    if (!best || ms < best.ms) best = { ms: ms, iso: String(pv.expireAt), rightId: rid };
  }
  return best;
}

// ---- Bar-pill / panel display helpers ------------------------

// Group digits with thousands separators: 1240 -> "1,240".
function groupNum(n) {
  var neg = n < 0;
  var s = String(Math.abs(Math.round(n || 0)));
  var out = "";
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 === 0) out += ",";
    out += s[i];
  }
  return (neg ? "-" : "") + out;
}

function unreadTotalOf(byType) {
  var t = 0;
  var b = byType || {};
  for (var k in b) t += (parseInt(b[k], 10) || 0);
  return t;
}

// Categories with a non-zero unread count, in canonical order, with a glyph
// and a human label. For the popup's chip row.
var CLASS_LABEL = {
  comment: "comments", reply: "replies", like: "likes",
  follow: "followers", system: "system", points: "points", other: "other"
};

function unreadChips(byType) {
  var b = byType || {};
  var out = [];
  for (var i = 0; i < KNOWN_TYPES.length; i++) {
    var k = KNOWN_TYPES[i];
    var n = parseInt(b[k], 10) || 0;
    if (n > 0) out.push({ cls: k, label: CLASS_LABEL[k] || k, count: n, glyph: glyphFor(k) });
  }
  return out;
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

// "in 3 days" / "in 5 hours" / "soon" for a future timestamp.
function untilTime(tsMs, nowMs) {
  var s = Math.floor((tsMs - (nowMs || Date.now())) / 1000);
  if (s <= 0) return "now";
  if (s < 3600) return "in " + Math.max(1, Math.round(s / 60)) + " minutes";
  var h = Math.round(s / 3600);
  if (h < 48) return h <= 1 ? "in about an hour" : "in " + h + " hours";
  return "in " + Math.round(h / 24) + " days";
}

// "2026-06-01" from an ISO timestamp; "" if unparseable.
function isoDate(iso) {
  var s = String(iso || "");
  var m = s.match(/^(\d{4}-\d{2}-\d{2})/);
  return m ? m[1] : "";
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
    MESSAGE_CATEGORIES: MESSAGE_CATEGORIES,
    categoryParamForClass: categoryParamForClass,
    urlProfile: urlProfile,
    messagesPageUrl: messagesPageUrl,
    modelUrl: modelUrl,
    b64urlDecode: b64urlDecode,
    jwtExp: jwtExp,
    tokenNeedsRefresh: tokenNeedsRefresh,
    maskToken: maskToken,
    KNOWN_TYPES: KNOWN_TYPES,
    DEFAULT_CONFIG: DEFAULT_CONFIG,
    truthy: truthy,
    mergeRaw: mergeRaw,
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
    payloadOf: payloadOf,
    glyphFor: glyphFor,
    formatMessage: formatMessage,
    mergeMessageLists: mergeMessageLists,
    selectFresh: selectFresh,
    mergeSeen: mergeSeen,
    parsePoints: parsePoints,
    parseProfileName: parseProfileName,
    parseProfileHandle: parseProfileHandle,
    parseFollowerCount: parseFollowerCount,
    parseBoostCount: parseBoostCount,
    followersUrl: followersUrl,
    boostPageUrl: boostPageUrl,
    boostExpirySoonest: boostExpirySoonest,
    untilTime: untilTime,
    isoDate: isoDate,
    groupNum: groupNum,
    unreadTotalOf: unreadTotalOf,
    unreadChips: unreadChips,
    relTime: relTime,
    splitHttp: splitHttp
  };
}
