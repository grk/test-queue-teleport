import { Env } from "./types";

type AuthResult =
  | { ok: true }
  | { ok: false; response: Response };

const KEY_PREFIX = "tqt_";

function parseApiKey(header: string | null): { id: string; secret: string } | null {
  if (!header) return null;

  const bearer = header.replace("Bearer ", "");
  if (!bearer.startsWith(KEY_PREFIX)) return null;

  const withoutPrefix = bearer.slice(KEY_PREFIX.length);
  const separatorIndex = withoutPrefix.indexOf("_");
  if (separatorIndex === -1) return null;

  const id = withoutPrefix.slice(0, separatorIndex);
  const secret = withoutPrefix.slice(separatorIndex + 1);
  if (!id || !secret) return null;

  return { id, secret };
}

async function hashSecret(secret: string): Promise<string> {
  const encoded = new TextEncoder().encode(secret);
  const digest = await crypto.subtle.digest("SHA-256", encoded);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const bufA = encoder.encode(a);
  const bufB = encoder.encode(b);

  if (bufA.byteLength !== bufB.byteLength) {
    // Compare bufA against itself to burn the same time, then return false
    crypto.subtle.timingSafeEqual(bufA, bufA);
    return false;
  }

  return crypto.subtle.timingSafeEqual(bufA, bufB);
}

export async function authenticate(
  request: Request,
  env: Env
): Promise<AuthResult> {
  const parsed = parseApiKey(request.headers.get("Authorization"));
  if (!parsed) {
    return { ok: false, response: new Response("Unauthorized", { status: 401 }) };
  }

  const row = await env.DB.prepare(
    "SELECT secret_hash FROM api_keys WHERE id = ?"
  )
    .bind(parsed.id)
    .first<{ secret_hash: string }>();

  if (!row) {
    return { ok: false, response: new Response("Forbidden", { status: 403 }) };
  }

  const providedHash = await hashSecret(parsed.secret);

  if (!timingSafeEqual(providedHash, row.secret_hash)) {
    return { ok: false, response: new Response("Forbidden", { status: 403 }) };
  }

  return { ok: true };
}
