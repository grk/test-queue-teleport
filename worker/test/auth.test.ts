import { describe, it, expect, beforeEach } from "vitest";
import { env, SELF } from "cloudflare:test";

async function hashSecret(secret: string): Promise<string> {
  const encoded = new TextEncoder().encode(secret);
  const digest = await crypto.subtle.digest("SHA-256", encoded);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function seedApiKey(id: string, secret: string, teamName: string) {
  const secretHash = await hashSecret(secret);
  await env.DB.prepare(
    "INSERT OR REPLACE INTO api_keys (id, secret_hash, team_name) VALUES (?, ?, ?)"
  )
    .bind(id, secretHash, teamName)
    .run();
}

describe("Worker auth", () => {
  beforeEach(async () => {
    await env.DB.exec(
      "CREATE TABLE IF NOT EXISTS api_keys (id TEXT PRIMARY KEY, secret_hash TEXT NOT NULL, team_name TEXT, created_at TEXT DEFAULT (datetime('now')))"
    );
  });

  it("accepts a valid API key and routes to DO", async () => {
    await seedApiKey("k1a2b3", "deadbeef1234", "testteam");

    const response = await SELF.fetch(
      "https://fake.host/?run_id=test-run&role=master",
      {
        headers: {
          Authorization: "Bearer tqt_k1a2b3_deadbeef1234",
          Upgrade: "websocket",
        },
      }
    );

    expect(response.status).toBe(101);
  });

  it("rejects missing Authorization header", async () => {
    const response = await SELF.fetch(
      "https://fake.host/?run_id=test-run&role=master"
    );

    expect(response.status).toBe(401);
  });

  it("rejects malformed key format", async () => {
    const response = await SELF.fetch(
      "https://fake.host/?run_id=test-run&role=master",
      {
        headers: { Authorization: "Bearer not-a-valid-format" },
      }
    );

    expect(response.status).toBe(401);
  });

  it("rejects unknown key id", async () => {
    const response = await SELF.fetch(
      "https://fake.host/?run_id=test-run&role=master",
      {
        headers: { Authorization: "Bearer tqt_unknown_deadbeef1234" },
      }
    );

    expect(response.status).toBe(403);
  });

  it("rejects wrong secret for valid key id", async () => {
    await seedApiKey("k1a2b3", "deadbeef1234", "testteam");

    const response = await SELF.fetch(
      "https://fake.host/?run_id=test-run&role=master",
      {
        headers: { Authorization: "Bearer tqt_k1a2b3_wrongsecret00" },
      }
    );

    expect(response.status).toBe(403);
  });

  it("rejects missing run_id", async () => {
    await seedApiKey("k1a2b3", "deadbeef1234", "testteam");

    const response = await SELF.fetch(
      "https://fake.host/?role=master",
      {
        headers: { Authorization: "Bearer tqt_k1a2b3_deadbeef1234" },
      }
    );

    expect(response.status).toBe(400);
  });

  it("rejects missing role", async () => {
    await seedApiKey("k1a2b3", "deadbeef1234", "testteam");

    const response = await SELF.fetch(
      "https://fake.host/?run_id=test-run",
      {
        headers: { Authorization: "Bearer tqt_k1a2b3_deadbeef1234" },
      }
    );

    expect(response.status).toBe(400);
  });
});
