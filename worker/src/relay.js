// relay.js -- request handling for the Cloudflare relay.
// Kept free of Cloudflare-only imports so it can be tested with plain Node (see test/).
//
// Telegram -> POST /telegram     store the message, react 👀, start the GitHub job
// GitHub job -> GET /inbox       read messages newer than ?after=
//               POST /ack        forget messages up to { upTo } once data is pushed
// You (setup) -> POST /admin/register | /admin/unregister | /admin/test-dispatch, GET /admin/status

const TG_API = "https://api.telegram.org";
const GH_API = "https://api.github.com";

// Messages arriving this soon after a dispatch are picked up by that run anyway,
// because the job only reads the inbox after its ~1 minute R setup.
export const DISPATCH_GAP_MS = 10_000;

export async function handleRequest(request, env, ctx, inbox) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const method = request.method;

  if (path === "/telegram" && method === "POST") return receiveUpdate(request, env, ctx, inbox);
  if (path === "/" && method === "GET") return text("Telegram tracker relay is running.");

  // Everything below is for the GitHub job and for you, never for Telegram.
  if (!isAuthorized(request, env)) return json({ ok: false, error: "unauthorized" }, 401);

  if (path === "/inbox" && method === "GET") {
    const after = toInt(url.searchParams.get("after"), 0);
    const limit = Math.min(Math.max(toInt(url.searchParams.get("limit"), 100), 1), 100);
    return json({ ok: true, updates: await inbox.list(after, limit) });
  }
  if (path === "/inbox/count" && method === "GET") {
    const after = toInt(url.searchParams.get("after"), 0);
    return json({ ok: true, count: await inbox.count(after) });
  }
  if (path === "/ack" && method === "POST") {
    const body = await request.json().catch(() => ({}));
    const upTo = toInt(body.upTo, -1);
    if (upTo < 0) return json({ ok: false, error: "upTo is required" }, 400);
    return json({ ok: true, deleted: await inbox.ack(upTo) });
  }
  if (path === "/admin/register" && method === "POST") {
    if (!/^[A-Za-z0-9_-]{32,256}$/.test(env.RELAY_SECRET || "")) {
      return json({ ok: false, error: "RELAY_SECRET must be 32-256 letters, digits, _ or -" }, 400);
    }
    const result = await telegram(env, "setWebhook", {
      url: `${url.origin}/telegram`,
      secret_token: env.RELAY_SECRET,
      allowed_updates: ["message"],
      drop_pending_updates: false, // anything sent before the switch is delivered here, not lost
    });
    return json(result, result.ok ? 200 : 502);
  }
  if (path === "/admin/unregister" && method === "POST") {
    const result = await telegram(env, "deleteWebhook", { drop_pending_updates: false });
    return json(result, result.ok ? 200 : 502);
  }
  if (path === "/admin/test-dispatch" && method === "POST") {
    const result = await triggerRun(env);
    await inbox.recordDispatch(result);
    return json(result, result.ok ? 200 : 502);
  }
  if (path === "/admin/status" && method === "GET") {
    const webhook = await telegram(env, "getWebhookInfo", {});
    return json({
      ok: true,
      waiting: await inbox.count(0),
      lastDispatch: await inbox.dispatchInfo(),
      webhook: webhook.ok ? webhook.result : webhook,
    });
  }
  return json({ ok: false, error: "not found" }, 404);
}

async function receiveUpdate(request, env, ctx, inbox) {
  const given = request.headers.get("X-Telegram-Bot-Api-Secret-Token") || "";
  if (!safeEqual(given, env.RELAY_SECRET || "")) return text("forbidden", 403);

  const update = await request.json().catch(() => null);
  const msg = update && update.message;
  if (!update || !Number.isInteger(update.update_id) || !msg) return text("ok");

  // Strangers who find the bot never reach GitHub, so they can't burn your Actions minutes.
  if (String(msg.chat && msg.chat.id) !== String(env.TELEGRAM_CHAT_ID || "").trim()) return text("ok");

  // Store before answering: if this throws, Telegram gets a 500 and retries the delivery.
  await inbox.add(update.update_id, JSON.stringify(update));
  ctx.waitUntil(afterReceive(env, inbox, msg));
  return text("ok");
}

async function afterReceive(env, inbox, msg) {
  await Promise.allSettled([
    telegram(env, "setMessageReaction", {
      chat_id: msg.chat.id,
      message_id: msg.message_id,
      reaction: [{ type: "emoji", emoji: "👀" }],
    }),
    maybeDispatch(env, inbox),
  ]);
}

async function maybeDispatch(env, inbox) {
  if (!(await inbox.claimDispatch(Date.now(), DISPATCH_GAP_MS))) return;
  await inbox.recordDispatch(await triggerRun(env));
}

// Starts .github/workflows/bot.yml. If this fails (say the token expired), the
// workflow's backup schedule still picks the message up, just later.
export async function triggerRun(env) {
  if (!env.GH_DISPATCH_TOKEN || !env.GITHUB_REPO) {
    return { ok: false, error: "GH_DISPATCH_TOKEN or GITHUB_REPO is not set" };
  }
  const workflow = env.WORKFLOW_FILE || "bot.yml";
  try {
    const res = await fetch(`${GH_API}/repos/${env.GITHUB_REPO}/actions/workflows/${workflow}/dispatches`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.GH_DISPATCH_TOKEN}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "telegram-tracker-relay",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ ref: env.GITHUB_BRANCH || "main", inputs: { reason: "telegram" } }),
    });
    if (res.ok) return { ok: true, status: res.status };
    return { ok: false, status: res.status, error: (await res.text()).slice(0, 300) };
  } catch (err) {
    return { ok: false, error: String(err).slice(0, 300) };
  }
}

async function telegram(env, method, payload) {
  try {
    const res = await fetch(`${TG_API}/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    return await res.json();
  } catch {
    return { ok: false, description: `Could not reach Telegram (${method})` };
  }
}

function isAuthorized(request, env) {
  const header = request.headers.get("Authorization") || "";
  return header.startsWith("Bearer ") && safeEqual(header.slice(7), env.RELAY_SECRET || "");
}

// Constant-time comparison; an empty secret never matches, so a missing secret fails closed.
export function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || b.length === 0 || a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function toInt(value, fallback) {
  if (value === null || value === undefined || value === "") return fallback;
  const n = Number(value);
  return Number.isFinite(n) ? Math.floor(n) : fallback;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

function text(body, status = 200) {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } });
}
