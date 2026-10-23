// index.js -- Cloudflare Worker entry point and the inbox it keeps messages in.
import { DurableObject } from "cloudflare:workers";
import { handleRequest } from "./relay.js";

// Holds Telegram updates until the GitHub job confirms it has saved them.
// A single SQLite-backed Durable Object: strongly consistent (unlike KV, a message
// stored here is visible to the very next read) and included in the free plan.
export class Inbox extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS updates (
      id INTEGER PRIMARY KEY, body TEXT NOT NULL, received_at INTEGER NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`);
  }

  add(id, body) {
    this.sql.exec("INSERT OR IGNORE INTO updates (id, body, received_at) VALUES (?, ?, ?)",
      id, body, Date.now());
  }

  list(after, limit) {
    return this.sql.exec("SELECT body FROM updates WHERE id > ? ORDER BY id LIMIT ?", after, limit)
      .toArray().map((row) => JSON.parse(row.body));
  }

  count(after) {
    return this.sql.exec("SELECT COUNT(*) AS n FROM updates WHERE id > ?", after).one().n;
  }

  ack(upTo) {
    return this.sql.exec("DELETE FROM updates WHERE id <= ?", upTo).rowsWritten;
  }

  // True (and records the time) when no dispatch happened in the last gapMs.
  claimDispatch(now, gapMs) {
    const last = Number(this.getMeta("last_dispatch_at") || 0);
    if (now - last < gapMs) return false;
    this.setMeta("last_dispatch_at", String(now));
    return true;
  }

  recordDispatch(result) {
    this.setMeta("last_dispatch_result", JSON.stringify({ at: new Date().toISOString(), ...result }));
  }

  dispatchInfo() {
    const value = this.getMeta("last_dispatch_result");
    return value ? JSON.parse(value) : null;
  }

  getMeta(key) {
    const rows = this.sql.exec("SELECT value FROM meta WHERE key = ?", key).toArray();
    return rows.length ? rows[0].value : null;
  }

  setMeta(key, value) {
    this.sql.exec(
      "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      key, value);
  }
}

export default {
  async fetch(request, env, ctx) {
    const inbox = env.INBOX.get(env.INBOX.idFromName("main"));
    return handleRequest(request, env, ctx, inbox);
  },
};
