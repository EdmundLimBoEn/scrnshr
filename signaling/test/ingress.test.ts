import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import { fixture } from "./harness";

for (const operation of ["ice", "ws"] as const) {
  test(`${operation} ingress shares a 60-request IP budget before session lookup`, async t => {
    const server = await fixture(t);
    const headers = {
      Authorization: `Bearer ${"X".repeat(43)}`,
      "CF-Connecting-IP": "198.51.100.10",
      Upgrade: "websocket",
    };
    const started = Date.now();
    for (let i = 0; i < 60; i++) {
      // Changing the session and capability must not bypass the IP budget.
      const response = await server.runtime.dispatchFetch(`https://signaling.test/v1/sessions/${randomUUID()}/${operation}`, {
        headers: { ...headers, Authorization: `Bearer ${i.toString().padStart(43, "X")}` },
      });
      assert.equal(response.status, 410);
    }
    for (const blockedOperation of ["ice", "ws"]) {
      const response = await server.runtime.dispatchFetch(`https://signaling.test/v1/sessions/${randomUUID()}/${blockedOperation}`, {
        headers: { ...headers, "X-Test-Forbid-Session-Lookup": "true" },
      });
      assert.equal(response.status, 429);
      assert.deepEqual(await response.json(), { error: "Session requests rate limited. Retry in one minute." });
      assert.equal(response.headers.get("Cache-Control"), "no-store");
    }
    assert.ok(Date.now() - started < 60_000, "Requests must fit within one minute");

    const session = await server.create();
    const receiver = await server.connect(session, session.receiverToken, "198.51.100.11");
    assert.deepEqual(await receiver.receive("waiting"), { type: "waiting" });
    const sender = await server.connect(session, session.joinToken, "198.51.100.12");
    await receiver.receive("approval-required");
    receiver.send({ type: "approve", accepted: true });
    assert.equal(typeof (await sender.receive("approved")).resumeToken, "string");
    const ice = await server.runtime.dispatchFetch(`https://signaling.test/v1/sessions/${session.sessionId}/ice`, {
      headers: { Authorization: `Bearer ${session.receiverToken}`, "CF-Connecting-IP": "198.51.100.11" },
    });
    assert.equal(ice.status, 200);
  });
}
