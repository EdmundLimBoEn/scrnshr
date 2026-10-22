import { type IceResponse, SESSION_DURATION_MS, UUID_PATTERN, parseIceServers } from "./protocol";
import { SessionRoom } from "./session";
import { RequestLimiter } from "./rate-limit";
import { bearer, equalHash, error, hash, json, makeToken, peerBearer } from "./security";

export { SessionRoom, RequestLimiter };

export interface Env {
  SESSIONS: DurableObjectNamespace<SessionRoom>;
  RATE_LIMITS: DurableObjectNamespace<RequestLimiter>;
  INGRESS_LIMIT: RateLimit;
  OWNER_TOKEN: string;
  TURN_KEY_ID?: string;
  TURN_API_TOKEN?: string;
  ALLOW_STUN_ONLY?: string;
}

async function ice(request: Request, env: Env, room: DurableObjectStub<SessionRoom>): Promise<Response> {
  const token = peerBearer(request);
  if (token === null) return error("Peer Bearer capability required", 401);
  const authorization = await room.authorizeIce(token);
  if (authorization.kind === "denied") return error(authorization.message, authorization.status);
  if (!env.TURN_KEY_ID || !env.TURN_API_TOKEN) {
    if (env.ALLOW_STUN_ONLY === "true") {
      return json({ iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }], connectivity: "local-only" } satisfies IceResponse);
    }
    return error("TURN is not configured. Set TURN_KEY_ID and TURN_API_TOKEN for internet sessions, or explicitly enable ALLOW_STUN_ONLY=true for LAN development.", 503);
  }
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(env.TURN_KEY_ID)) return error("TURN_KEY_ID configuration is invalid", 503);
  try {
    const ttl = Math.max(60, Math.min(
      Math.ceil((authorization.expiresAt - Date.now()) / 1000) + 600,
      Math.ceil(SESSION_DURATION_MS / 1000) + 600,
    ));
    const response = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`, {
      method: "POST",
      headers: { Authorization: `Bearer ${env.TURN_API_TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify({ ttl }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) {
      console.error(JSON.stringify({ event: "turn-credential-failure", status: response.status }));
      return error("TURN credential generation failed. Check the backend TURN key and API token.", 502);
    }
    const servers = parseIceServers(await response.json());
    if (servers === null || !servers.some(server => server.urls.some(url => /^turns?:/.test(url)))) {
      return error("TURN provider returned invalid ICE servers", 502);
    }
    // TURN issuance can outlive session stop, rejection or expiry. Re-check before releasing credentials.
    if (!await room.isAuthorized(token)) return error("Session ended or peer capability expired", 410);
    return json({ iceServers: servers, connectivity: "internet" } satisfies IceResponse);
  } catch {
    console.error(JSON.stringify({ event: "turn-credential-failure", reason: "network-or-response" }));
    return error("TURN service unavailable. Retry or check backend configuration.", 502);
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") return json({ ok: true, service: "scrnshr-signaling" });
    if (url.search !== "") return error("Query parameters are not supported; use Bearer authorization", 400);
    if (request.method === "POST" && url.pathname === "/v1/sessions") {
      if (!env.OWNER_TOKEN || env.OWNER_TOKEN.length < 32) return error("Backend OWNER_TOKEN must be configured with at least 32 characters", 503);
      const token = bearer(request);
      if (token === null || !equalHash(await hash(token), await hash(env.OWNER_TOKEN))) return error("Owner Bearer authorization required", 401);
      const ownerKey = await hash(`owner:${env.OWNER_TOKEN}`);
      const ipKey = await hash(`ip:${request.headers.get("CF-Connecting-IP") ?? "local-development"}`);
      const ownerAllowed = await env.RATE_LIMITS.getByName(ownerKey).allow(30);
      const ipAllowed = await env.RATE_LIMITS.getByName(ipKey).allow(12);
      if (!ownerAllowed || !ipAllowed) return error("Session creation rate limited. Retry in one hour.", 429);
      const sessionId = crypto.randomUUID();
      const receiverToken = makeToken();
      const joinToken = makeToken();
      const [receiverHash, joinHash] = await Promise.all([hash(receiverToken), hash(joinToken)]);
      const { expiresAt } = await env.SESSIONS.getByName(sessionId).initialize({ sessionId, receiverHash, joinHash });
      return json({ sessionId, receiverToken, joinToken, expiresAt: new Date(expiresAt).toISOString() }, 201);
    }
    const match = /^\/v1\/sessions\/([^/]+)\/(ws|ice)$/.exec(url.pathname);
    const sessionId = match?.[1];
    const operation = match?.[2];
    if (match === null || sessionId === undefined || operation === undefined) return error("Not found", 404);
    if (!UUID_PATTERN.test(sessionId)) return error("Invalid session ID", 400);
    if (request.method !== "GET") return error("GET required", 405);
    if (peerBearer(request) === null) return error("Peer Bearer capability required", 401);
    if (operation === "ws" && request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return error("WebSocket upgrade required", 426);
    const { success } = await env.INGRESS_LIMIT.limit({
      key: request.headers.get("CF-Connecting-IP") ?? "local-development",
    });
    if (!success) return error("Session requests rate limited. Retry in one minute.", 429);
    const room = env.SESSIONS.getByName(sessionId);
    if (operation === "ice") return ice(request, env, room);
    return room.fetch(request);
  },
} satisfies ExportedHandler<Env>;
