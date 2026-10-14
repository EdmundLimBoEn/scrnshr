import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { Miniflare, Response as RuntimeResponse, type Request as RuntimeRequest, type WebSocket } from "miniflare";
import { isRecord, type CreatedSession, type ServerMessage } from "../src/protocol";

export const OWNER_TOKEN = "test-owner-secret-that-is-longer-than-32-characters";
export const SIGNAL = { type: "signal", payload: "opaque signed SDP or ICE", mac: "M".repeat(43) };

type Message = Record<string, unknown>;
type Waiter = {
  type: ServerMessage["type"];
  resolve: (message: Message) => void;
};

export class Peer {
  readonly messages: Message[] = [];
  readonly closed: Promise<{ code: number; reason: string }>;
  private readonly queue: Message[] = [];
  private waiter: Waiter | null = null;

  constructor(readonly socket: WebSocket) {
    socket.addEventListener("message", event => {
      assert.equal(typeof event.data, "string");
      const parsed: unknown = JSON.parse(String(event.data));
      assert.ok(isRecord(parsed));
      this.messages.push(parsed);
      if (this.waiter !== null && parsed.type === this.waiter.type) {
        const waiter = this.waiter;
        this.waiter = null;
        waiter.resolve(parsed);
      } else {
        this.queue.push(parsed);
      }
    });
    this.closed = new Promise(resolve => {
      socket.addEventListener("close", event => {
        resolve({ code: event.code, reason: event.reason });
      });
    });
    socket.accept();
  }

  send(value: unknown): void { this.socket.send(JSON.stringify(value)); }

  async receive(type: ServerMessage["type"]): Promise<Message> {
    assert.equal(this.waiter, null, "Only one pending receive per peer is supported");
    const index = this.queue.findIndex(message => message.type === type);
    if (index >= 0) {
      const message = this.queue.splice(index, 1)[0];
      assert.ok(message);
      return message;
    }
    return deadline(new Promise<Message>(resolve => { this.waiter = { type, resolve }; }), `WebSocket ${type}`);
  }

  async expectClose(code: number): Promise<void> {
    try {
      assert.equal((await deadline(this.closed, "WebSocket close")).code, code);
    } catch (error) {
      throw new Error(`Expected close ${code}; readyState ${this.socket.readyState}; messages ${JSON.stringify(this.messages)}`, { cause: error });
    }
  }

  close(): void {
    if (this.socket.readyState === 1) this.socket.close(1000, "Test complete");
  }
}

async function deadline<T>(operation: Promise<T>, description: string): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      operation,
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error(`Timed out waiting for ${description}`)), 5_000);
      }),
    ]);
  } finally { if (timeout !== undefined) clearTimeout(timeout); }
}

let bundledWorker: Promise<string> | undefined;
function workerSource(): Promise<string> {
  bundledWorker ??= build({
    entryPoints: [fileURLToPath(new URL("./worker.ts", import.meta.url))],
    bundle: true, format: "esm", target: "es2022", external: ["cloudflare:workers"], write: false,
  }).then(result => {
    const file = result.outputFiles[0];
    assert.ok(file);
    return file.text;
  });
  return bundledWorker;
}

type FixtureOptions = {
  bindings?: Record<string, string>;
  outbound?: (request: RuntimeRequest) => Promise<RuntimeResponse>;
  persistent?: boolean;
};

export async function fixture(t: TestContext, options: FixtureOptions = {}) {
  const storage = options.persistent ? await mkdtemp(join(tmpdir(), "scrnshr-signaling-test-")) : false;
  const script = await workerSource();
  const peers = new Set<Peer>();
  const makeRuntime = () => new Miniflare({
    name: "signaling-test", modules: true, script,
    compatibilityDate: "2026-07-30",
    unsafeInspectDurableObjects: true,
    durableObjects: {
      SESSIONS: { className: "SessionRoom", useSQLite: true },
      TEST_SESSIONS: { className: "SessionRoom", useSQLite: true },
      RATE_LIMITS: { className: "RequestLimiter", useSQLite: true },
    },
    durableObjectsPersist: storage,
    bindings: { OWNER_TOKEN, ALLOW_STUN_ONLY: "true", ...options.bindings },
    outboundService: options.outbound ?? (async () => { throw new Error("Unexpected outbound network request in test"); }),
  });
  let runtime = makeRuntime();
  await runtime.ready;
  t.after(async () => {
    for (const peer of peers) peer.close();
    await runtime.dispose();
    if (storage !== false) await rm(storage, { recursive: true, force: true });
  });

  return {
    get runtime() { return runtime; },
    async restart() {
      assert.notEqual(storage, false, "Restart requires persistent test storage");
      for (const peer of peers) peer.close();
      await runtime.dispose();
      runtime = makeRuntime();
      await runtime.ready;
    },
    async create(ip = "192.0.2.1"): Promise<CreatedSession> {
      const response = await runtime.dispatchFetch("https://signaling.test/v1/sessions", {
        method: "POST", headers: { Authorization: `Bearer ${OWNER_TOKEN}`, "CF-Connecting-IP": ip },
      });
      assert.equal(response.status, 201);
      const value: unknown = await response.json();
      assert.ok(isRecord(value));
      assert.equal(typeof value.sessionId, "string");
      assert.equal(typeof value.receiverToken, "string");
      assert.equal(typeof value.joinToken, "string");
      assert.equal(typeof value.expiresAt, "string");
      assert.ok(typeof value.sessionId === "string" && typeof value.receiverToken === "string"
        && typeof value.joinToken === "string" && typeof value.expiresAt === "string");
      return { sessionId: value.sessionId, receiverToken: value.receiverToken, joinToken: value.joinToken, expiresAt: value.expiresAt };
    },
    async connect(session: CreatedSession, token: string): Promise<Peer> {
      const response = await runtime.dispatchFetch(`https://signaling.test/v1/sessions/${session.sessionId}/ws`, {
        headers: { Authorization: `Bearer ${token}`, Upgrade: "websocket" },
      });
      assert.equal(response.status, 101);
      assert.ok(response.webSocket);
      const peer = new Peer(response.webSocket);
      peers.add(peer);
      return peer;
    },
    async ice(session: CreatedSession, token: string) {
      return runtime.dispatchFetch(`https://signaling.test/v1/sessions/${session.sessionId}/ice`, {
        headers: { Authorization: `Bearer ${token}` },
      });
    },
    async storage(session: CreatedSession) {
      return runtime.unsafeGetDurableObjectStorage("signaling-test", "SessionRoom", { name: session.sessionId });
    },
    async runAlarm(session: CreatedSession) {
      const response = await runtime.dispatchFetch(`https://signaling.test/__test/sessions/${session.sessionId}/alarm`, { method: "POST" });
      assert.equal(response.status, 200);
      return response.json();
    },
  };
}

export async function approvedSession(t: TestContext, options: FixtureOptions = {}) {
  const server = await fixture(t, options);
  const session = await server.create();
  const receiver = await server.connect(session, session.receiverToken);
  assert.deepEqual(await receiver.receive("waiting"), { type: "waiting" });
  const sender = await server.connect(session, session.joinToken);
  assert.deepEqual(await sender.receive("waiting"), { type: "waiting" });
  assert.deepEqual(await receiver.receive("approval-required"), { type: "approval-required" });
  receiver.send({ type: "approve", accepted: true });
  const approval = await sender.receive("approved");
  assert.ok(typeof approval.resumeToken === "string");
  assert.match(approval.resumeToken, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(approval.resumeToken, session.joinToken);
  assert.deepEqual(await receiver.receive("approved"), { type: "approved" });
  assert.deepEqual(await receiver.receive("peer"), { type: "peer", role: "sender" });
  assert.deepEqual(await sender.receive("peer"), { type: "peer", role: "receiver" });
  return { server, session, receiver, sender, resumeToken: approval.resumeToken };
}

export { RuntimeResponse };
