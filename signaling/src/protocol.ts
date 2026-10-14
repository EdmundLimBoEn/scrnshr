export type Role = "receiver" | "sender";

export type ClientMessage =
  | { type: "approve"; accepted: boolean }
  | { type: "signal"; payload: string; mac: string }
  | { type: "stop" };

export type ServerMessage =
  | { type: "waiting" }
  | { type: "peer"; role: Role }
  | { type: "approval-required" }
  | { type: "approved"; resumeToken?: string }
  | { type: "rejected" }
  | { type: "signal"; payload: string; mac: string }
  | { type: "peer-left"; role: Role }
  | { type: "ended"; reason: string }
  | { type: "error"; message: string };

export interface CreatedSession {
  sessionId: string;
  receiverToken: string;
  joinToken: string;
  expiresAt: string;
}

export interface IceServer {
  urls: [string, ...string[]];
  username?: string;
  credential?: string;
}

export interface IceResponse {
  iceServers: IceServer[];
  connectivity: "internet" | "local-only";
}

export const SESSION_DURATION_MS = 2 * 60 * 60 * 1000;
export const JOIN_DURATION_MS = 5 * 60 * 1000;
export const MAX_FRAME_BYTES = 64 * 1024;
export const FRAME_WINDOW_MS = 10_000;
export const MAX_FRAMES_PER_WINDOW = 120;
export const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseClientMessage(text: string): ClientMessage | null {
  let value: unknown;
  try { value = JSON.parse(text); } catch { return null; }
  if (!isRecord(value)) return null;
  switch (value.type) {
    case "approve":
      return typeof value.accepted === "boolean"
        ? { type: "approve", accepted: value.accepted } : null;
    case "signal":
      return typeof value.payload === "string" && value.payload.length > 0
        && typeof value.mac === "string" && TOKEN_PATTERN.test(value.mac)
        ? { type: "signal", payload: value.payload, mac: value.mac } : null;
    case "stop": return { type: "stop" };
    default: return null;
  }
}

export function parseIceServers(value: unknown): IceServer[] | null {
  if (!isRecord(value) || !Array.isArray(value.iceServers) || value.iceServers.length > 16) return null;
  const servers: IceServer[] = [];
  for (const server of value.iceServers) {
    if (!isRecord(server) || !Array.isArray(server.urls) || server.urls.length === 0 || server.urls.length > 16) return null;
    const urls: string[] = [];
    for (const url of server.urls) {
      if (typeof url !== "string" || url.length > 512 || !/^(stun|stuns|turn|turns):[^\s]+$/.test(url)) return null;
      urls.push(url);
    }
    const firstUrl = urls.shift();
    if (firstUrl === undefined) return null;
    const entry: IceServer = { urls: [firstUrl, ...urls] };
    if (server.username !== undefined) {
      if (typeof server.username !== "string" || server.username.length > 1024) return null;
      entry.username = server.username;
    }
    if (server.credential !== undefined) {
      if (typeof server.credential !== "string" || server.credential.length > 1024) return null;
      entry.credential = server.credential;
    }
    if (entry.urls.some(url => /^turns?:/.test(url)) && (!entry.username || !entry.credential)) return null;
    servers.push(entry);
  }
  return servers.length > 0 ? servers : null;
}
