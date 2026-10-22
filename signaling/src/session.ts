import { DurableObject } from "cloudflare:workers";
import {
  FRAME_WINDOW_MS, JOIN_DURATION_MS, MAX_FRAME_BYTES, MAX_FRAMES_PER_WINDOW,
  SESSION_DURATION_MS, isRecord, parseClientMessage,
  type Role, type ServerMessage,
} from "./protocol";
import { equalHash, error, hash, peerBearer } from "./security";
import { makeToken } from "./security";

type SessionRow = {
  session_id: string;
  expires_at: number;
  join_expires_at: number;
  receiver_hash: string;
  join_hash: string;
  sender_hash: string | null;
  status: string;
  receiver_connection: string | null;
  sender_connection: string | null;
  receiver_ice_start: number;
  receiver_ice_count: number;
  sender_ice_start: number;
  sender_ice_count: number;
};

interface CommonSession {
  sessionId: string;
  expiresAt: number;
  joinExpiresAt: number;
  receiverHash: string;
  receiverConnection: string | null;
  senderConnection: string | null;
}
type Session =
  | CommonSession & { kind: "pending"; joinHash: string }
  | CommonSession & { kind: "approved"; senderHash: string }
  | CommonSession & { kind: "ended" };

interface Attachment {
  role: Role;
  connectionId: string;
  frameWindowStart: number;
  frameCount: number;
}

function attachment(socket: WebSocket): Attachment | null {
  const value: unknown = socket.deserializeAttachment();
  if (!isRecord(value) || (value.role !== "receiver" && value.role !== "sender")
    || typeof value.connectionId !== "string" || typeof value.frameWindowStart !== "number"
    || typeof value.frameCount !== "number") return null;
  return {
    role: value.role, connectionId: value.connectionId,
    frameWindowStart: value.frameWindowStart, frameCount: value.frameCount,
  };
}

function currentConnection(session: Session, role: Role): string | null {
  return role === "receiver" ? session.receiverConnection : session.senderConnection;
}

export type IceAuthorization = { kind: "authorized"; expiresAt: number }
  | { kind: "denied"; status: number; message: string };

export class SessionRoom extends DurableObject<unknown> {
  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS session (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      session_id TEXT NOT NULL, expires_at INTEGER NOT NULL, join_expires_at INTEGER NOT NULL,
      receiver_hash TEXT NOT NULL, join_hash TEXT NOT NULL, sender_hash TEXT,
      status TEXT NOT NULL CHECK (status IN ('pending','approved','ended')),
      receiver_connection TEXT, sender_connection TEXT,
      receiver_ice_start INTEGER NOT NULL DEFAULT 0, receiver_ice_count INTEGER NOT NULL DEFAULT 0,
      sender_ice_start INTEGER NOT NULL DEFAULT 0, sender_ice_count INTEGER NOT NULL DEFAULT 0
    )`);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS role_quota (
      role TEXT NOT NULL, kind TEXT NOT NULL, starts_at INTEGER NOT NULL, count INTEGER NOT NULL,
      PRIMARY KEY (role, kind)
    )`);
  }

  private quota(role: Role, kind: "frame" | "connect"): { startsAt: number; count: number } | null {
    const row = this.ctx.storage.sql.exec<{ starts_at: number; count: number }>(
      "SELECT starts_at, count FROM role_quota WHERE role = ? AND kind = ?", role, kind,
    ).toArray()[0];
    return row === undefined ? null : { startsAt: row.starts_at, count: row.count };
  }

  private saveQuota(role: Role, kind: "frame" | "connect", startsAt: number, count: number): void {
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO role_quota VALUES (?, ?, ?, ?)", role, kind, startsAt, count);
  }

  // Connection attempts are rare, so they are counted in SQLite and survive everything.
  private allowConnect(role: Role, limit: number, windowMs: number): boolean {
    const now = Date.now();
    const row = this.quota(role, "connect");
    const fresh = row === null || now - row.startsAt >= windowMs;
    if (!fresh && row.count >= limit) return false;
    this.saveQuota(role, "connect", fresh ? now : row.startsAt, fresh ? 1 : row.count + 1);
    return true;
  }

  async initialize(input: {
    sessionId: string; receiverHash: string; joinHash: string;
  }): Promise<{ expiresAt: number }> {
    const expiresAt = Date.now() + SESSION_DURATION_MS;
    const joinExpiresAt = Date.now() + JOIN_DURATION_MS;
    this.ctx.storage.sql.exec(
      `INSERT INTO session (id, session_id, expires_at, join_expires_at, receiver_hash, join_hash, status)
       VALUES (1, ?, ?, ?, ?, ?, 'pending')`,
      input.sessionId, expiresAt, joinExpiresAt, input.receiverHash, input.joinHash,
    );
    await this.ctx.storage.setAlarm(joinExpiresAt);
    return { expiresAt };
  }

  private row(): SessionRow | null {
    return this.ctx.storage.sql.exec<SessionRow>("SELECT * FROM session WHERE id = 1").toArray()[0] ?? null;
  }

  private session(): Session | null {
    const row = this.row();
    if (row === null) return null;
    const base: CommonSession = {
      sessionId: row.session_id, expiresAt: row.expires_at, joinExpiresAt: row.join_expires_at,
      receiverHash: row.receiver_hash, receiverConnection: row.receiver_connection,
      senderConnection: row.sender_connection,
    };
    switch (row.status) {
      case "pending": return { ...base, kind: "pending", joinHash: row.join_hash };
      case "approved":
        if (row.sender_hash === null) throw new Error("Approved session missing sender capability");
        return { ...base, kind: "approved", senderHash: row.sender_hash };
      case "ended": return { ...base, kind: "ended" };
      default: throw new Error("Invalid persisted session state");
    }
  }

  private active(): Session | null {
    const state = this.session();
    if (state === null || state.kind === "ended") return null;
    if (Date.now() >= state.expiresAt) { this.end("session-expired"); return null; }
    if (state.kind === "pending" && Date.now() >= state.joinExpiresAt) {
      this.end("pairing-expired"); return null;
    }
    return state;
  }

  private roleFor(state: Session, tokenHash: string, allowJoin: boolean): Role | null {
    if (equalHash(tokenHash, state.receiverHash)) return "receiver";
    if (state.kind === "approved" && equalHash(tokenHash, state.senderHash)) return "sender";
    if (allowJoin && state.kind === "pending" && equalHash(tokenHash, state.joinHash)) return "sender";
    return null;
  }

  async authorizeIce(token: string): Promise<IceAuthorization> {
    const tokenHash = await hash(token);
    const state = this.active();
    if (state === null) return { kind: "denied", status: 410, message: "Session ended or expired" };
    const role = this.roleFor(state, tokenHash, false);
    if (role === null) return { kind: "denied", status: 401, message: "Invalid peer capability or approval required" };
    const row = this.row();
    if (row === null) return { kind: "denied", status: 410, message: "Session ended" };
    const start = role === "receiver" ? row.receiver_ice_start : row.sender_ice_start;
    const count = role === "receiver" ? row.receiver_ice_count : row.sender_ice_count;
    const now = Date.now();
    const newWindow = now - start >= 60_000;
    if (!newWindow && count >= 12) return { kind: "denied", status: 429, message: "ICE credential requests rate limited" };
    if (role === "receiver") {
      this.ctx.storage.sql.exec("UPDATE session SET receiver_ice_start = ?, receiver_ice_count = ? WHERE id = 1", newWindow ? now : start, newWindow ? 1 : count + 1);
    } else {
      this.ctx.storage.sql.exec("UPDATE session SET sender_ice_start = ?, sender_ice_count = ? WHERE id = 1", newWindow ? now : start, newWindow ? 1 : count + 1);
    }
    return { kind: "authorized", expiresAt: state.expiresAt };
  }

  async isAuthorized(token: string): Promise<boolean> {
    const tokenHash = await hash(token);
    const state = this.active();
    return state !== null && this.roleFor(state, tokenHash, false) !== null;
  }

  async fetch(request: Request): Promise<Response> {
    if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return error("WebSocket upgrade required", 426);
    }
    const token = peerBearer(request);
    if (token === null) return error("Peer Bearer capability required", 401);
    const tokenHash = await hash(token);
    const state = this.active();
    if (state === null) return error("Session ended or expired", 410);
    const role = this.roleFor(state, tokenHash, true);
    if (role === null) return error("Invalid peer capability", 401);
    if (!this.allowConnect(role, 12, 60_000)) return error("Connection attempts rate limited", 429);
    if (role === "sender" && state.kind === "pending" && this.socketFor(state, role) !== null) {
      return error("A sender is already awaiting approval", 409);
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const previous = this.socketFor(state, role);
    const connectionId = crypto.randomUUID();
    this.ctx.acceptWebSocket(server, [role]);
    // A reconnect inherits the role's frame budget from the replaced socket, or from the
    // window saved when the last socket for this role closed, so reconnecting cannot reset it.
    const now = Date.now();
    const prior = previous !== null ? attachment(previous) : null;
    const inherited = prior !== null
      ? { startsAt: prior.frameWindowStart, count: prior.frameCount }
      : this.quota(role, "frame");
    const window = inherited !== null && now - inherited.startsAt < FRAME_WINDOW_MS
      ? inherited : { startsAt: now, count: 0 };
    server.serializeAttachment({ role, connectionId, frameWindowStart: window.startsAt, frameCount: window.count } satisfies Attachment);
    this.setConnection(role, connectionId);
    if (previous !== null) {
      this.send(previous, { type: "error", message: "Connection replaced by an authenticated reconnect" });
      previous.close(4001, "Authenticated reconnect");
    }

    const current = this.session();
    if (current === null) throw new Error("Session disappeared during connection");
    if (current.kind === "approved") {
      this.send(server, { type: "approved" });
      this.announcePeers(current);
    } else {
      this.send(server, { type: "waiting" });
      if (this.socketFor(current, "sender") !== null) {
        const receiver = this.socketFor(current, "receiver");
        if (receiver !== null) this.send(receiver, { type: "approval-required" });
      }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  private setConnection(role: Role, connectionId: string | null): void {
    this.ctx.storage.sql.exec(role === "receiver"
      ? "UPDATE session SET receiver_connection = ? WHERE id = 1"
      : "UPDATE session SET sender_connection = ? WHERE id = 1", connectionId);
  }

  private socketFor(state: Session, role: Role): WebSocket | null {
    const connectionId = currentConnection(state, role);
    if (connectionId === null) return null;
    for (const socket of this.ctx.getWebSockets(role)) {
      const metadata = attachment(socket);
      if (metadata?.connectionId === connectionId && socket.readyState === WebSocket.OPEN) return socket;
    }
    return null;
  }

  private send(socket: WebSocket, message: ServerMessage): void {
    if (socket.readyState !== WebSocket.OPEN) return;
    try { socket.send(JSON.stringify(message)); }
    catch { socket.close(1011, "Delivery failed"); }
  }

  private announcePeers(state: Session): void {
    const receiver = this.socketFor(state, "receiver");
    const sender = this.socketFor(state, "sender");
    if (receiver !== null && sender !== null) {
      this.send(receiver, { type: "peer", role: "sender" });
      this.send(sender, { type: "peer", role: "receiver" });
    }
  }

  async webSocketMessage(socket: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const metadata = attachment(socket);
    const state = this.active();
    if (metadata === null || state === null || currentConnection(state, metadata.role) !== metadata.connectionId) {
      socket.close(4001, "Inactive connection"); return;
    }
    if (typeof raw !== "string") { socket.close(1003, "Text messages required"); return; }
    if (new TextEncoder().encode(raw).byteLength > MAX_FRAME_BYTES) {
      this.send(socket, { type: "error", message: "Signaling frame exceeds 64 KiB" });
      socket.close(1009, "Frame too large"); return;
    }
    const now = Date.now();
    if (now - metadata.frameWindowStart >= FRAME_WINDOW_MS) {
      metadata.frameWindowStart = now; metadata.frameCount = 0;
    }
    metadata.frameCount++;
    socket.serializeAttachment(metadata);
    if (metadata.frameCount > MAX_FRAMES_PER_WINDOW) {
      this.send(socket, { type: "error", message: "Signaling message rate limited" });
      socket.close(4008, "Message rate limited"); return;
    }
    const message = parseClientMessage(raw);
    if (message === null) { this.send(socket, { type: "error", message: "Invalid signaling message" }); return; }
    switch (message.type) {
      case "approve": {
        if (metadata.role !== "receiver" || state.kind !== "pending") {
          this.send(socket, { type: "error", message: "Only the receiver may approve a pending sender" }); return;
        }
        const sender = this.socketFor(state, "sender");
        if (sender === null) { this.send(socket, { type: "error", message: "No sender awaiting approval" }); return; }
        if (!message.accepted) {
          this.send(sender, { type: "rejected" }); this.end("rejected"); return;
        }
        const resumeToken = makeToken();
        const senderHash = await hash(resumeToken);
        // Hashing yields, so re-check expiry and both socket generations before granting the capability.
        const current = this.active();
        if (current === null || current.kind !== "pending"
          || current.receiverConnection !== metadata.connectionId
          || current.senderConnection !== state.senderConnection
          || this.socketFor(current, "sender") !== sender) return;
        this.ctx.storage.sql.exec("UPDATE session SET status = 'approved', sender_hash = ?, join_hash = '' WHERE id = 1", senderHash);
        await this.ctx.storage.setAlarm(current.expiresAt);
        const approved = this.active();
        if (approved?.kind !== "approved") return;
        this.send(sender, { type: "approved", resumeToken });
        this.send(socket, { type: "approved" });
        this.announcePeers(approved);
        return;
      }
      case "signal": {
        if (state.kind !== "approved") {
          this.send(socket, { type: "error", message: "Peer approval required before signaling" }); return;
        }
        const other = this.socketFor(state, metadata.role === "receiver" ? "sender" : "receiver");
        if (other === null) { this.send(socket, { type: "error", message: "Peer is disconnected" }); return; }
        this.send(other, message);
        return;
      }
      case "stop":
        if (metadata.role === "sender" && state.kind === "pending") {
          this.send(socket, { type: "error", message: "Peer approval required before stopping the session" }); return;
        }
        this.end("stopped"); return;
      default: {
        const exhaustive: never = message;
        return exhaustive;
      }
    }
  }

  webSocketClose(socket: WebSocket, code: number, reason: string): void {
    this.disconnected(socket);
    socket.close(code, reason);
  }

  webSocketError(socket: WebSocket): void {
    this.disconnected(socket);
    socket.close(1011, "Socket error");
  }

  private disconnected(socket: WebSocket): void {
    const metadata = attachment(socket);
    const state = this.active();
    if (metadata === null || state === null || currentConnection(state, metadata.role) !== metadata.connectionId) return;
    this.saveQuota(metadata.role, "frame", metadata.frameWindowStart, metadata.frameCount);
    this.setConnection(metadata.role, null);
    const other = this.socketFor(state, metadata.role === "receiver" ? "sender" : "receiver");
    if (other !== null) this.send(other, { type: "peer-left", role: metadata.role });
  }

  private end(reason: string): void {
    const state = this.session();
    if (state === null || state.kind === "ended") return;
    this.ctx.storage.sql.exec(`UPDATE session SET status = 'ended', receiver_hash = '', join_hash = '',
      sender_hash = NULL, receiver_connection = NULL, sender_connection = NULL WHERE id = 1`);
    for (const socket of this.ctx.getWebSockets()) {
      this.send(socket, { type: "ended", reason });
      socket.close(4000, reason);
    }
    this.ctx.waitUntil(this.ctx.storage.setAlarm(state.expiresAt + 24 * 60 * 60 * 1000));
  }

  async alarm(): Promise<void> {
    const state = this.session();
    if (state === null) return;
    if (state.kind === "ended") {
      if (Date.now() >= state.expiresAt + 24 * 60 * 60 * 1000) {
        this.ctx.storage.sql.exec("DELETE FROM session WHERE id = 1");
        this.ctx.storage.sql.exec("DELETE FROM role_quota");
      }
      return;
    }
    if (this.active() === null) return;
    await this.ctx.storage.setAlarm(state.kind === "pending" ? state.joinExpiresAt : state.expiresAt);
  }
}
