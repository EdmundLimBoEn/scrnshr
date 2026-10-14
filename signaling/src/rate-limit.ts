import { DurableObject } from "cloudflare:workers";

export class RequestLimiter extends DurableObject<unknown> {
  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env);
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS bucket (id INTEGER PRIMARY KEY CHECK (id = 1), starts_at INTEGER NOT NULL, count INTEGER NOT NULL)");
  }

  async allow(limit: number): Promise<boolean> {
    const now = Date.now();
    const windowMs = 60 * 60 * 1000;
    const row = this.ctx.storage.sql.exec<{ starts_at: number; count: number }>("SELECT starts_at, count FROM bucket WHERE id = 1").toArray()[0];
    if (row === undefined || now - row.starts_at >= windowMs) {
      this.ctx.storage.sql.exec("INSERT OR REPLACE INTO bucket VALUES (1, ?, 1)", now);
      await this.ctx.storage.setAlarm(now + windowMs);
      return true;
    }
    if (row.count >= limit) return false;
    this.ctx.storage.sql.exec("UPDATE bucket SET count = count + 1 WHERE id = 1");
    return true;
  }

  alarm(): void {
    this.ctx.storage.sql.exec("DELETE FROM bucket WHERE starts_at <= ?", Date.now() - 60 * 60 * 1000);
  }
}
