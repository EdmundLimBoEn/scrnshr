import { bindings, defineConfig, exports } from "cf/config";

const name = "scrnshr-signaling";

export default defineConfig(({ mode }) => ({
  worker: {
    name,
    entrypoint: "./src/index.ts",
    compatibilityDate: "2026-07-01",
    workersDev: true,
    env: {
      SESSIONS: bindings.durableObject({ worker: name, exportName: "SessionRoom" }),
      RATE_LIMITS: bindings.durableObject({ worker: name, exportName: "RequestLimiter" }),
      INGRESS_LIMIT: bindings.rateLimit({ namespace: "1001", simple: { limit: 60, period: 60 } }),
      OWNER_TOKEN: bindings.secret(),
      TURN_KEY_ID: bindings.secret(),
      TURN_API_TOKEN: bindings.secret(),
      ALLOW_STUN_ONLY: mode === "development" ? bindings.secret() : bindings.text("false"),
    },
    exports: {
      SessionRoom: exports.durableObject({ storage: "sqlite" }),
      RequestLimiter: exports.durableObject({ storage: "sqlite" }),
    },
  },
}));
