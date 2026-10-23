// Run from worker/:  node --test test/relay.test.js   (Node 20+, no installs needed)
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { handleRequest, safeEqual } from "../src/relay.js";

const SECRET = "s".repeat(40);
const env = {
  TELEGRAM_BOT_TOKEN: "123:abc",
  TELEGRAM_CHAT_ID: "42",
  RELAY_SECRET: SECRET,
  GH_DISPATCH_TOKEN: "ghp_test",
  GITHUB_REPO: "me/tracker",
  GITHUB_BRANCH: "main",
  WORKFLOW_FILE: "bot.yml",
};

// In-memory stand-in for the Durable Object.
class FakeInbox {
  constructor() { this.rows = new Map(); this.lastDispatch = 0; this.dispatch = null; }
  async add(id, body) { if (!this.rows.has(id)) this.rows.set(id, body); }
  async list(after, limit) {
    return [...this.rows.keys()].filter((id) => id > after).sort((a, b) => a - b)
      .slice(0, limit).map((id) => JSON.parse(this.rows.get(id)));
  }
  async count(after) { return [...this.rows.keys()].filter((id) => id > after).length; }
  async ack(upTo) {
    let n = 0;
    for (const id of [...this.rows.keys()]) if (id <= upTo) { this.rows.delete(id); n++; }
    return n;
  }
  async claimDispatch(now, gap) {
    if (now - this.lastDispatch < gap) return false;
    this.lastDispatch = now;
    return true;
  }
  async recordDispatch(result) { this.dispatch = result; }
  async dispatchInfo() { return this.dispatch; }
}

let inbox, calls, pending;
const ctx = { waitUntil: (p) => pending.push(p) };

beforeEach(() => {
  inbox = new FakeInbox();
  calls = [];
  pending = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), body: init && init.body ? JSON.parse(init.body) : null });
    if (String(url).startsWith("https://api.github.com")) return new Response(null, { status: 204 });
    return Response.json({ ok: true, result: true });
  };
});

const BASE = "https://relay.example.workers.dev";

function update(id, chatId = 42, text = "250 lunch") {
  return { update_id: id, message: { message_id: id + 1000, date: 1761200000, chat: { id: chatId }, text } };
}

async function send(path, { method = "GET", body, headers = {} } = {}) {
  const req = new Request(BASE + path, {
    method,
    headers: { "Content-Type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const res = await handleRequest(req, env, ctx, inbox);
  await Promise.all(pending);
  return res;
}

const fromTelegram = (body, secret = SECRET) =>
  send("/telegram", { method: "POST", body, headers: { "X-Telegram-Bot-Api-Secret-Token": secret } });
const auth = { Authorization: `Bearer ${SECRET}` };

test("home page is public", async () => {
  assert.equal((await send("/")).status, 200);
});

test("wrong webhook secret is rejected and nothing is stored", async () => {
  const res = await fromTelegram(update(1), "wrong");
  assert.equal(res.status, 403);
  assert.equal(await inbox.count(0), 0);
  assert.equal(calls.length, 0);
});

test("owner message is stored, gets 👀 and starts the workflow", async () => {
  const res = await fromTelegram(update(10));
  assert.equal(res.status, 200);
  assert.equal(await inbox.count(0), 1);
  const reaction = calls.find((c) => c.url.endsWith("/setMessageReaction"));
  assert.equal(reaction.body.message_id, 1010);
  assert.equal(reaction.body.reaction[0].emoji, "👀");
  const dispatch = calls.find((c) => c.url.startsWith("https://api.github.com"));
  assert.equal(dispatch.url, "https://api.github.com/repos/me/tracker/actions/workflows/bot.yml/dispatches");
  assert.deepEqual(dispatch.body, { ref: "main", inputs: { reason: "telegram" } });
  assert.equal(inbox.dispatch.ok, true);
});

test("strangers are ignored without touching GitHub", async () => {
  const res = await fromTelegram(update(11, 999));
  assert.equal(res.status, 200);
  assert.equal(await inbox.count(0), 0);
  assert.equal(calls.length, 0);
});

test("a quick second message does not start a second run", async () => {
  await fromTelegram(update(20));
  await fromTelegram(update(21));
  assert.equal(await inbox.count(0), 2);
  assert.equal(calls.filter((c) => c.url.startsWith("https://api.github.com")).length, 1);
});

test("duplicate deliveries from Telegram are stored once", async () => {
  await fromTelegram(update(30));
  await fromTelegram(update(30));
  assert.equal(await inbox.count(0), 1);
});

test("inbox needs the secret", async () => {
  assert.equal((await send("/inbox")).status, 401);
  assert.equal((await send("/inbox", { headers: { Authorization: "Bearer nope" } })).status, 401);
});

test("inbox lists, counts and acks in order", async () => {
  for (const id of [5, 3, 4]) await inbox.add(id, JSON.stringify(update(id)));
  const list = await (await send("/inbox?after=3", { headers: auth })).json();
  assert.deepEqual(list.updates.map((u) => u.update_id), [4, 5]);
  const count = await (await send("/inbox/count?after=0", { headers: auth })).json();
  assert.equal(count.count, 3);
  const ack = await (await send("/ack", { method: "POST", body: { upTo: "4" }, headers: auth })).json();
  assert.equal(ack.deleted, 2);
  assert.equal(await inbox.count(0), 1);
  assert.equal((await send("/ack", { method: "POST", body: {}, headers: auth })).status, 400);
});

test("register points Telegram at /telegram with the secret", async () => {
  const res = await send("/admin/register", { method: "POST", headers: auth });
  assert.equal(res.status, 200);
  const call = calls.find((c) => c.url.endsWith("/setWebhook"));
  assert.equal(call.body.url, `${BASE}/telegram`);
  assert.equal(call.body.secret_token, SECRET);
  assert.deepEqual(call.body.allowed_updates, ["message"]);
  assert.equal(call.body.drop_pending_updates, false);
});

test("register refuses a weak secret", async () => {
  const weak = { ...env, RELAY_SECRET: "short" };
  const req = new Request(BASE + "/admin/register", { method: "POST", headers: { Authorization: "Bearer short" } });
  assert.equal((await handleRequest(req, weak, ctx, inbox)).status, 400);
});

test("failed dispatch is recorded for /admin/status", async () => {
  globalThis.fetch = async (url) => String(url).startsWith("https://api.github.com")
    ? new Response("Bad credentials", { status: 401 })
    : Response.json({ ok: true, result: { url: `${BASE}/telegram`, pending_update_count: 0 } });
  await fromTelegram(update(40));
  const status = await (await send("/admin/status", { headers: auth })).json();
  assert.equal(status.waiting, 1);
  assert.equal(status.lastDispatch.ok, false);
  assert.equal(status.lastDispatch.status, 401);
  assert.equal(status.webhook.url, `${BASE}/telegram`);
});

test("safeEqual", () => {
  assert.equal(safeEqual("abc", "abc"), true);
  assert.equal(safeEqual("abc", "abd"), false);
  assert.equal(safeEqual("", ""), false);
  assert.equal(safeEqual("ab", "abc"), false);
});
