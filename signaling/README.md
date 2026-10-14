# Signaling service

This Worker uses one SQLite Durable Object per session and separate hashed limiter objects. It approves exactly one iPhone sender, forwards authenticated-peer signaling, and issues expiring Cloudflare TURN credentials. See [the protocol](../docs/protocol.md) for native client messages and errors.

## Local checks

Use Bun to install the pinned toolchain, with Node.js 22.18 or newer installed. The current Cloudflare CLI loads TypeScript configuration through Node; do not run it with Bun's `--bun` override.

```sh
cd signaling
bun install --frozen-lockfile
bun run check
bun run check:deploy
```

`check` typechecks source and configuration, runs real Workers-runtime integration tests, then builds the Worker. `check:deploy` reads that artifact and validates a deployment dry run without uploading it or creating resources. The build lives in `.cloudflare/output/v0/` and includes both SQLite Durable Object exports.

The project pins `cf` and the Cloudflare Vite plugin because the host's older global `cf` lacks the current typed `cf/config` interface. There is no Wrangler configuration or Wrangler fallback.

## Local server

Copy `.dev.vars.example` to `.dev.vars`. Replace its owner token with 32 random bytes encoded as base64url. The file is ignored by Git. Set `ALLOW_STUN_ONLY=true` only for deliberate LAN development; internet connectivity requires the TURN settings.

```sh
bun run dev
```

The Vite development server listens at port 8787, or the next available port, on all local interfaces, with local Durable Objects. Use a development HTTPS endpoint for phone tests, and keep the owner token on the Mac. Backend HTTP tests run locally without an Apple device. The pinned CLI's `cf dev --local` flag is currently unsupported; its Vite development workflow already runs locally.

## Deployment handoff

Deployment stays gated until the native HDMI checks pass. The future deploy target is `scrnshr-signaling`, with SQLite classes `SessionRoom` and `RequestLimiter`. Required backend secret bindings are `OWNER_TOKEN`, `TURN_KEY_ID`, and `TURN_API_TOKEN`. Generate a fresh owner token and keep the TURN API token server-side. Production `ALLOW_STUN_ONLY` is false.

After Cloudflare authentication and account selection, create a protected temporary JSON file containing only those three backend bindings. Pass the file to the deployment command; never print its contents or commit it. The CLI uploads the secrets with the new Worker version:

```sh
bun run build
bun run check:deploy
bun run deploy -- --secrets-file /absolute/path/to/protected-secrets.json
```

The deployment script uploads the prebuilt artifact. A manual CI deployment may use this command after the hardware gate; pull requests and ordinary pushes only run checks. CI account access uses `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`; those deployment credentials do not belong in the Worker secrets file. The exact local CLI is pinned because the typed configuration is still in beta. [Cloudflare project commands](https://developers.cloudflare.com/cf/projects/), [CI authentication](https://developers.cloudflare.com/cf/ci/).

The tests mock only the upstream TURN API. Session routing, SQLite storage, WebSockets, alarms and role authorization run in Miniflare/workerd. They do not prove actual TURN reachability, phone capture, Apple signing, app audio, or HDMI rendering.

Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
