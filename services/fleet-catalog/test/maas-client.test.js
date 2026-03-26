import test from "node:test";
import assert from "node:assert/strict";

import { buildMaasAuthorizationHeader, createMaasClient } from "../src/maas-client.js";
import { fetchMachineAndBuildSyncPayload, fetchMachinesAndBuildSyncPayloads } from "../src/maas-integration.js";

test("buildMaasAuthorizationHeader encodes MAAS api keys into an OAuth header", () => {
  const header = buildMaasAuthorizationHeader("consumer:token:secret");

  assert.match(header, /^OAuth /);
  assert.match(header, /oauth_consumer_key="consumer"/);
  assert.match(header, /oauth_token="token"/);
  assert.match(header, /oauth_signature="%26secret"/);
});

test("createMaasClient requests machines with the expected endpoint and auth header", async () => {
  const calls = [];
  const client = createMaasClient({
    baseUrl: "http://maas.example:5240/MAAS/",
    apiKey: "consumer:token:secret",
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), headers: options.headers });
      return {
        ok: true,
        json: async () => [{ system_id: "abc123" }]
      };
    }
  });

  const result = await client.listMachines();

  assert.deepEqual(result, [{ system_id: "abc123" }]);
  assert.equal(calls[0].url, "http://maas.example:5240/MAAS/api/2.0/machines/");
  assert.match(calls[0].headers.Authorization, /^OAuth /);
});

test("fetchMachineAndBuildSyncPayload fetches a machine and builds the normalized sync contract", async () => {
  const payload = await fetchMachineAndBuildSyncPayload(
    "maas-h100-fixture-01",
    {
      site_code: "lon1",
      rack_name: "rack-a1",
      sku_code: "gpu-h100x8-2tb-15tb-100g"
    },
    {
      client: {
        async getMachine() {
          return {
            system_id: "maas-h100-fixture-01",
            hostname: "gpu-h100-fixture-01",
            status_name: "Ready",
            zone: { name: "lon-a" },
            pool: { name: "retail" },
            power_type: "redfish",
            cpu_vendor: "AMD",
            cpu_model: "EPYC 9654",
            cpu_sockets: 2,
            cpu_count: 192,
            memory_gb: 2048,
            interfaces: [{ link_speed_mbps: 100000 }],
            block_devices: [{ type: "nvme", size_bytes: 16492674416640 }],
            gpu_devices: [{ model: "H100 SXM", vram_gb: 80 }]
          };
        }
      }
    }
  );

  assert.equal(payload.site_code, "lon1");
  assert.equal(payload.machine.maas_system_id, "maas-h100-fixture-01");
  assert.equal(payload.machine.infrastructure_state, "ready");
  assert.equal(payload.machine.gpus[0].model, "H100 SXM");
});

test("fetchMachinesAndBuildSyncPayloads skips machines with no placement mapping", async () => {
  const payloads = await fetchMachinesAndBuildSyncPayloads(
    async (machine) => {
      if (machine.system_id === "keep-me") {
        return { site_code: "lon1", rack_name: "rack-a1" };
      }

      return null;
    },
    {
      client: {
        async listMachines() {
          return [
            {
              system_id: "keep-me",
              hostname: "gpu-keep",
              status_name: "Ready",
              cpu_model: "EPYC 9654",
              cpu_count: 192,
              memory_gb: 2048,
              gpu_devices: []
            },
            {
              system_id: "skip-me",
              hostname: "gpu-skip",
              status_name: "Ready",
              cpu_model: "EPYC 9654",
              cpu_count: 192,
              memory_gb: 2048,
              gpu_devices: []
            }
          ];
        }
      }
    }
  );

  assert.equal(payloads.length, 1);
  assert.equal(payloads[0].machine.maas_system_id, "keep-me");
});
