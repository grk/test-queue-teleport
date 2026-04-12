import { describe, it, expect, beforeEach } from "vitest";
import { env, SELF } from "cloudflare:test";
import { RelayMessage } from "../src/types";

async function hashSecret(secret: string): Promise<string> {
  const encoded = new TextEncoder().encode(secret);
  const digest = await crypto.subtle.digest("SHA-256", encoded);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function seedApiKey(id: string, secret: string) {
  const secretHash = await hashSecret(secret);
  await env.DB.prepare(
    "INSERT OR IGNORE INTO api_keys (id, secret_hash, team_name) VALUES (?, ?, ?)"
  )
    .bind(id, secretHash, "test")
    .run();
}

async function connectWs(runId: string, role: "master" | "worker") {
  const response = await SELF.fetch(
    `https://fake.host/?run_id=${runId}&role=${role}`,
    {
      headers: {
        Authorization: "Bearer tqt_testkey_testsecret",
        Upgrade: "websocket",
      },
    }
  );
  return response;
}

describe("TunnelRelay", () => {
  beforeEach(async () => {
    await env.DB.exec(
      "CREATE TABLE IF NOT EXISTS api_keys (id TEXT PRIMARY KEY, secret_hash TEXT NOT NULL, team_name TEXT, created_at TEXT DEFAULT (datetime('now')))"
    );
    await seedApiKey("testkey", "testsecret");
  });

  it("accepts a master WebSocket connection", async () => {
    const response = await connectWs("conn-run1", "master");

    expect(response.status).toBe(101);
    expect(response.webSocket).toBeDefined();
  });

  it("accepts a worker WebSocket connection", async () => {
    const response = await connectWs("conn-run2", "worker");

    expect(response.status).toBe(101);
    expect(response.webSocket).toBeDefined();
  });

  it("rejects second master connection", async () => {
    // First master connects successfully
    const resp1 = await connectWs("conn-run3", "master");
    expect(resp1.status).toBe(101);
    const master1Ws = resp1.webSocket!;
    master1Ws.accept();

    // Second master attempt — the DO accepts the WebSocket then immediately closes it.
    // In the test env, the server.close() may not propagate as a client close event,
    // so instead we verify the first master still works by connecting a worker and
    // routing a message through it.
    const resp2 = await connectWs("conn-run3", "master");
    expect(resp2.status).toBe(101); // upgrade succeeds at HTTP level

    // Connect a worker and verify routing still goes to the first master
    const workerResp = await connectWs("conn-run3", "worker");
    const workerWs = workerResp.webSocket!;
    workerWs.accept();

    const masterReceived: RelayMessage[] = [];
    master1Ws.addEventListener("message", (event) => {
      const msg = JSON.parse(event.data as string) as RelayMessage;
      masterReceived.push(msg);
      master1Ws.send(JSON.stringify({
        type: "response",
        conn_id: msg.conn_id,
        data: btoa("from-master-1"),
      }));
    });

    const responsePromise = new Promise<RelayMessage>((resolve) => {
      workerWs.addEventListener("message", (event) => {
        resolve(JSON.parse(event.data as string));
      });
    });

    workerWs.send(JSON.stringify({
      type: "request",
      conn_id: "conn-dup-master",
      data: btoa("test"),
    }));

    const response = await responsePromise;
    expect(response.type).toBe("response");
    expect(atob(response.data!)).toBe("from-master-1");
  });

  it("rejects non-WebSocket request with 426", async () => {
    const response = await SELF.fetch(
      "https://fake.host/?run_id=conn-run4&role=master",
      {
        headers: {
          Authorization: "Bearer tqt_testkey_testsecret",
        },
      }
    );

    expect(response.status).toBe(426);
  });
});

describe("Message routing", () => {
  beforeEach(async () => {
    await env.DB.exec(
      "CREATE TABLE IF NOT EXISTS api_keys (id TEXT PRIMARY KEY, secret_hash TEXT NOT NULL, team_name TEXT, created_at TEXT DEFAULT (datetime('now')))"
    );
    await seedApiKey("testkey", "testsecret");
  });

  it("routes request from worker to master and response back", async () => {
    const masterResp = await connectWs("route1", "master");
    const masterWs = masterResp.webSocket!;
    masterWs.accept();

    const workerResp = await connectWs("route1", "worker");
    const workerWs = workerResp.webSocket!;
    workerWs.accept();

    const masterReceived: RelayMessage[] = [];
    masterWs.addEventListener("message", (event) => {
      const msg = JSON.parse(event.data as string) as RelayMessage;
      masterReceived.push(msg);
      masterWs.send(
        JSON.stringify({
          type: "response",
          conn_id: msg.conn_id,
          data: btoa("test-response-data"),
        })
      );
    });

    const responsePromise = new Promise<RelayMessage>((resolve) => {
      workerWs.addEventListener("message", (event) => {
        resolve(JSON.parse(event.data as string));
      });
    });

    workerWs.send(
      JSON.stringify({
        type: "request",
        conn_id: "conn-1",
        data: btoa("test-request-data"),
      })
    );

    const response = await responsePromise;

    expect(masterReceived).toHaveLength(1);
    expect(masterReceived[0].type).toBe("request");
    expect(masterReceived[0].conn_id).toBe("conn-1");
    expect(masterReceived[0].data).toBe(btoa("test-request-data"));

    expect(response.type).toBe("response");
    expect(response.conn_id).toBe("conn-1");
    expect(response.data).toBe(btoa("test-response-data"));
  });

  it("routes fire-and-forget send without tracking", async () => {
    const masterResp = await connectWs("route2", "master");
    const masterWs = masterResp.webSocket!;
    masterWs.accept();

    const workerResp = await connectWs("route2", "worker");
    const workerWs = workerResp.webSocket!;
    workerWs.accept();

    const masterReceived: RelayMessage[] = [];
    const messagePromise = new Promise<RelayMessage>((resolve) => {
      masterWs.addEventListener("message", (event) => {
        const msg = JSON.parse(event.data as string) as RelayMessage;
        masterReceived.push(msg);
        resolve(msg);
      });
    });

    workerWs.send(
      JSON.stringify({
        type: "send",
        conn_id: "conn-ff",
        data: btoa("fire-and-forget-data"),
      })
    );

    const msg = await messagePromise;
    expect(msg.type).toBe("send");
    expect(msg.conn_id).toBe("conn-ff");
    expect(msg.data).toBe(btoa("fire-and-forget-data"));
  });

  it("returns error when worker sends request with no master", async () => {
    const workerResp = await connectWs("route3", "worker");
    const workerWs = workerResp.webSocket!;
    workerWs.accept();

    const responsePromise = new Promise<RelayMessage>((resolve) => {
      workerWs.addEventListener("message", (event) => {
        resolve(JSON.parse(event.data as string));
      });
    });

    workerWs.send(
      JSON.stringify({
        type: "request",
        conn_id: "conn-nomaster",
        data: btoa("some-data"),
      })
    );

    const response = await responsePromise;
    expect(response.type).toBe("error");
    expect(response.conn_id).toBe("conn-nomaster");
    expect(response.reason).toBe("master_not_connected");
  });

  it("routes requests from multiple workers independently", async () => {
    const masterResp = await connectWs("route5", "master");
    const masterWs = masterResp.webSocket!;
    masterWs.accept();

    masterWs.addEventListener("message", (event) => {
      const msg = JSON.parse(event.data as string) as RelayMessage;
      if (msg.type === "request") {
        masterWs.send(
          JSON.stringify({
            type: "response",
            conn_id: msg.conn_id,
            data: btoa("reply-to-" + atob(msg.data!)),
          })
        );
      }
    });

    const workers: WebSocket[] = [];
    for (let i = 0; i < 2; i++) {
      const resp = await connectWs("route5", "worker");
      const ws = resp.webSocket!;
      ws.accept();
      workers.push(ws);
    }

    const responses: Promise<RelayMessage>[] = workers.map(
      (ws, i) =>
        new Promise<RelayMessage>((resolve) => {
          ws.addEventListener("message", (event) => {
            resolve(JSON.parse(event.data as string));
          });
          ws.send(
            JSON.stringify({
              type: "request",
              conn_id: `conn-worker-${i}`,
              data: btoa(`worker-${i}`),
            })
          );
        })
    );

    const results = await Promise.all(responses);

    expect(results[0].conn_id).toBe("conn-worker-0");
    expect(atob(results[0].data!)).toBe("reply-to-worker-0");
    expect(results[1].conn_id).toBe("conn-worker-1");
    expect(atob(results[1].data!)).toBe("reply-to-worker-1");
  });
});
