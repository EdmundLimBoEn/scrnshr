import productionWorker, { RequestLimiter, SessionRoom as ProductionSessionRoom, type Env } from "../src/index";

export { RequestLimiter };

export class SessionRoom extends ProductionSessionRoom {
  async runAlarmForTest(): Promise<{ alarm: number | null; status: string | null }> {
    await this.alarm();
    const row = this.ctx.storage.sql.exec<{ status: string }>("SELECT status FROM session WHERE id = 1").toArray()[0];
    return { alarm: await this.ctx.storage.getAlarm(), status: row?.status ?? null };
  }
}

interface TestEnv extends Env { TEST_SESSIONS: DurableObjectNamespace<SessionRoom> }

// This entry point is bundled by tests only. Production builds use src/index.ts.
export default {
  async fetch(request: Request, env: TestEnv): Promise<Response> {
    const path = new URL(request.url).pathname;
    const alarm = /^\/__test\/sessions\/([^/]+)\/alarm$/.exec(path);
    const sessionId = alarm?.[1];
    if (request.method === "POST" && sessionId !== undefined) {
      return Response.json(await env.TEST_SESSIONS.getByName(sessionId).runAlarmForTest());
    }
    if (request.headers.has("X-Test-Forbid-Session-Lookup")) {
      env = { ...env, SESSIONS: new Proxy(env.SESSIONS, {
        get() { throw new Error("Blocked request touched the session namespace"); },
      }) };
    }
    return productionWorker.fetch(request, env);
  },
} satisfies ExportedHandler<TestEnv>;
