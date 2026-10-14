import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { isRecord, parseClientMessage, parseIceServers, TOKEN_PATTERN } from "../src/protocol";
import { bearer, equalHash, error, hash, json, makeToken, peerBearer } from "../src/security";

const validMac = "aB_0-".repeat(8) + "xyz";

function requestWithAuthorization(value: string): Request {
  return new Request("https://scrnshr.example/api/sessions", {
    headers: { Authorization: value },
  });
}

describe("client protocol parsing", () => {
  it("rejects malformed JSON and values that are not protocol objects", () => {
    for (const text of ["", "{", "null", "true", "42", '"stop"', "[]", '[{"type":"stop"}]']) {
      assert.equal(parseClientMessage(text), null, text);
    }
    for (const value of [null, undefined, true, 42, "stop", []]) {
      assert.equal(isRecord(value), false);
    }
    assert.equal(isRecord({ type: "stop" }), true);
  });

  it("accepts explicit approval and rejection and rejects coercible booleans", () => {
    assert.deepEqual(parseClientMessage('{"type":"approve","accepted":true}'), { type: "approve", accepted: true });
    assert.deepEqual(parseClientMessage('{"type":"approve","accepted":false}'), { type: "approve", accepted: false });
    for (const accepted of [undefined, null, 0, 1, "true", "false", {}, []]) {
      assert.equal(parseClientMessage(JSON.stringify({ type: "approve", accepted })), null);
    }
  });

  it("accepts stop and strips unrelated external fields", () => {
    assert.deepEqual(parseClientMessage('{"type":"stop","payload":"untrusted","accepted":true}'), { type: "stop" });
    assert.deepEqual(parseClientMessage('{"type":"approve","accepted":true,"role":"receiver"}'), { type: "approve", accepted: true });
    for (const value of [{}, { type: "approved" }, { type: "offer" }, { type: null }, { type: 1 }]) {
      assert.equal(parseClientMessage(JSON.stringify(value)), null);
    }
  });

  it("relays opaque authenticated signaling without interpreting the payload", () => {
    const payload = "opaque signed bytes: 💻\u0000{this is not JSON}";
    assert.deepEqual(parseClientMessage(JSON.stringify({ type: "signal", payload, mac: validMac, sessionId: "ignored" })), {
      type: "signal", payload, mac: validMac,
    });
  });

  it("requires a nonempty string payload and a 43-character base64url MAC", () => {
    for (const payload of [undefined, null, "", 0, true, {}, []]) {
      assert.equal(parseClientMessage(JSON.stringify({ type: "signal", payload, mac: validMac })), null);
    }
    for (const mac of [undefined, null, 43, validMac.slice(1), validMac + "a", "+" + validMac.slice(1), "/" + validMac.slice(1), validMac.slice(1) + "=", " " + validMac.slice(1)]) {
      assert.equal(parseClientMessage(JSON.stringify({ type: "signal", payload: "opaque", mac })), null);
    }
  });
});

describe("ICE server validation", () => {
  it("accepts STUN and credentialed TURN servers without exposing unrelated response fields", () => {
    assert.deepEqual(parseIceServers({
      iceServers: [
        { urls: ["stun:stun.cloudflare.com:3478", "stuns:stun.example:5349"] },
        { urls: ["turn:turn.example:3478?transport=udp", "turns:turn.example:443?transport=tcp"], username: "expiring-user", credential: "expiring-secret", credentialType: "password" },
      ],
      expiresAt: "ignored",
    }), [
      { urls: ["stun:stun.cloudflare.com:3478", "stuns:stun.example:5349"] },
      { urls: ["turn:turn.example:3478?transport=udp", "turns:turn.example:443?transport=tcp"], username: "expiring-user", credential: "expiring-secret" },
    ]);
  });

  it("rejects malformed envelopes and URL collections", () => {
    for (const value of [undefined, null, [], {}, { iceServers: null }, { iceServers: {} }, { iceServers: [] }, { iceServers: [null] }, { iceServers: [[]] }, { iceServers: [{}] }, { iceServers: [{ urls: "stun:example" }] }, { iceServers: [{ urls: [] }] }]) {
      assert.equal(parseIceServers(value), null);
    }
    for (const url of [null, 1, true, "", "stun:", "stun:host name", "stun:host\nname", "https://example", "file:///etc/passwd"]) {
      assert.equal(parseIceServers({ iceServers: [{ urls: [url] }] }), null);
    }
  });

  it("bounds server count, URL count, and URL length at the network boundary", () => {
    const url = "stun:" + "a".repeat(507);
    const maximum = { iceServers: Array.from({ length: 16 }, () => ({ urls: Array.from({ length: 16 }, () => url) })) };
    assert.equal(parseIceServers(maximum)?.length, 16);
    assert.equal(parseIceServers({ iceServers: Array.from({ length: 17 }, () => ({ urls: ["stun:example"] })) }), null);
    assert.equal(parseIceServers({ iceServers: [{ urls: Array.from({ length: 17 }, () => "stun:example") }] }), null);
    assert.equal(parseIceServers({ iceServers: [{ urls: [url + "a"] }] }), null);
  });

  it("requires both TURN credentials, including when STUN and TURN share an entry", () => {
    for (const credentials of [{}, { username: "user" }, { credential: "secret" }, { username: "", credential: "secret" }, { username: "user", credential: "" }]) {
      assert.equal(parseIceServers({ iceServers: [{ urls: ["stun:example", "turns:example:443"], ...credentials }] }), null);
    }
  });

  it("validates optional credentials and caps their lengths", () => {
    const maximumCredentials = { username: "u".repeat(1024), credential: "s".repeat(1024) };
    assert.deepEqual(parseIceServers({ iceServers: [{ urls: ["turn:example"], ...maximumCredentials }] }), [{ urls: ["turn:example"], ...maximumCredentials }]);
    for (const invalid of [null, 1, true, {}, [], "x".repeat(1025)]) {
      assert.equal(parseIceServers({ iceServers: [{ urls: ["stun:example"], username: invalid }] }), null);
      assert.equal(parseIceServers({ iceServers: [{ urls: ["stun:example"], credential: invalid }] }), null);
    }
    assert.equal(parseIceServers({ iceServers: [{ urls: ["stun:example"] }, { urls: ["https://example"] }] }), null);
  });
});

describe("authentication and response security", () => {
  it("generates distinct 256-bit URL-safe tokens", () => {
    const tokens = Array.from({ length: 512 }, makeToken);
    assert.equal(new Set(tokens).size, tokens.length);
    for (const token of tokens) {
      assert.equal(token.length, 43);
      assert.match(token, TOKEN_PATTERN);
      assert.equal(Buffer.from(token, "base64url").length, 32);
    }
  });

  it("hashes tokens with SHA-256 using stable UTF-8 encoding", async () => {
    assert.equal(await hash(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert.equal(await hash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    assert.equal(await hash("café"), "850f7dc43910ff890f8879c0ed26fe697c93a067ad93a7d50f466a7028a9bf4e");
    assert.notEqual(await hash("Cafe"), await hash("café"));
  });

  it("compares complete hashes and rejects prefixes or changed characters", async () => {
    const digest = await hash("token");
    assert.equal(equalHash(digest, digest), true);
    assert.equal(equalHash("", ""), true);
    assert.equal(equalHash(digest, digest.slice(1)), false);
    assert.equal(equalHash(digest.slice(1), digest), false);
    assert.equal(equalHash(digest, (digest.startsWith("0") ? "1" : "0") + digest.slice(1)), false);
    assert.equal(equalHash(digest, digest.slice(0, -1) + (digest.endsWith("0") ? "1" : "0")), false);
    assert.equal(equalHash("x", "x\u0000"), false);
  });

  it("accepts a single bounded bearer credential and rejects ambiguous headers", () => {
    assert.equal(bearer(new Request("https://scrnshr.example")), null);
    assert.equal(bearer(requestWithAuthorization("Bearer owner-secret")), "owner-secret");
    assert.equal(bearer(requestWithAuthorization("Bearer " + "a".repeat(256))), "a".repeat(256));
    for (const header of ["", "Bearer", "Bearer ", "Basic owner-secret", "bearer owner-secret", "Bearer a b", "Bearer a\tb", "Bearer  token", "Bearer " + "a".repeat(257)]) {
      assert.equal(bearer(requestWithAuthorization(header)), null, header);
    }
  });

  it("requires the generated-token format for peer authentication", () => {
    const token = makeToken();
    assert.equal(peerBearer(requestWithAuthorization("Bearer " + token)), token);
    assert.equal(peerBearer(new Request("https://scrnshr.example")), null);
    for (const token of ["owner-secret", "a".repeat(42), "a".repeat(44), "+" + "a".repeat(42), "/" + "a".repeat(42), "a".repeat(42) + "="]) {
      assert.equal(peerBearer(requestWithAuthorization("Bearer " + token)), null);
    }
  });

  it("marks success and error responses as uncacheable JSON with MIME sniffing disabled", async () => {
    const success = json({ sessionId: "example" }, 201);
    const failure = error("Session expired", 410);
    assert.equal(success.status, 201);
    assert.equal(failure.status, 410);
    assert.equal(json({ ok: true }).status, 200);
    for (const response of [success, failure]) {
      assert.equal(response.headers.get("Cache-Control"), "no-store");
      assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
      assert.match(response.headers.get("Content-Type") ?? "", /^application\/json\b/);
    }
    assert.deepEqual(await success.json(), { sessionId: "example" });
    assert.deepEqual(await failure.json(), { error: "Session expired" });
  });
});
