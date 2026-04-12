export interface Env {
  DB: D1Database;
  RELAY: DurableObjectNamespace;
}

export interface RelayMessage {
  type: "request" | "send" | "response" | "error";
  conn_id: string;
  data?: string;
  reason?: string;
}
