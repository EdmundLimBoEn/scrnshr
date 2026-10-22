import assert from "node:assert/strict";
import { test } from "node:test";
import { hash } from "../src/security";
import { approvedSession, fixture, OWNER_TOKEN, RuntimeResponse, SIGNAL } from "./harness";

test("session creation authenticates the owner and returns expiring, distinct peer capabilities", async t => {
  const server = await fixture(t);
  for (const token of [undefined, "wrong-owner", "owner with whitespace"]) {
    const response = await server.runtime.dispatchFetch("https://signaling.test/v1/sessions", {
      method: "POST", headers: token === undefined ? {} : { Authorization: `Bearer ${token}` },
    });
    assert.equal(response.status, 401);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
  }
  const session = await server.create();
  assert.match(session.sessionId, /^[0-9a-f-]{36}$/);
  assert.match(session.receiverToken, /^[A-Za-z0-9_-]{43}$/);
  assert.match(session.joinToken, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(session.receiverToken, session.joinToken);
  const remaining = Date.parse(session.expiresAt) - Date.now();
  assert.ok(remaining > 7_190_000 && remaining <= 7_200_000);
});

test("unset owner authorization fails closed", async t => {
  const server = await fixture(t, { bindings: { OWNER_TOKEN: "too-short" } });
  const response = await server.runtime.dispatchFetch("https://signaling.test/v1/sessions", {
    method: "POST", headers: { Authorization: "Bearer too-short" },
  });
  assert.equal(response.status, 503);
});

test("routing rejects query credentials, missing peer authorization, invalid sessions and non-upgrades", async t => {
  const server = await fixture(t);
  const session = await server.create();
  const path = `https://signaling.test/v1/sessions/${session.sessionId}`;
  const cases = [
    { url: `${path}/ws?token=${session.receiverToken}`, status: 400, headers: {} },
    { url: `${path}/ice`, status: 401, headers: {} },
    { url: `${path}/ws`, status: 426, headers: { Authorization: `Bearer ${session.receiverToken}` } },
    { url: "https://signaling.test/v1/sessions/not-a-uuid/ws", status: 400, headers: {} },
    { url: "https://signaling.test/unknown", status: 404, headers: {} },
  ];
  for (const item of cases) {
    assert.equal((await server.runtime.dispatchFetch(item.url, { headers: item.headers })).status, item.status);
  }
  const badPeer = await server.runtime.dispatchFetch(`${path}/ws`, {
    headers: { Authorization: `Bearer ${"X".repeat(43)}`, Upgrade: "websocket" },
  });
  assert.equal(badPeer.status, 401);
  const missing = await server.runtime.dispatchFetch("https://signaling.test/v1/sessions/00000000-0000-4000-8000-000000000000/ws", {
    headers: { Authorization: `Bearer ${session.receiverToken}`, Upgrade: "websocket" },
  });
  assert.equal(missing.status, 410);
});

test("pending sender cannot relay signaling, approve itself, stop the session or fetch ICE", async t => {
  const server = await fixture(t);
  const session = await server.create();
  const receiver = await server.connect(session, session.receiverToken);
  const sender = await server.connect(session, session.joinToken);
  await sender.receive("waiting");
  await receiver.receive("approval-required");
  sender.send(SIGNAL);
  assert.match(String((await sender.receive("error")).message), /approval required/i);
  sender.send({ type: "approve", accepted: true });
  assert.match(String((await sender.receive("error")).message), /only the receiver/i);
  sender.send({ type: "stop" });
  assert.match(String((await sender.receive("error")).message), /approval required/i);
  assert.equal((await server.ice(session, session.joinToken)).status, 401);
  assert.equal(receiver.messages.some(message => message.type === "signal"), false);
  assert.equal((await server.ice(session, session.receiverToken)).status, 200);
});

test("only one sender can await approval and receiver cannot approve an absent sender", async t => {
  const server = await fixture(t);
  const session = await server.create();
  const receiver = await server.connect(session, session.receiverToken);
  receiver.send({ type: "approve", accepted: true });
  assert.match(String((await receiver.receive("error")).message), /no sender/i);
  const sender = await server.connect(session, session.joinToken);
  await sender.receive("waiting");
  const duplicate = await server.runtime.dispatchFetch(`https://signaling.test/v1/sessions/${session.sessionId}/ws`, {
    headers: { Authorization: `Bearer ${session.joinToken}`, Upgrade: "websocket" },
  });
  assert.equal(duplicate.status, 409);
  receiver.send({ type: "approve", accepted: true });
  assert.ok(typeof (await sender.receive("approved")).resumeToken === "string");
});

test("approval grants a separate resume token and relays opaque signed payloads both ways", async t => {
  const { server, session, receiver, sender, resumeToken } = await approvedSession(t);
  sender.send(SIGNAL);
  assert.deepEqual(await receiver.receive("signal"), SIGNAL);
  const answer = { ...SIGNAL, payload: "opaque answer with unicode: 📱", mac: "A".repeat(43) };
  receiver.send(answer);
  assert.deepEqual(await sender.receive("signal"), answer);
  assert.equal((await server.ice(session, resumeToken)).status, 200);
  assert.equal((await server.ice(session, session.joinToken)).status, 401);
  const oldJoin = await server.runtime.dispatchFetch(`https://signaling.test/v1/sessions/${session.sessionId}/ws`, {
    headers: { Authorization: `Bearer ${session.joinToken}`, Upgrade: "websocket" },
  });
  assert.equal(oldJoin.status, 401);
  sender.send({ type: "approve", accepted: true });
  assert.match(String((await sender.receive("error")).message), /only the receiver/i);
  receiver.send({ type: "approve", accepted: true });
  assert.match(String((await receiver.receive("error")).message), /pending sender/i);
});

test("receiver rejection invalidates every peer capability", async t => {
  const server = await fixture(t);
  const session = await server.create();
  const receiver = await server.connect(session, session.receiverToken);
  const sender = await server.connect(session, session.joinToken);
  await receiver.receive("approval-required");
  receiver.send({ type: "approve", accepted: false });
  assert.deepEqual(await sender.receive("rejected"), { type: "rejected" });
  assert.deepEqual(await receiver.receive("ended"), { type: "ended", reason: "rejected" });
  await receiver.expectClose(4000);
  sender.close();
  assert.equal((await server.ice(session, session.receiverToken)).status, 410);
  assert.equal((await server.ice(session, session.joinToken)).status, 410);
});

test("approved sender reconnect replaces its old socket without revoking the current connection", async t => {
  const { server, session, receiver, sender, resumeToken } = await approvedSession(t);
  const replacement = await server.connect(session, resumeToken);
  assert.deepEqual(await replacement.receive("approved"), { type: "approved" });
  assert.match(String((await sender.receive("error")).message), /connection replaced/i);
  sender.close();
  await replacement.receive("peer");
  replacement.send(SIGNAL);
  assert.deepEqual(await receiver.receive("signal"), SIGNAL);
  receiver.send({ ...SIGNAL, payload: "answer after old close event" });
  assert.equal((await replacement.receive("signal")).payload, "answer after old close event");
  assert.equal(receiver.messages.some(message => message.type === "peer-left"), false);
  const again = await server.connect(session, resumeToken);
  assert.deepEqual(await again.receive("approved"), { type: "approved" });
  await replacement.expectClose(4001);
  again.send({ ...SIGNAL, payload: "stable resume capability" });
  assert.equal((await receiver.receive("signal")).payload, "stable resume capability");
});

test("receiver reconnect restores approved state and an old close cannot clear it", async t => {
  const { server, session, receiver, sender } = await approvedSession(t);
  const replacement = await server.connect(session, session.receiverToken);
  await receiver.expectClose(4001);
  assert.deepEqual(await replacement.receive("approved"), { type: "approved" });
  await replacement.receive("peer");
  sender.send(SIGNAL);
  assert.deepEqual(await replacement.receive("signal"), SIGNAL);
  assert.equal(sender.messages.some(message => message.type === "peer-left"), false);
});

test("peer disconnect is reported and the approved sender can resume later", async t => {
  const { server, session, receiver, sender, resumeToken } = await approvedSession(t);
  sender.close();
  assert.deepEqual(await receiver.receive("peer-left"), { type: "peer-left", role: "sender" });
  receiver.send(SIGNAL);
  assert.match(String((await receiver.receive("error")).message), /disconnected/i);
  const replacement = await server.connect(session, resumeToken);
  await replacement.receive("approved");
  receiver.send(SIGNAL);
  assert.deepEqual(await replacement.receive("signal"), SIGNAL);
});

for (const stoppingRole of ["receiver", "sender"] as const) {
  test(`${stoppingRole} stops an approved session, notifies both peers and revokes all capabilities`, async t => {
    const { server, session, receiver, sender, resumeToken } = await approvedSession(t);
    (stoppingRole === "receiver" ? receiver : sender).send({ type: "stop" });
    assert.deepEqual(await receiver.receive("ended"), { type: "ended", reason: "stopped" });
    assert.deepEqual(await sender.receive("ended"), { type: "ended", reason: "stopped" });
    await receiver.expectClose(4000);
    if (stoppingRole === "sender") await sender.expectClose(4000);
    else sender.close();
    for (const token of [session.receiverToken, session.joinToken, resumeToken]) {
      assert.equal((await server.ice(session, token)).status, 410);
    }
    const rows = await (await server.storage(session)).exec("SELECT status,receiver_hash,join_hash,sender_hash FROM session");
    assert.deepEqual(rows, [{ status: "ended", receiver_hash: "", join_hash: "", sender_hash: null }]);
  });
}

test("hibernation restores authenticated socket attachments and approved peer capabilities", async t => {
  const { server, session, receiver, sender, resumeToken } = await approvedSession(t);
  await server.runtime.unsafeEvictDurableObject("signaling-test", "SessionRoom", { name: session.sessionId, webSockets: "hibernate" });
  sender.send({ ...SIGNAL, payload: "message after hibernation" });
  assert.equal((await receiver.receive("signal")).payload, "message after hibernation");
  receiver.send(SIGNAL);
  assert.deepEqual(await sender.receive("signal"), SIGNAL);
  assert.equal((await server.ice(session, resumeToken)).status, 200);
  assert.equal((await server.ice(session, session.joinToken)).status, 401);
});

test("SQLite state and approved resume tokens survive a full worker restart", async t => {
  const { server, session, resumeToken } = await approvedSession(t, { persistent: true });
  await server.restart();
  const receiver = await server.connect(session, session.receiverToken);
  assert.deepEqual(await receiver.receive("approved"), { type: "approved" });
  const sender = await server.connect(session, resumeToken);
  assert.deepEqual(await sender.receive("approved"), { type: "approved" });
  sender.send(SIGNAL);
  assert.deepEqual(await receiver.receive("signal"), SIGNAL);
  assert.equal((await server.ice(session, session.joinToken)).status, 401);
});

test("pending pairing expiry ends both peers and denies approval after timeout", async t => {
  const server = await fixture(t);
  const session = await server.create();
  const receiver = await server.connect(session, session.receiverToken);
  const sender = await server.connect(session, session.joinToken);
  await receiver.receive("approval-required");
  await (await server.storage(session)).exec("UPDATE session SET join_expires_at = ? WHERE id = 1", Date.now() - 1_000);
  receiver.send({ type: "approve", accepted: true });
  assert.deepEqual(await receiver.receive("ended"), { type: "ended", reason: "pairing-expired" });
  assert.deepEqual(await sender.receive("ended"), { type: "ended", reason: "pairing-expired" });
  sender.close();
  assert.equal(sender.messages.some(message => message.type === "approved"), false);
  assert.equal((await server.ice(session, session.receiverToken)).status, 410);
});

test("approved session expiry revokes resume capabilities and stops relay", async t => {
  const { server, session, receiver, sender, resumeToken } = await approvedSession(t);
  await (await server.storage(session)).exec("UPDATE session SET expires_at = ? WHERE id = 1", Date.now() - 1_000);
  sender.send(SIGNAL);
  assert.deepEqual(await receiver.receive("ended"), { type: "ended", reason: "session-expired" });
  assert.equal(receiver.messages.some(message => message.type === "signal"), false);
  assert.equal((await server.ice(session, resumeToken)).status, 410);
});

test("pending pairing alarm expires the room and schedules tombstone cleanup", async t => {
  const server = await fixture(t);
  const session = await server.create();
  const receiver = await server.connect(session, session.receiverToken);
  const sender = await server.connect(session, session.joinToken);
  await receiver.receive("approval-required");
  const storage = await server.storage(session);
  await storage.exec("UPDATE session SET join_expires_at = ? WHERE id = 1", Date.now() - 1_000);
  assert.deepEqual(await server.runAlarm(session), {
    status: "ended", alarm: Date.parse(session.expiresAt) + 24 * 60 * 60 * 1_000,
  });
  assert.deepEqual(await receiver.receive("ended"), { type: "ended", reason: "pairing-expired" });
  assert.deepEqual(await sender.receive("ended"), { type: "ended", reason: "pairing-expired" });
  receiver.close();
  sender.close();
  assert.equal((await server.ice(session, session.receiverToken)).status, 410);
});

test("approved room alarm ignores obsolete join expiry and uses the full session deadline", async t => {
  const { server, session, receiver, sender } = await approvedSession(t);
  const storage = await server.storage(session);
  await storage.exec("UPDATE session SET join_expires_at = ? WHERE id = 1", Date.now() - 1_000);
  assert.deepEqual(await server.runAlarm(session), { status: "approved", alarm: Date.parse(session.expiresAt) });
  sender.send(SIGNAL);
  assert.deepEqual(await receiver.receive("signal"), SIGNAL);
  const expiredAt = Date.now() - 1_000;
  await storage.exec("UPDATE session SET expires_at = ? WHERE id = 1", expiredAt);
  assert.deepEqual(await server.runAlarm(session), { status: "ended", alarm: expiredAt + 24 * 60 * 60 * 1_000 });
  assert.deepEqual(await receiver.receive("ended"), { type: "ended", reason: "session-expired" });
});

test("ended tombstones remain until cleanup deadline and the alarm then removes their persisted state", async t => {
  const { server, session, receiver } = await approvedSession(t);
  receiver.send({ type: "stop" });
  await receiver.receive("ended");
  assert.deepEqual(await server.runAlarm(session), {
    status: "ended", alarm: Date.parse(session.expiresAt) + 24 * 60 * 60 * 1_000,
  });
  await (await server.storage(session)).exec("UPDATE session SET expires_at = ? WHERE id = 1", Date.now() - 24 * 60 * 60 * 1_000 - 1_000);
  const afterCleanup = await server.runAlarm(session);
  assert.ok(typeof afterCleanup === "object" && afterCleanup !== null && "status" in afterCleanup);
  assert.equal(afterCleanup.status, null);
  assert.deepEqual(await (await server.storage(session)).exec("SELECT * FROM session"), []);
  assert.equal((await server.ice(session, session.receiverToken)).status, 410);
});

test("malformed text messages return errors without reaching the other peer", async t => {
  const { receiver, sender } = await approvedSession(t);
  for (const raw of ["invalid JSON", "[]", "null", '{"type":"unknown"}', '{"type":"signal","payload":"opaque","mac":"wrong"}']) {
    sender.socket.send(raw);
    assert.match(String((await sender.receive("error")).message), /invalid signaling/i);
  }
  sender.send(SIGNAL);
  assert.deepEqual(await receiver.receive("signal"), SIGNAL);
  assert.equal(receiver.messages.filter(message => message.type === "signal").length, 1);
});

test("binary signaling is rejected with a protocol close", async t => {
  const { receiver, sender } = await approvedSession(t);
  sender.socket.send(new Uint8Array([1, 2, 3]));
  await sender.expectClose(1003);
  assert.deepEqual(await receiver.receive("peer-left"), { type: "peer-left", role: "sender" });
});

test("UTF-8 frame size is bounded rather than only the JavaScript character count", async t => {
  const { receiver, sender } = await approvedSession(t);
  sender.send({ ...SIGNAL, payload: "📱".repeat(16_400) });
  assert.match(String((await sender.receive("error")).message), /64 KiB/i);
  await sender.expectClose(1009);
  assert.equal(receiver.messages.some(message => message.type === "signal"), false);
});

test("message rate limits persist across hibernation", async t => {
  const { server, session, receiver, sender } = await approvedSession(t);
  for (let i = 0; i < 60; i++) {
    sender.send({ ...SIGNAL, payload: `first:${i}` });
    await receiver.receive("signal");
  }
  await server.runtime.unsafeEvictDurableObject("signaling-test", "SessionRoom", { name: session.sessionId, webSockets: "hibernate" });
  for (let i = 0; i < 60; i++) {
    sender.send({ ...SIGNAL, payload: `second:${i}` });
    await receiver.receive("signal");
  }
  sender.send(SIGNAL);
  assert.match(String((await sender.receive("error")).message), /rate limited/i);
  await sender.expectClose(4008);
});

test("ICE credentials are peer-scoped and rate limits survive hibernation", async t => {
  const { server, session, resumeToken } = await approvedSession(t);
  for (let i = 0; i < 12; i++) assert.equal((await server.ice(session, resumeToken)).status, 200);
  await server.runtime.unsafeEvictDurableObject("signaling-test", "SessionRoom", { name: session.sessionId, webSockets: "hibernate" });
  assert.equal((await server.ice(session, resumeToken)).status, 429);
  const receiverResponse = await server.ice(session, session.receiverToken);
  assert.equal(receiverResponse.status, 200);
  assert.deepEqual(await receiverResponse.json(), {
    iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }], connectivity: "local-only",
  });
  await (await server.storage(session)).exec("UPDATE session SET sender_ice_start = ? WHERE id = 1", Date.now() - 61_000);
  assert.equal((await server.ice(session, resumeToken)).status, 200);
});

test("TURN misconfiguration reports unavailable instead of silently allowing local-only sessions", async t => {
  const server = await fixture(t, { bindings: { ALLOW_STUN_ONLY: "false" } });
  const session = await server.create();
  const response = await server.ice(session, session.receiverToken);
  assert.equal(response.status, 503);
  assert.match(JSON.stringify(await response.json()), /TURN is not configured/);
});

test("TURN credentials are generated server-side using the backend secret and a bounded TTL", async t => {
  const calls: { url: string; authorization: string | null; body: unknown }[] = [];
  const server = await fixture(t, {
    bindings: { TURN_KEY_ID: "test-key", TURN_API_TOKEN: "backend-turn-secret" },
    outbound: async request => {
      calls.push({ url: request.url, authorization: request.headers.get("Authorization"), body: await request.json() });
      return RuntimeResponse.json({ iceServers: [
        { urls: ["stun:stun.cloudflare.com:3478"] },
        { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:5349?transport=tcp"], username: "expiring-user", credential: "expiring-password" },
      ] });
    },
  });
  const session = await server.create();
  const response = await server.ice(session, session.receiverToken);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const body = JSON.stringify(await response.json());
  assert.match(body, /internet/);
  assert.match(body, /expiring-password/);
  assert.equal(body.includes("backend-turn-secret"), false);
  assert.deepEqual(calls, [{
    url: "https://rtc.live.cloudflare.com/v1/turn/keys/test-key/credentials/generate-ice-servers",
    authorization: "Bearer backend-turn-secret", body: { ttl: 7_800 },
  }]);
});

test("TURN credential TTL follows the remaining session lifetime plus grace", async t => {
  const calls: unknown[] = [];
  const server = await fixture(t, {
    bindings: { TURN_KEY_ID: "test-key", TURN_API_TOKEN: "secret" },
    outbound: async request => {
      calls.push(await request.json());
      return RuntimeResponse.json({ iceServers: [{ urls: ["turn:example.test:3478"], username: "u", credential: "p" }] });
    },
  });
  const session = await server.create();
  const before = Date.now();
  await (await server.storage(session)).exec("UPDATE session SET expires_at = ? WHERE id = 1", Date.now() + 5 * 60_000);
  assert.equal((await server.ice(session, session.receiverToken)).status, 200);
  const elapsedSeconds = Math.ceil((Date.now() - before) / 1000);
  assert.equal(calls.length, 1);
  const { ttl } = calls[0] as { ttl: number };
  assert.ok(Number.isInteger(ttl));
  assert.ok(ttl >= 900 - elapsedSeconds && ttl <= 900, `Expected about 900 seconds, got ${ttl}`);
});

for (const badUpstream of [
  { name: "HTTP error", status: 403, value: { error: "bad upstream credentials" } },
  { name: "invalid JSON", status: 200, value: "not-json" },
  { name: "missing relay", status: 200, value: { iceServers: [{ urls: ["stun:example.test:3478"] }] } },
  { name: "missing TURN credentials", status: 200, value: { iceServers: [{ urls: ["turn:example.test:3478"] }] } },
]) {
  test(`TURN ${badUpstream.name} fails without returning a success payload`, async t => {
    const server = await fixture(t, {
      bindings: { TURN_KEY_ID: "test-key", TURN_API_TOKEN: "secret" },
      outbound: async () => new RuntimeResponse(typeof badUpstream.value === "string" ? badUpstream.value : JSON.stringify(badUpstream.value), { status: badUpstream.status }),
    });
    const session = await server.create();
    assert.equal((await server.ice(session, session.receiverToken)).status, 502);
  });
}

test("credentials are withheld if the session ends while TURN is issuing them", async t => {
  let notifyRequested: () => void = () => { throw new Error("TURN request not initialized"); };
  const requested = new Promise<void>(resolve => { notifyRequested = resolve; });
  let release: () => void = () => { throw new Error("TURN response not initialized"); };
  const held = new Promise<void>(resolve => { release = resolve; });
  const { server, session, receiver } = await approvedSession(t, {
    bindings: { TURN_KEY_ID: "test-key", TURN_API_TOKEN: "secret" },
    outbound: async () => {
      notifyRequested();
      await held;
      return RuntimeResponse.json({ iceServers: [{ urls: ["turn:example.test:3478"], username: "u", credential: "p" }] });
    },
  });
  const credentials = server.ice(session, session.receiverToken);
  await requested;
  receiver.send({ type: "stop" });
  await receiver.receive("ended");
  release();
  assert.equal((await credentials).status, 410);
});

test("session creation enforces per-IP limits with persisted buckets", async t => {
  const server = await fixture(t);
  for (let i = 0; i < 12; i++) await server.create("198.51.100.10");
  const blocked = await server.runtime.dispatchFetch("https://signaling.test/v1/sessions", {
    method: "POST", headers: { Authorization: `Bearer ${OWNER_TOKEN}`, "CF-Connecting-IP": "198.51.100.10" },
  });
  assert.equal(blocked.status, 429);
  const bucket = await server.runtime.unsafeGetDurableObjectStorage("signaling-test", "RequestLimiter", { name: await hash("ip:198.51.100.10") });
  assert.deepEqual((await bucket.exec("SELECT count FROM bucket")), [{ count: 12 }]);
  await server.runtime.unsafeEvictDurableObject("signaling-test", "RequestLimiter", { name: await hash("ip:198.51.100.10") });
  assert.equal((await server.runtime.dispatchFetch("https://signaling.test/v1/sessions", {
    method: "POST", headers: { Authorization: `Bearer ${OWNER_TOKEN}`, "CF-Connecting-IP": "198.51.100.10" },
  })).status, 429);
  await bucket.exec("UPDATE bucket SET starts_at = ?", Date.now() - 3_601_000);
  await server.create("198.51.100.10");
});

test("owner-wide session creation limit prevents bypass by changing IP address", async t => {
  const server = await fixture(t);
  for (let i = 0; i < 30; i++) await server.create(`203.0.113.${i + 1}`);
  const blocked = await server.runtime.dispatchFetch("https://signaling.test/v1/sessions", {
    method: "POST", headers: { Authorization: `Bearer ${OWNER_TOKEN}`, "CF-Connecting-IP": "203.0.113.250" },
  });
  assert.equal(blocked.status, 429);
});
