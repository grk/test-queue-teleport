import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        isolatedStorage: false,
        main: "./src/index.ts",
        miniflare: {
          compatibilityDate: "2025-04-01",
          d1Databases: {
            DB: "tq-teleport-db",
          },
          durableObjects: {
            RELAY: "TunnelRelay",
          },
        },
      },
    },
  },
});
