# scrnshr session protocol

The iPhone sends one screen video track and one app audio track to the Mac. The Mac remains the presenter and the phone remains the input device. The Worker coordinates a session through a Durable Object. SDP, ICE, and capture status are opaque messages; screen and audio media never pass through this service.

## Pairing and authorization

The Mac creates a session with a backend owner token. Configure that token in the Mac, keep it in Keychain, and send it only in an HTTPS `Authorization: Bearer <OWNER_TOKEN>` header. The iPhone never needs the owner token.

`POST /v1/sessions` has no body. A successful `201` response contains:

```json
{
  "sessionId": "2d59fd60-93a0-45c7-9c8a-750c302c0fef",
  "receiverToken": "<43-character base64url capability>",
  "joinToken": "<43-character base64url capability>",
  "expiresAt": "2026-10-13T19:00:00.000Z"
}
```

All three capabilities are 32 cryptographically random bytes, encoded without base64 padding. Only SHA-256 capability hashes persist in the Durable Object. A session expires two hours after creation. Its initial join token expires after five minutes; an unapproved session ends at that point.

The Mac independently generates a 32-byte pairing HMAC secret. Include the service HTTPS URL, session ID, join token, the two-hour session deadline, a separate five-minute join deadline, and pairing secret in the QR payload. The QR secret stays between the devices and never goes to the Worker. Showing the QR to another person grants that person the ability to request this session; the Mac must explicitly approve the sender before signaling begins. The signed native payload includes session identity, sending role, negotiation generation and a monotonically increasing sequence number. Each peer verifies those fields and the HMAC before applying SDP, ICE or capture status. Native endpoints, rather than the signaling service, enforce that authenticity check.

`GET /v1/sessions/:sessionId/ws` upgrades with `Authorization: Bearer <capability>`. Query parameters and query-string tokens are rejected. The receiver token identifies the Mac. Before approval, only the join token identifies the sender. On approval, the sender receives a new resume token, and the join token is revoked. Keep the resume token until the session ends; authenticated reconnects use that same token. If the initial approval frame is lost before the sender saves its resume token, create a fresh session and QR. Reusing the revoked join token cannot recover that session.

## WebSocket messages

Send JSON text frames no larger than 64 KiB. Each peer may send 120 frames per 10 seconds. The backend validates the outer envelope and preserves `payload` as the original string without parsing or re-serializing it.

Client messages:

```json
{ "type": "approve", "accepted": true }
{ "type": "signal", "payload": "<original signed JSON string>", "mac": "<base64url HMAC-SHA256>" }
{ "type": "stop" }
```

Only the receiver may approve or reject a pending sender. Both approved peers may signal or stop. A pending sender cannot stop the receiver's session. Rejecting a sender ends the session; create a fresh session and QR for another attempt.

Server messages:

| Message | Meaning |
| --- | --- |
| `{ "type": "waiting" }` | The connection is authenticated and pairing is pending. |
| `{ "type": "approval-required" }` | The receiver has a sender awaiting approval. |
| `{ "type": "approved", "resumeToken": "..." }` | Initial sender approval, carrying the new resume capability. |
| `{ "type": "approved" }` | Receiver approval or an already-approved reconnect. |
| `{ "type": "peer", "role": "sender" }` | The named other peer is connected and approved. The sender receives role `receiver`. |
| `{ "type": "rejected" }` | The receiver rejected the pending sender. |
| `{ "type": "signal", "payload": "...", "mac": "..." }` | Opaque signed message from the other approved peer. |
| `{ "type": "peer-left", "role": "sender" }` | Signaling disconnected for the named peer. The existing media connection may still be healthy. |
| `{ "type": "ended", "reason": "stopped" }` | Session ended. Other reasons include `rejected`, `pairing-expired`, and `session-expired`. |
| `{ "type": "error", "message": "..." }` | Invalid action or delivery problem; never contains secrets or SDP. |

There is one connection per role. A second sender using the pending join token gets HTTP `409`. An approved sender using its resume token, or the Mac using its receiver token, may replace its existing socket. The service stores a connection generation so late close events from the replaced socket cannot disconnect the new one. Socket attachments and SQLite state survive Durable Object hibernation. Clients cancel their WebSocket on `ended`, `rejected`, or an authenticated-reconnect replacement error and do not retry a replaced socket. They do not wait for a transport close handshake before updating session state.

Signaling reconnect never clears the Mac's blackout. Losing signaling alone does not authorize clearing live video or interrupting healthy WebRTC media. Session expiry, explicit stop, capture stop and media failure require the native clients to end or hide media independently of WebSocket availability. The session expiry in pairing data supplies an absolute native stop deadline.

## ICE configuration

`GET /v1/sessions/:sessionId/ice` requires the receiver token or approved sender resume token in a Bearer header. The pending join token cannot obtain credentials. The route allows 12 requests per peer per minute.

```json
{
  "iceServers": [
    { "urls": ["stun:stun.cloudflare.com:3478"] },
    {
      "urls": ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"],
      "username": "<expiring TURN username>",
      "credential": "<expiring TURN credential>"
    }
  ],
  "connectivity": "internet"
}
```

The backend keeps `TURN_KEY_ID` and `TURN_API_TOKEN` private and requests client credentials valid for two hours plus ten minutes. Peer authorization is checked again after the upstream request, so ending a session during issuance does not release credentials. Credential responses use `Cache-Control: no-store`. Direct ICE remains preferred unless native diagnostics explicitly choose relay-only mode.

Without TURN configuration, the route returns actionable HTTP `503`. Setting backend `ALLOW_STUN_ONLY=true` deliberately permits LAN development and returns only STUN with `connectivity: "local-only"`. Native clients should show that limitation and refuse to promise internet reachability.

## Errors, limits, and expiry

HTTP errors use `{ "error": "<message>" }`. `401` means missing or invalid authorization; `400` invalid path/query; `409` an occupied pending sender; `410` an ended, expired or unknown session; `426` missing WebSocket upgrade; `429` rate limit; `503` incomplete backend configuration; `502` TURN provider failure.

Authenticated session creation is limited to 12 per originating IP and 30 per owner per hour. Limiter identities are SHA-256 hashes; tokens and IPs are not stored or logged as plaintext. `/health` returns only the service name and success status. Logs contain generic event names and upstream status codes, never capabilities, TURN keys, SDP or signed payload contents. Set Cloudflare request observability to redact Authorization headers and avoid logging request URLs with pairing material.

Expired or stopped sessions revoke stored capability hashes immediately. Their tombstones expire a day after the original session deadline; cleanup deletes only the matching row inside that session's own Durable Object.

Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
