import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { runInNewContext } from "node:vm";
import { build } from "esbuild";
import { FRAME_WINDOW_MS } from "../src/protocol";
import { hash } from "../src/security";
import type { SessionRoom } from "../src/session";

// Run the production room against real SQLite, with socket states and close callbacks
// controlled independently so the peer can withhold its close handshake.
const bundle = await build({
  entryPoints: [new URL("../src/session.ts", import.meta.url).pathname],
  bundle: true, write: false, platform: "node", format: "cjs", external: ["cloudflare:workers"],
});

class Socket {
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  readyState = Socket.OPEN;
  messages: string[] = [];
  metadata: unknown;
  serializeAttachment(value: unknown) { this.metadata = structuredClone(value); }
  deserializeAttachment() { return structuredClone(this.metadata); }
  send(message: string) { this.messages.push(message); }
  close() { this.readyState = Socket.CLOSING; }
}

for (const role of ["sender", "receiver"] as const) {
  for (const closingState of [Socket.CLOSING, Socket.CLOSED]) {
    test(`${role} quota survives two reconnects with withheld close callbacks (state ${closingState})`, async t => {
      const db = new DatabaseSync(":memory:");
      t.after(() => db.close());
      let now = Date.now();
      const sockets: { socket: Socket; tag: string }[] = [];
      const ctx = {
        storage: {
          sql: { exec(query: string, ...args: (string | number | null)[]) {
            const rows = db.prepare(query).all(...args);
            return { toArray: () => rows };
          } },
          async setAlarm() {},
        },
        acceptWebSocket(socket: Socket, tags: string[]) { sockets.push({ socket, tag: tags[0]! }); },
        getWebSockets(tag?: string) { return sockets.filter(s => tag === undefined || s.tag === tag).map(s => s.socket); },
      };
      const module = { exports: {} as { SessionRoom: typeof SessionRoom } };
      runInNewContext(bundle.outputFiles[0]!.text, {
        module, exports: module.exports,
        require: () => ({ DurableObject: class { constructor(readonly ctx: unknown) {} } }),
        Date: class extends Date { static override now() { return now; } },
        crypto, TextEncoder, btoa,
        WebSocket: Socket,
        WebSocketPair: class { 0 = new Socket(); 1 = new Socket(); },
        Response: class { constructor(_body: unknown, readonly init: unknown) {} },
      });
      const room = new module.exports.SessionRoom(ctx as unknown as DurableObjectState, {});
      const receiverToken = "T".repeat(43);
      const senderToken = "S".repeat(43);
      await room.initialize({ sessionId: "quota-test", receiverHash: await hash(receiverToken), joinHash: "unused" });
      db.prepare("UPDATE session SET status = 'approved', sender_hash = ?").run(await hash(senderToken));
      const connect = async (peerRole: "sender" | "receiver") => {
        await room.fetch(new Request("https://test/ws", {
          headers: { Upgrade: "websocket", Authorization: `Bearer ${peerRole === "sender" ? senderToken : receiverToken}` },
        }));
        return sockets[sockets.length - 1]!.socket;
      };
      const other = await connect(role === "sender" ? "receiver" : "sender");
      let peer = await connect(role);
      const signal = JSON.stringify({ type: "signal", payload: "opaque", mac: "M".repeat(43) });
      const send = (socket: Socket) => room.webSocketMessage(socket as unknown as WebSocket, signal);
      const close = (socket: Socket) => room.webSocketClose(socket as unknown as WebSocket, 1000, "delayed close");
      const quota = () => db.prepare("SELECT count FROM role_quota WHERE role = ? AND kind = 'frame'").get(role)?.count ?? 0;
      for (let i = 0; i < 120; i++) await send(peer);
      assert.equal(quota(), 0, "frames must not write SQLite quotas");
      await send(peer); // Server initiates close; withhold its completion callback.
      peer.readyState = closingState;
      const old = peer;
      const inherited: unknown[] = [];
      for (let i = 0; i < 2; i++) {
        peer = await connect(role);
        inherited.push(quota());
        await send(peer);
        peer.readyState = closingState;
      }
      const forwarded = () => other.messages.filter(raw => JSON.parse(raw).type === "signal").length;
      assert.equal(forwarded(), 120);
      assert.deepEqual(inherited, [121, 122]);
      close(peer);
      assert.equal(quota(), 123);
      close(old);
      assert.equal(quota(), 123, "late close must not lower cumulative counts");
      now += FRAME_WINDOW_MS;
      peer = await connect(role);
      await send(peer);
      close(old);
      assert.equal(forwarded(), 121, "a new window allows signaling again");
      assert.equal(quota(), 0, "expired close must not overwrite the new window");
    });
  }
}
