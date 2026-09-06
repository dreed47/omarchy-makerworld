"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const M = require("../Model.js");

// ---- regions / urls ---------------------------------------------------

test("region + base url selection", () => {
  assert.equal(M.normalizedRegion("CN"), "china");
  assert.equal(M.normalizedRegion("China"), "china");
  assert.equal(M.normalizedRegion(""), "global");
  assert.equal(M.normalizedRegion("us"), "global");
  assert.equal(M.apiBase("china"), "https://api.bambulab.cn");
  assert.equal(M.apiBase("global"), "https://api.bambulab.com");
  assert.match(M.urlMessageCount("global"), /^https:\/\/api\.bambulab\.com\/v1\/user-service\/my\/message\/count$/);
  assert.match(M.urlMessages("global", 30, 0), /limit=30&offset=0$/);
  assert.equal(M.modelUrl("global", 12345), "https://makerworld.com/en/models/12345");
});

// ---- JWT ------------------------------------------------------------

function fakeJwt(payloadObj) {
  const b64 = (o) =>
    Buffer.from(JSON.stringify(o)).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return b64({ alg: "HS256", typ: "JWT" }) + "." + b64(payloadObj) + ".sig";
}

test("jwtExp reads exp, tolerates junk", () => {
  const exp = Math.floor(Date.now() / 1000) + 1000;
  assert.equal(M.jwtExp(fakeJwt({ exp })), exp);
  assert.equal(M.jwtExp("not-a-jwt"), 0);
  assert.equal(M.jwtExp(""), 0);
  assert.equal(M.jwtExp(fakeJwt({ nope: 1 })), 0);
});

test("tokenNeedsRefresh margin logic", () => {
  const now = 1_000_000;
  assert.equal(M.tokenNeedsRefresh(0, now), true, "no exp => refresh");
  assert.equal(M.tokenNeedsRefresh(now - 10, now), true, "expired => refresh");
  assert.equal(M.tokenNeedsRefresh(now + 3 * 86400, now, 7), true, "inside margin");
  assert.equal(M.tokenNeedsRefresh(now + 30 * 86400, now, 7), false, "outside margin");
});

test("maskToken", () => {
  assert.equal(M.maskToken("abcdefghijklmnop"), "abcdef…mnop");
  assert.equal(M.maskToken("short"), "set");
  assert.equal(M.maskToken(""), "");
});

// ---- config -------------------------------------------------------

test("normalizedConfig clamps and defaults", () => {
  const c = M.normalizedConfig({ pollSeconds: 5, profileMinutes: 1, maxBurst: 999, notifyTypes: "likes, comments" });
  assert.equal(c.pollSeconds, 120, "poll floored at 120");
  assert.equal(c.profileMinutes, 5, "profile floored at 5");
  assert.equal(c.maxBurst, 20, "burst capped at 20");
  assert.deepEqual(c.notifyTypes.sort(), ["comment", "like"]);
  assert.equal(c.notify, true);
  const d = M.normalizedConfig(null);
  assert.deepEqual(d.notifyTypes, M.KNOWN_TYPES);
});

test("truthy accepts bools and on/off strings", () => {
  assert.equal(M.truthy(true), true);
  assert.equal(M.truthy(false), false);
  assert.equal(M.truthy("on"), true);
  assert.equal(M.truthy("off"), false);
  assert.equal(M.truthy("false"), false);
  assert.equal(M.truthy("0"), false);
  assert.equal(M.truthy("yes"), true);
  assert.equal(M.truthy(undefined, true), true);
  assert.equal(M.truthy("", false), false);
});

test("mergeRaw lays non-empty override keys over base", () => {
  const merged = M.mergeRaw(
    { region: "global", pollSeconds: 300, notify: true },
    { region: "china", pollSeconds: "", notify: "off", extra: "x" }
  );
  assert.equal(merged.region, "china");
  assert.equal(merged.pollSeconds, 300, "empty string does not override");
  assert.equal(merged.notify, "off");
  assert.equal(merged.extra, "x");
});

test("normalizedConfig reads bar-schema on/off strings", () => {
  const c = M.normalizedConfig({ notify: "off", showPoints: "off", openOnClick: "on", debug: "on" });
  assert.equal(c.notify, false);
  assert.equal(c.showPoints, false);
  assert.equal(c.openOnClick, true);
  assert.equal(c.debug, true);
  assert.equal(M.normalizedConfig(null).showPoints, true, "default on");
});

test("groupNum / unreadTotalOf / unreadChips", () => {
  assert.equal(M.groupNum(1240), "1,240");
  assert.equal(M.groupNum(5), "5");
  assert.equal(M.groupNum(1234567), "1,234,567");
  assert.equal(M.groupNum(-2500), "-2,500");
  assert.equal(M.unreadTotalOf({ comment: 2, like: 3, follow: 0 }), 5);
  const chips = M.unreadChips({ like: 3, comment: 1, bogus: 9 });
  assert.deepEqual(chips.map((c) => c.cls), ["comment", "like"], "known types only, canonical order");
  assert.equal(chips[0].count, 1);
  assert.equal(typeof chips[1].glyph, "string");
});

test("parseProfileName", () => {
  assert.equal(M.parseProfileName({ data: { nickName: "Dave" } }), "Dave");
  assert.equal(M.parseProfileName({ user: { name: "Dave R" } }), "Dave R");
  assert.equal(M.parseProfileName({ nope: 1 }), "");
});

test("pickNotifyTypes aliases + all", () => {
  assert.deepEqual(M.pickNotifyTypes("followers,fans").sort(), ["follow"]);
  assert.deepEqual(M.pickNotifyTypes("all"), M.KNOWN_TYPES);
  assert.deepEqual(M.pickNotifyTypes(""), M.KNOWN_TYPES);
  assert.deepEqual(M.pickNotifyTypes(["reply", "reply", "credits"]).sort(), ["points", "reply"]);
});

// ---- unwrap / auth error --------------------------------------

test("unwrap peels nested data", () => {
  assert.deepEqual(M.unwrap({ data: { data: { x: 1 } } }), { x: 1 });
  assert.deepEqual(M.unwrap({ x: 1 }), { x: 1 });
  assert.deepEqual(M.unwrap({ data: [1, 2] }), [1, 2]);
});

test("isAuthError", () => {
  assert.equal(M.isAuthError({ code: 401 }), true);
  assert.equal(M.isAuthError({ code: "403" }), true);
  assert.equal(M.isAuthError({ message: "token has expired" }), true);
  assert.equal(M.isAuthError({ code: 0, message: "ok" }), false);
});

// ---- counts -----------------------------------------------------

test("parseCounts: flat *Count keys", () => {
  const r = M.parseCounts({ commentCount: 2, likeCount: 5, fansCount: 1, systemCount: 0, totalUnread: 8 });
  assert.equal(r.byType.comment, 2);
  assert.equal(r.byType.like, 5);
  assert.equal(r.byType.follow, 1);
  assert.equal(r.total, 8);
});

test("parseCounts: nested + array of {type,count}", () => {
  const nested = M.parseCounts({ data: { counts: { comment: 3, praise: 4 } } });
  assert.equal(nested.byType.comment, 3);
  assert.equal(nested.byType.like, 4);
  const arr = M.parseCounts({ list: [{ type: "follow", count: 2 }, { type: "reply", count: 1 }] });
  assert.equal(arr.byType.follow, 2);
  assert.equal(arr.byType.reply, 1);
});

test("diffCounts: per-type rise + total-only fallback", () => {
  assert.deepEqual(
    M.diffCounts({ comment: 1, like: 2 }, { comment: 3, like: 2 }).sort(),
    ["comment"]
  );
  assert.deepEqual(M.diffCounts({}, {}, 4, 7), ["system"], "total rose, no per-type");
  assert.deepEqual(M.diffCounts({ like: 1 }, { like: 1 }, 5, 5), []);
});

// ---- message list --------------------------------------------

test("extractMessages finds the array in various shapes", () => {
  assert.equal(M.extractMessages({ hits: [1, 2, 3] }).length, 3);
  assert.equal(M.extractMessages({ data: { list: [{}, {}] } }).length, 2);
  assert.equal(M.extractMessages({ messages: { records: [{}] } }).length, 1);
  assert.equal(M.extractMessages([{}, {}]).length, 2);
  assert.equal(M.extractMessages({ nope: 1 }).length, 0);
});

test("classifyMessage by type field and by text", () => {
  assert.equal(M.classifyMessage({ bizType: "DESIGN_COMMENT" }), "comment");
  assert.equal(M.classifyMessage({ type: "comment_reply" }), "reply");
  assert.equal(M.classifyMessage({ title: "Someone liked your model" }), "like");
  assert.equal(M.classifyMessage({ content: "You have a new follower" }), "follow");
  assert.equal(M.classifyMessage({ content: "You earned 30 points" }), "points");
  assert.equal(M.classifyMessage({ type: "SYSTEM_NOTICE" }), "system");
  assert.equal(M.classifyMessage({ foo: "bar" }), "other");
});

test("messageTs handles seconds, millis, ISO", () => {
  assert.equal(M.messageTs({ createTime: 1700000000 }), 1700000000000);
  assert.equal(M.messageTs({ createdAt: 1700000000000 }), 1700000000000);
  assert.equal(M.messageTs({ ctime: "2023-11-14T22:13:20Z" }), Date.parse("2023-11-14T22:13:20Z"));
  assert.equal(M.messageTs({}), 0);
});

test("formatMessage builds body + model url", () => {
  const f = M.formatMessage({
    bizType: "comment",
    senderName: "Alice",
    designTitle: "Cable Clip",
    content: "<p>Nice&nbsp;print!</p>",
    designId: "998877",
    createTime: 1700000000,
  }, "global");
  assert.equal(f.cls, "comment");
  assert.equal(f.title, "New comment");
  assert.equal(f.url, "https://makerworld.com/en/models/998877");
  assert.match(f.body, /Alice/);
  assert.match(f.body, /Cable Clip/);
  assert.match(f.body, /Nice print!/);
  assert.ok(!/[<>]/.test(f.body), "html stripped");
});

test("formatMessage falls back to messages page when no id/link", () => {
  const f = M.formatMessage({ type: "system", content: "Policy update" }, "global");
  assert.equal(f.url, "https://makerworld.com/en/my/messages");
});

test("selectFresh: unseen + allowed + capped + oldest-first", () => {
  const raw = [
    { id: "a", bizType: "comment", createTime: 30 },
    { id: "b", bizType: "like", createTime: 10 },
    { id: "c", bizType: "comment", createTime: 20 },
    { id: "d", bizType: "follow", createTime: 40 },
  ];
  const out = M.selectFresh(raw, ["a"], ["comment", "like"], 5, "global");
  assert.deepEqual(out.map((x) => x.id), ["b", "c"], "b(10) before c(20); a seen; d wrong class");

  const capped = M.selectFresh(raw, [], ["comment", "like", "follow"], 2, "global");
  assert.deepEqual(capped.map((x) => x.id), ["a", "d"], "keep newest 2 by ts (a=30, d=40)");
});

test("mergeSeen bounds the ring buffer", () => {
  const big = Array.from({ length: 320 }, (_, i) => "id" + i);
  const merged = M.mergeSeen(big, ["new1", "new2"], 300);
  assert.equal(merged.length, 300);
  assert.equal(merged[merged.length - 1], "new2");
  assert.equal(merged[0], "id22");
});

// ---- points ---------------------------------------------------

test("parsePoints digs through common shapes", () => {
  assert.equal(M.parsePoints({ points: 1200 }), 1200);
  assert.equal(M.parsePoints({ data: { wallet: { balance: 42 } } }), 42);
  assert.equal(M.parsePoints({ data: { totalPoints: "7" } }), 7);
  assert.equal(M.parsePoints({ nothing: 1 }), null);
});

// ---- misc ----------------------------------------------------

test("splitHttp separates body and status", () => {
  assert.deepEqual(M.splitHttp('{"ok":1}\n__HTTP__200'), { body: '{"ok":1}', status: 200 });
  assert.deepEqual(M.splitHttp('boom\n__HTTP__401'), { body: "boom", status: 401 });
  assert.deepEqual(M.splitHttp("no marker"), { body: "no marker", status: 0 });
});

test("relTime", () => {
  const now = 10_000_000_000;
  assert.equal(M.relTime(now - 5000, now), "5s ago");
  assert.equal(M.relTime(now - 120000, now), "2m ago");
  assert.equal(M.relTime(now - 3 * 3600 * 1000, now), "3h ago");
  assert.equal(M.relTime(now - 2 * 86400 * 1000, now), "2d ago");
});

test("glyphFor always returns a single glyph", () => {
  for (const c of M.KNOWN_TYPES.concat(["other", "bogus"])) {
    assert.equal(typeof M.glyphFor(c), "string");
    assert.ok(M.glyphFor(c).length >= 1);
  }
});
