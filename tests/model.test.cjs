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

test("parseCounts: flat *Count keys, total is the sum of mapped types", () => {
  const r = M.parseCounts({ commentCount: 2, likeCount: 5, fansCount: 1, systemCount: 0, totalUnread: 8 });
  assert.equal(r.byType.comment, 2);
  assert.equal(r.byType.like, 5);
  assert.equal(r.byType.follow, 1);
  assert.equal(r.total, 8, "2 + 5 + 1 + 0");
  assert.equal(r.apiUnreadTotal, 8);
});

test("parseCounts: real /message/count payload ignores device/print noise", () => {
  const r = M.parseCounts({
    noticeCount: 0, messageCount: 0, total: 0, commentCount: 0, designCount: 0,
    systemCount: 0, deviceCount: 674, communityCount: 0, paidContentCount: 0,
    crowdfundingMessageCount: 0, unreadTotal: 674, IMUnreadCount: 0,
    bubbleMsg: [], taskPopup: null,
  });
  assert.equal(r.total, 0, "no comments/system/etc -> badge shows nothing");
  assert.equal(r.apiUnreadTotal, 674, "API grand total kept for debug only");
  assert.equal(r.byType.like, undefined);
  assert.equal(M.unreadTotalOf(r.byType), 0);
  // ... and a real comment lands
  const withComment = M.parseCounts({ commentCount: 2, noticeCount: 1, deviceCount: 700, unreadTotal: 703 });
  assert.equal(withComment.total, 3, "2 comments + 1 notice(->system)");
  assert.equal(withComment.byType.comment, 2);
  assert.equal(withComment.byType.system, 1);
  assert.equal(withComment.apiUnreadTotal, 703);
});

test("parseCounts: nested + array of {type,count}", () => {
  const nested = M.parseCounts({ data: { counts: { comment: 3, praise: 4 } } });
  assert.equal(nested.byType.comment, 3);
  assert.equal(nested.byType.like, 4);
  assert.equal(nested.total, 7);
  const arr = M.parseCounts({ list: [{ type: "follow", count: 2 }, { type: "reply", count: 1 }] });
  assert.equal(arr.byType.follow, 2);
  assert.equal(arr.byType.reply, 1);
});

test("diffCounts: only mapped categories, device bumps ignored", () => {
  assert.deepEqual(
    M.diffCounts({ comment: 1, like: 2 }, { comment: 3, like: 2 }).sort(),
    ["comment"]
  );
  assert.deepEqual(M.diffCounts({}, {}), [], "no per-type change");
  assert.deepEqual(M.diffCounts({ like: 1 }, { like: 1 }), []);
  // a device/print count is never in byType, so it can't appear here
  assert.deepEqual(M.diffCounts({ system: 0 }, { system: 0 }), []);
});

// ---- message list --------------------------------------------

test("extractMessages finds the array in various shapes", () => {
  assert.equal(M.extractMessages({ hits: [1, 2, 3] }).length, 3);
  assert.equal(M.extractMessages({ data: { list: [{}, {}] } }).length, 2);
  assert.equal(M.extractMessages({ messages: { records: [{}] } }).length, 1);
  assert.equal(M.extractMessages([{}, {}]).length, 2);
  assert.equal(M.extractMessages({ nope: 1 }).length, 0);
});

// ---- real notification envelopes (captured live) ------------------

const MSG_RATING = {
  id: 2245597530, type: 251, isread: 0, createTime: "2026-09-05T15:27:33Z",
  from: { uid: 1, name: "Wolli", handle: "user_1" },
  instRating: {
    id: 284759039,
    designInfo: { id: 159401, uid: 9, title: "Wago 221 Connector Box", cover: "x", modelId: "" },
    instanceInfo: { id: 175002, title: "0.2mm layer" },
    score: 5, content: "Perfekt! Nützliches Teil für Heimwerker.",
  },
};
const MSG_COMMENTED = {
  id: 2226477609, type: 201, createTime: "2026-09-01T00:00:00Z",
  from: { uid: 2, name: "TonyBlokeDesigns" },
  designCommented: {
    designInfo: { id: 462884, title: "The Princess Bride Buttercup Dagger", modelId: "" },
    commentInfo: { id: 7311421, uid: 3, content: "This is a great little movie prop <b>x</b>", images: [] },
  },
};
const MSG_REPLIED = {
  id: 2225071994, type: 202, createTime: "2026-09-01T01:00:00Z",
  from: { uid: 4, name: "Curious" },
  commentReplied: {
    designInfo: { id: 3175483, title: "Waveshare AMOLED Mount" },
    commentInfo: { content: "first question" },
    commentReply: { content: "so is it best to use a case?" },
  },
};
const MSG_BOOSTED = {
  id: 2235075159, type: 503, createTime: "2026-08-30T00:00:00Z",
  from: { uid: 5, name: "user_570093703" },
  pointDesignBoosted: {
    designId: 71028, designTitle: "Cleveland Browns Lightbox",
    designBoostCnt: 6, boostedByUsername: "user_570093703",
  },
};
const MSG_SYSTEM = {
  id: 2204111083, type: 412, createTime: "2026-08-20T00:00:00Z", from: null,
  systemForWeb: {
    systemInfo: {
      uid: 0, title: "PrintMon Maker & AI Scanner – Discontinuation Notice",
      bio: "Thank you for the journey.", content: "Dear MakerWorld users,\nlong text …",
    },
  },
};
const MSG_COMMUNITY = {
  id: 2068664378, type: 603, createTime: "2026-07-31T13:16:09Z", from: null,
  communityPostLiked: {
    post: { postId: 1815240, type: 66, content: "{\"content\":[]}", designId: 3034987 },
    users: [{ uid: 6, name: "Aaron", handle: "Aaron.reed" }], userCount: 1,
  },
};
const MSG_PRINT = {
  id: 2248799006, type: 6, createTime: "2026-09-05T15:27:33Z", from: null,
  taskMessage: { id: 1, title: "test.stl", designId: 0, status: 2, deviceName: "X1 Carbon", detail: "Task Success" },
};

test("payloadOf picks the one non-envelope object", () => {
  assert.equal(M.payloadOf(MSG_RATING).key, "instRating");
  assert.equal(M.payloadOf(MSG_BOOSTED).key, "pointDesignBoosted");
  assert.equal(M.payloadOf({ id: 1, type: 2, from: null, isread: 0, createTime: "x" }).key, "");
});

test("classifyMessage: numeric event codes then text fallback", () => {
  assert.equal(M.classifyMessage(MSG_RATING), "comment");
  assert.equal(M.classifyMessage(MSG_COMMENTED), "comment");
  assert.equal(M.classifyMessage(MSG_REPLIED), "reply");
  assert.equal(M.classifyMessage(MSG_BOOSTED), "points");
  assert.equal(M.classifyMessage(MSG_SYSTEM), "system");
  assert.equal(M.classifyMessage(MSG_COMMUNITY), "like");
  assert.equal(M.classifyMessage(MSG_PRINT), "print");
  // unknown code -> guess from payload key / text
  assert.equal(M.classifyMessage({ type: 99999, someReply: { content: "re: hi" } }), "reply");
  assert.equal(M.classifyMessage({ type: 99999, blob: { title: "policy update" } }), "system");
});

test("messageTs handles seconds, millis, ISO", () => {
  assert.equal(M.messageTs({ createTime: 1700000000 }), 1700000000000);
  assert.equal(M.messageTs({ createdAt: 1700000000000 }), 1700000000000);
  assert.equal(M.messageTs({ ctime: "2023-11-14T22:13:20Z" }), Date.parse("2023-11-14T22:13:20Z"));
  assert.equal(M.messageTs({}), 0);
});

test("formatMessage: rating -> comment, model url, actor + design + text", () => {
  const f = M.formatMessage(MSG_RATING, "global");
  assert.equal(f.cls, "comment");
  assert.equal(f.title, "New comment");
  assert.equal(f.url, "https://makerworld.com/en/models/159401");
  assert.match(f.body, /Wolli/);
  assert.match(f.body, /Wago 221 Connector Box/);
  assert.match(f.body, /Perfekt/);
  assert.equal(f.read, false);
  assert.equal(String(f.id), "2245597530");
});

test("formatMessage: reply uses the latest reply text + design", () => {
  const f = M.formatMessage(MSG_REPLIED, "global");
  assert.equal(f.cls, "reply");
  assert.equal(f.url, "https://makerworld.com/en/models/3175483");
  assert.match(f.body, /best to use a case/);
  assert.ok(!/[<>]/.test(f.body), "html stripped");
});

test("formatMessage: design boost -> points, boost count, model url", () => {
  const f = M.formatMessage(MSG_BOOSTED, "global");
  assert.equal(f.cls, "points");
  assert.equal(f.url, "https://makerworld.com/en/models/71028");
  assert.match(f.body, /boosted/);
  assert.match(f.body, /Cleveland Browns Lightbox/);
  assert.match(f.body, /6 total/);
});

test("formatMessage: system message -> title, no design -> notification centre", () => {
  const f = M.formatMessage(MSG_SYSTEM, "global");
  assert.equal(f.cls, "system");
  assert.equal(f.url, "https://makerworld.com/en/my/notification");
  assert.match(f.body, /Discontinuation Notice/);
  assert.match(f.body, /Thank you for the journey/);
});

test("formatMessage: community like digs post.designId", () => {
  const f = M.formatMessage(MSG_COMMUNITY, "global");
  assert.equal(f.cls, "like");
  assert.equal(f.url, "https://makerworld.com/en/models/3034987");
  assert.match(f.body, /Aaron/);
});

test("urlMessages + categoryParamForClass", () => {
  assert.match(M.urlMessages("global", 15, 0, 1), /[?&]type=1(&|$)/);
  assert.ok(!/type=/.test(M.urlMessages("global", 15, 0)), "no category -> no type param");
  assert.equal(M.categoryParamForClass("comment"), 1);
  assert.equal(M.categoryParamForClass("reply"), 1);
  assert.equal(M.categoryParamForClass("like"), 5);
  assert.equal(M.categoryParamForClass("points"), 2);
  assert.equal(M.categoryParamForClass("system"), 3);
  assert.equal(M.categoryParamForClass("follow"), 3);
});

test("mergeMessageLists: dedup, drop print, newest first, limit", () => {
  const listA = [M.formatMessage(MSG_COMMENTED, "global"), M.formatMessage(MSG_PRINT, "global")];
  const listB = [M.formatMessage(MSG_REPLIED, "global"), M.formatMessage(MSG_COMMENTED, "global")];
  const merged = M.mergeMessageLists([listA, listB], "global", { dropPrint: true, limit: 10 });
  assert.equal(merged.length, 2, "print dropped, MSG_COMMENTED deduped");
  assert.equal(String(merged[0].id), "2225071994", "MSG_REPLIED (Sep 1 01:00) newest");
  assert.ok(merged.every((m) => m.cls !== "print"));
});

test("selectFresh: unseen + allowed + capped + oldest-first", () => {
  const mk = (id, type, ms) => ({ id, type, createTime: ms, designCommented: { designInfo: { id: 1 } } });
  const raw = [
    mk("a", 201, 30000), // comment
    { id: "b", type: 603, createTime: 10000, communityPostLiked: {} }, // like
    mk("c", 201, 20000), // comment
    { id: "d", type: 301, createTime: 40000, followed: {} }, // follow
  ];
  const out = M.selectFresh(raw, ["a"], ["comment", "like"], 5, "global");
  assert.deepEqual(out.map((x) => x.id), ["b", "c"], "b(10s) before c(20s); a seen; d wrong class");

  const capped = M.selectFresh(raw, [], ["comment", "like", "follow"], 2, "global");
  assert.deepEqual(capped.map((x) => x.id), ["a", "d"], "keep newest 2 by ts (a=30s, d=40s)");
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

// ---- followers + boost tokens (real /my/profile shape) -----------

const PROFILE = {
  name: "dreed10", handle: "dreed10", uid: 654298191,
  point: 7841, pointRegular: 4469, pointExclusive: 3372.8,
  boost: 0, boostGained: 207, fanCount: 194, followCount: 1,
  downloadCount: 11550, likeCount: 2221, collectionCount: 6223, myLikeCount: 8,
};

test("parse profile: name, handle, followers, boost", () => {
  assert.equal(M.parseProfileName(PROFILE), "dreed10");
  assert.equal(M.parseProfileHandle(PROFILE), "dreed10");
  assert.equal(M.parseFollowerCount(PROFILE), 194);
  assert.equal(M.parseBoostCount(PROFILE), 0, "0 tokens is a value, not null");
  assert.equal(M.parseBoostCount({ nope: 1 }), null);
  assert.equal(M.parseFollowerCount({ nope: 1 }), null);
});

test("followersUrl / boostPageUrl", () => {
  assert.equal(M.followersUrl("global", "dreed10"), "https://makerworld.com/en/@dreed10");
  assert.equal(M.followersUrl("global", ""), "https://makerworld.com/en/my/notification");
  assert.match(M.boostPageUrl("global"), /makerworld\.com\/en\//);
});

test("boostExpirySoonest: soonest future expiry, ignores past", () => {
  const now = Date.parse("2026-09-06T00:00:00Z");
  const msgs = [
    { pointBoostingRightGet: { boostingRightId: 1, expireAt: "2026-08-01T00:00:00Z" } }, // past
    { pointBoostingRightExpireRemind: { boostingRightId: 2, expireAt: "2026-09-20T00:00:00Z" } },
    { pointBoostingRightExpireRemind: { boostingRightId: 3, expireAt: "2026-09-10T00:00:00Z" } }, // soonest
    { designCommented: {} },
  ];
  const s = M.boostExpirySoonest(msgs, now);
  assert.equal(s.rightId, "3");
  assert.equal(s.iso, "2026-09-10T00:00:00Z");
  assert.equal(M.boostExpirySoonest([{ pointBoostingRightGet: { expireAt: "2020-01-01T00:00:00Z" } }], now), null);
  assert.equal(M.boostExpirySoonest([], now), null);
});

test("formatMessage: boost-expiry reminder, grant, badge", () => {
  const now = Date.parse("2026-09-06T00:00:00Z");
  const remind = M.formatMessage({
    id: 9, type: 502, createTime: "2026-09-06T00:00:00Z",
    pointBoostingRightExpireRemind: { boostingRightId: 3, expireAt: "2026-09-10T00:00:00Z", earnReason: "plan" },
  }, "global");
  assert.equal(remind.cls, "points");
  assert.equal(remind.title, "Boost token expiring");
  assert.match(remind.body, /2026-09-10/);
  assert.match(remind.url, /boost/);

  const grant = M.formatMessage({
    id: 8, type: 501, pointBoostingRightGet: { boostingRightId: 3, expireAt: "2026-10-01T00:00:00Z" },
  }, "global");
  assert.equal(grant.cls, "points");
  assert.match(grant.body, /boost token/i);

  const badge = M.formatMessage({
    id: 7, type: 815, newBadgeReceived: { badgeTitle: "MakerWorld Guardian" },
  }, "global");
  assert.equal(badge.cls, "system");
  assert.match(badge.body, /MakerWorld Guardian/);
});

test("untilTime / isoDate", () => {
  const now = 1_000_000_000_000;
  assert.equal(M.untilTime(now + 3 * 86400 * 1000, now), "in 3 days");
  assert.equal(M.untilTime(now + 5 * 3600 * 1000, now), "in 5 hours");
  assert.equal(M.untilTime(now - 1000, now), "now");
  assert.equal(M.isoDate("2026-09-10T00:00:00Z"), "2026-09-10");
  assert.equal(M.isoDate("garbage"), "");
});

test("normalizedConfig: boostExpiryWarnDays clamp", () => {
  assert.equal(M.normalizedConfig({ boostExpiryWarnDays: 99 }).boostExpiryWarnDays, 30);
  assert.equal(M.normalizedConfig({ boostExpiryWarnDays: -3 }).boostExpiryWarnDays, 0);
  assert.equal(M.normalizedConfig({ boostExpiryWarnDays: "7" }).boostExpiryWarnDays, 7);
  assert.equal(M.normalizedConfig(null).boostExpiryWarnDays, 5);
});

// ---- creator stat milestones -----------------------------------

test("profileStat reads received download/like/collection totals", () => {
  assert.equal(M.profileStat(PROFILE, "downloads"), 11550);
  assert.equal(M.profileStat(PROFILE, "likes"), 2221);
  assert.equal(M.profileStat(PROFILE, "collections"), 6223);
  assert.equal(M.profileStat({ data: { downloadCount: "9" } }, "downloads"), 9);
  assert.equal(M.profileStat({ nope: 1 }, "downloads"), null);
});

test("milestoneStep scales with size", () => {
  assert.equal(M.milestoneStep(400), 250);
  assert.equal(M.milestoneStep(5000), 1000);
  assert.equal(M.milestoneStep(50000), 5000);
  assert.equal(M.milestoneStep(500000), 25000);
  assert.equal(M.milestoneStep(5000000), 100000);
});

test("highestMilestoneCrossed", () => {
  assert.equal(M.highestMilestoneCrossed(-1, 5000), 0, "no baseline -> silent");
  assert.equal(M.highestMilestoneCrossed(11400, 11550), 0, "no round number crossed");
  assert.equal(M.highestMilestoneCrossed(9500, 10600), 10000, "crossed 10k");
  assert.equal(M.highestMilestoneCrossed(950, 1300), 1000, "crossed tier boundary");
  assert.equal(M.highestMilestoneCrossed(2999, 3000), 3000, "exact landing counts");
  assert.equal(M.highestMilestoneCrossed(3000, 3000), 0, "no change");
  assert.equal(M.highestMilestoneCrossed(3200, 3100), 0, "went down");
});

test("normalizedConfig: notifyMilestones", () => {
  assert.equal(M.normalizedConfig({ notifyMilestones: "off" }).notifyMilestones, false);
  assert.equal(M.normalizedConfig(null).notifyMilestones, true);
});

// ---- "My models" tab -----------------------------------------

const MY_DESIGNS = {
  total: 42,
  hits: [
    {
      id: 159401, title: "Wago 221 Connector Box", slug: "wago-221-connector-box",
      coverUrl: "https://x/c.png", likeCount: 575, collectionCount: 300, shareCount: 0,
      printCount: 470, commentCount: 12, downloadCount: 941, readCount: 0, boostCnt: 3,
      instances: [{ big: "payload we ignore" }],
    },
    {
      id: 462884, title: "The Princess Bride Buttercup Dagger", slug: "buttercup-dagger",
      likeCount: 279, printCount: 227, downloadCount: 434, commentCount: 4,
    },
    { id: 71028, title: "Cleveland Browns Lightbox", downloadCount: 210, likeCount: 88, printCount: 190 },
  ],
};

test("parseMyDesigns keeps only stat fields + builds slug URL", () => {
  const p = M.parseMyDesigns(MY_DESIGNS, "global");
  assert.equal(p.total, 42);
  assert.equal(p.designs.length, 3);
  const d0 = p.designs[0];
  assert.equal(d0.id, "159401");
  assert.equal(d0.downloads, 941);
  assert.equal(d0.likes, 575);
  assert.equal(d0.prints, 470);
  assert.equal(d0.comments, 12);
  assert.equal(d0.boosts, 3);
  assert.equal(d0.url, "https://makerworld.com/en/models/159401-wago-221-connector-box");
  assert.equal(d0.instances, undefined, "bulk payload dropped");
  // missing slug -> bare id URL
  assert.equal(p.designs[2].url, "https://makerworld.com/en/models/71028");
});

test("sortDesigns by each stat, descending, non-mutating", () => {
  const p = M.parseMyDesigns(MY_DESIGNS, "global");
  assert.deepEqual(M.sortDesigns(p.designs, "downloads").map((d) => d.id), ["159401", "462884", "71028"]);
  assert.deepEqual(M.sortDesigns(p.designs, "likes").map((d) => d.id), ["159401", "462884", "71028"]);
  assert.deepEqual(M.sortDesigns(p.designs, "prints").map((d) => d.id), ["159401", "462884", "71028"]);
  assert.equal(p.designs[0].id, "159401", "input order untouched");
});

test("urlMyDesigns / designUrl", () => {
  assert.match(M.urlMyDesigns("global", 60, 0), /design-service\/my\/design\/published\?limit=60&offset=0$/);
  assert.equal(M.designUrl("global", 5, "my-slug"), "https://makerworld.com/en/models/5-my-slug");
  assert.equal(M.designUrl("global", 5, ""), "https://makerworld.com/en/models/5");
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
