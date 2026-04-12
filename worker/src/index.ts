import { Env } from "./types";
import { authenticate } from "./auth";

export { TunnelRelay } from "./relay";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const auth = await authenticate(request, env);
    if (!auth.ok) return auth.response;

    const url = new URL(request.url);
    const runId = url.searchParams.get("run_id");
    if (!runId) return new Response("Missing run_id", { status: 400 });

    const role = url.searchParams.get("role");
    if (!role || (role !== "master" && role !== "worker")) {
      return new Response("Missing or invalid role", { status: 400 });
    }

    const doId = env.RELAY.idFromName(runId);
    const stub = env.RELAY.get(doId);
    return stub.fetch(request);
  },
};
