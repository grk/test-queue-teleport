import { Env, RelayMessage } from "./types";

export class TunnelRelay {
  private state: DurableObjectState;
  private env: Env;
  private master: WebSocket | null = null;
  private workers: Map<string, WebSocket> = new Map();
  private pendingRequests: Map<string, WebSocket> = new Map();

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }

    const url = new URL(request.url);
    const role = url.searchParams.get("role");

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    if (role === "master") {
      if (this.master !== null) {
        server.accept();
        server.close(4409, "Master already connected");
        return new Response(null, { status: 101, webSocket: client });
      }

      this.master = server;
      server.accept();

      server.addEventListener("message", (event) => {
        this.handleMasterMessage(event);
      });

      server.addEventListener("close", () => {
        this.master = null;
        for (const [, ws] of this.workers) {
          ws.close(1001, "Master disconnected");
        }
        this.workers.clear();
        this.pendingRequests.clear();
      });
    } else {
      const workerId = crypto.randomUUID();
      this.workers.set(workerId, server);
      server.accept();

      server.addEventListener("message", (event) => {
        this.handleWorkerMessage(server, event);
      });

      server.addEventListener("close", () => {
        this.workers.delete(workerId);
        for (const [connId, ws] of this.pendingRequests) {
          if (ws === server) {
            this.pendingRequests.delete(connId);
          }
        }
      });
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  private handleMasterMessage(event: MessageEvent): void {
    let msg: RelayMessage;
    try {
      msg = JSON.parse(event.data as string);
    } catch {
      return;
    }

    if (msg.type !== "response" || !msg.conn_id) return;

    const workerWs = this.pendingRequests.get(msg.conn_id);
    if (workerWs) {
      workerWs.send(
        JSON.stringify({
          type: "response",
          conn_id: msg.conn_id,
          data: msg.data,
        })
      );
      this.pendingRequests.delete(msg.conn_id);
    }
  }

  private handleWorkerMessage(workerWs: WebSocket, event: MessageEvent): void {
    let msg: RelayMessage;
    try {
      msg = JSON.parse(event.data as string);
    } catch {
      return;
    }

    if (!msg.conn_id) return;

    if (!this.master || this.master.readyState !== WebSocket.READY_STATE_OPEN) {
      if (msg.type === "request") {
        workerWs.send(
          JSON.stringify({
            type: "error",
            conn_id: msg.conn_id,
            reason: "master_not_connected",
          })
        );
      }
      return;
    }

    if (msg.type === "request") {
      this.pendingRequests.set(msg.conn_id, workerWs);
      this.master.send(
        JSON.stringify({
          type: "request",
          conn_id: msg.conn_id,
          data: msg.data,
        })
      );
    } else if (msg.type === "send") {
      this.master.send(
        JSON.stringify({
          type: "send",
          conn_id: msg.conn_id,
          data: msg.data,
        })
      );
    }
  }
}
