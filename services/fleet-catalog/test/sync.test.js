import test from "node:test";
import assert from "node:assert/strict";

import { validateSyncRequest } from "../src/sync.js";

test("validateSyncRequest requires site context and core machine fields", () => {
  const errors = validateSyncRequest({
    machine: {
      hostname: "",
      maas_system_id: "",
      cpu_model: "",
      cpu_cores_total: 0,
      ram_gb: 0,
      gpus: {}
    }
  });

  assert.deepEqual(errors, [
    "site_code is required",
    "machine.hostname is required",
    "machine.maas_system_id is required",
    "machine.cpu_model is required",
    "machine.cpu_cores_total must be a positive integer",
    "machine.ram_gb must be a positive integer",
    "machine.gpus must be an array"
  ]);
});

test("validateSyncRequest accepts a minimal valid normalized sync payload", () => {
  const errors = validateSyncRequest({
    site_code: "lon1",
    rack_name: "rack-a1",
    sku_code: "gpu-h100x8-2tb-15tb-100g",
    source: "fixture",
    machine: {
      hostname: "gpu-h100-01",
      maas_system_id: "maas-h100-01",
      cpu_model: "EPYC 9654",
      cpu_cores_total: 192,
      ram_gb: 2048,
      gpus: []
    }
  });

  assert.deepEqual(errors, []);
});
