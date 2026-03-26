import test from "node:test";
import assert from "node:assert/strict";

import { runMaasSync } from "../src/maas-sync-runner.js";

test("runMaasSync fetches, resolves placement, and syncs machines", async () => {
  const calls = [];
  const result = await runMaasSync({
    placementResolver: async (machine) => ({
      site_code: "lon1",
      rack_name: "rack-a1",
      sku_code: machine.system_id === "maas-01" ? "gpu-h100x8-2tb-15tb-100g" : null
    }),
    clientOptions: {
      client: {
        async listMachines() {
          return [
            {
              system_id: "maas-01",
              hostname: "gpu-01",
              status_name: "Ready",
              cpu_model: "EPYC 9654",
              cpu_count: 192,
              memory_gb: 2048,
              gpu_devices: []
            }
          ];
        }
      }
    },
    syncMachineFromNormalizedPayload: async (payload) => {
      calls.push(payload);
      return { gpu_count: payload.machine.gpus.length };
    }
  });

  assert.equal(result.synced, 1);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].site_code, "lon1");
  assert.equal(calls[0].machine.maas_system_id, "maas-01");
});
