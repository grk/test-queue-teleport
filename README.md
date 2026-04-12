# test-queue-teleport

**test-queue's distributed mode, but it works everywhere.**

[test-queue](https://github.com/tmm1/test-queue) has a distributed mode where a central master serves work over TCP and relay workers on other machines connect to it. It works great when all nodes share a network. It doesn't work when runners are isolated VMs with no inbound connectivity — like GitHub Actions, most cloud CI, or any setup where machines can't see each other.

test-queue-teleport bridges the TCP connection through a Cloudflare Durable Object. Both sides connect outbound — no inbound ports, no VPNs, no tunnels to configure.

```
CI Runner (master)          Cloudflare              CI Runners (workers × N)

rspec-queue master          Durable Object          rspec-queue relay
    │ TCP                   (per run)                   │ TCP
tq-teleport serve ══WS══►  ◄══WS══  tq-teleport connect ◄────┘
```

test-queue doesn't know Cloudflare exists. The master thinks it's serving local TCP. The relay workers think they're connecting to a TCP address.

## Quick Start

### 1. Deploy the relay

```bash
cd worker
cp wrangler.toml.example wrangler.toml
bun install
bun wrangler d1 create tq-teleport-db
# Update database_id in wrangler.toml
bun wrangler d1 execute tq-teleport-db --remote --file schema.sql
bun wrangler deploy
```

### 2. Create an API key

```bash
cd worker
bun run generate-key myteam
# Save the full key as a CI secret (TQ_TELEPORT_API_KEY)
# Run the D1 insert command with --remote
```

### 3. Add the gem

```ruby
# Gemfile
group :test do
  gem "test-queue"
  gem "test-queue-teleport"
end
```

### 4. Update your CI config

Set three environment variables on all jobs, then wrap your test-queue command:

```bash
# On the master node:
export TQ_TELEPORT_URL=https://tq-teleport.your-account.workers.dev
export TQ_TELEPORT_API_KEY=tqt_...
export TQ_TELEPORT_RUN_ID=$UNIQUE_BUILD_ID  # must be the same across all nodes

tq-teleport serve -- bundle exec rspec-queue

# On each worker node:
tq-teleport connect -- bundle exec rspec-queue
```

The master job runs test-queue with its local workers. The worker jobs connect through the relay and pull work from the same queue.

<details>
<summary>GitHub Actions example</summary>

```yaml
name: Tests
on: push

env:
  TQ_TELEPORT_URL: ${{ secrets.TQ_TELEPORT_URL }}
  TQ_TELEPORT_API_KEY: ${{ secrets.TQ_TELEPORT_API_KEY }}
  TQ_TELEPORT_RUN_ID: "${{ github.run_id }}-${{ github.run_attempt }}"

jobs:
  master:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { bundler-cache: true }
      - run: bundle exec tq-teleport serve -- bundle exec rspec-queue

  workers:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        worker: [0, 1, 2, 3]
      fail-fast: false
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { bundler-cache: true }
      - run: bundle exec tq-teleport connect -- bundle exec rspec-queue
```
</details>

## Custom Runners

If you already have a custom test-queue runner:

```yaml
# Master:
- run: bundle exec tq-teleport serve -- bundle exec ruby script/test-queue

# Workers:
- run: bundle exec tq-teleport connect -- bundle exec ruby script/test-queue
```

Zero changes to your runner script. `tq-teleport` sets `TEST_QUEUE_SOCKET` and `TEST_QUEUE_RELAY` automatically.

## E2E Encryption

By default, data flows through Cloudflare as base64 over TLS. For end-to-end encryption where the relay cannot read your test data:

```bash
# Generate an encryption key (shown by generate-key script)
# Add as CI secret: TQ_TELEPORT_ENCRYPTION_KEY
```

When `TQ_TELEPORT_ENCRYPTION_KEY` is set, all data is encrypted with AES-256-GCM before leaving your runners. The relay only sees ciphertext.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TQ_TELEPORT_URL` | Yes | Your deployed Worker URL |
| `TQ_TELEPORT_API_KEY` | Yes | API key from `generate-key` |
| `TQ_TELEPORT_RUN_ID` | Yes | Unique per CI run, same across all nodes |
| `TQ_TELEPORT_ENCRYPTION_KEY` | No | Enables E2E encryption |
| `TQ_TELEPORT_DEBUG` | No | Verbose debug output to stderr |

## How It Works

The gem spawns test-queue as a subprocess and bridges its TCP connections to WebSocket frames. `serve` connects as master, `connect` connects as worker. Both handle signal forwarding, reconnection on WS drops, and graceful shutdown.

Each CI run gets its own Durable Object instance. The DO holds WebSocket connections and routes opaque message frames between master and workers using a `conn_id` correlation. It never parses test-queue's protocol.

## Why Durable Objects

The relay needs to hold WebSocket connections from both sides and route messages between them in real time. This is a surprisingly awkward problem for most infrastructure:

- **A regular server** works, but now you're maintaining a box, handling TLS, dealing with uptime. For a CI tool that runs a few minutes a day, it's overkill.
- **A serverless function** (Lambda, Cloud Function) can't hold WebSocket connections — it processes a request and dies.
- **A managed WebSocket service** (Pusher, Ably) adds latency, cost, and a dependency for what's fundamentally just routing bytes between two sockets.

Cloudflare Durable Objects are uniquely suited here:

- **Each run gets its own instance**, keyed by run ID. No shared state, no cleanup, no collision between concurrent CI runs.
- **WebSocket connections are first-class** — the DO holds them in memory for the duration of the run, routing messages with sub-millisecond latency.
- **It only exists while connections are open.** When the test run ends and sockets close, the DO disappears. No idle compute.
- **Global anycast** — both master and workers connect to the nearest Cloudflare edge, then get routed to the same DO. No region configuration.
- **The free tier is generous.** A typical CI run generates a few thousand DO requests (one per test file distributed + results). Free tier handles dozens of runs per day easily.

## License

[O'Saasy License](LICENSE.md) — free to use, modify, and self-host. Cannot be offered as a competing hosted service.
