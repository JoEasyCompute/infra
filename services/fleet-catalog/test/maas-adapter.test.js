import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { buildSyncPayloadFromMaasMachine } from "../src/maas-adapter.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function loadFixture(name) {
  const fixturePath = path.join(__dirname, "fixtures", name);
  return JSON.parse(fs.readFileSync(fixturePath, "utf8"));
}

test("buildSyncPayloadFromMaasMachine maps raw MAAS fixture into sync contract", () => {
  const maasMachine = loadFixture("maas-machine-h100.json");

  const payload = buildSyncPayloadFromMaasMachine(maasMachine, {
    site_code: "lon1",
    rack_name: "rack-a1",
    sku_code: "gpu-h100x8-2tb-15tb-100g",
    source: "fixture-test",
    reason: "adapter verification"
  });

  assert.equal(payload.site_code, "lon1");
  assert.equal(payload.rack_name, "rack-a1");
  assert.equal(payload.sku_code, "gpu-h100x8-2tb-15tb-100g");
  assert.equal(payload.machine.maas_system_id, "maas-h100-fixture-01");
  assert.equal(payload.machine.infrastructure_state, "ready");
  assert.equal(payload.machine.sellability_state, "sellable");
  assert.equal(payload.machine.local_nvme_gb, 15360);
  assert.equal(payload.machine.network_gbps, 100);
  assert.equal(payload.machine.gpus.length, 2);
  assert.equal(payload.machine.gpus[0].model, "H100 SXM");
});
