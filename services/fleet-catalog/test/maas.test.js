import test from "node:test";
import assert from "node:assert/strict";

import {
  deriveSellabilityState,
  mapMaasStatusToInfrastructureState,
  normalizeMaasMachine
} from "../src/maas.js";

test("maps MAAS states into platform infrastructure states", () => {
  assert.equal(mapMaasStatusToInfrastructureState("Ready"), "ready");
  assert.equal(mapMaasStatusToInfrastructureState("Allocated"), "reserved");
  assert.equal(mapMaasStatusToInfrastructureState("Deployed"), "active");
});

test("unknown MAAS states default to quarantined", () => {
  assert.equal(mapMaasStatusToInfrastructureState("odd-state"), "quarantined");
});

test("sellable machines must be healthy, ready, and unleased", () => {
  const result = deriveSellabilityState({
    infrastructureState: "ready",
    leaseState: "none",
    healthState: "healthy",
    maintenanceState: "none"
  });

  assert.equal(result, "sellable");
});

test("maintenance machines are internal only", () => {
  const result = deriveSellabilityState({
    infrastructureState: "ready",
    leaseState: "none",
    healthState: "healthy",
    maintenanceState: "scheduled"
  });

  assert.equal(result, "internal_only");
});

test("normalization derives platform states and preserves GPU payloads", () => {
  const normalized = normalizeMaasMachine({
    hostname: "gpu-01",
    maas_system_id: "abc123",
    status_name: "Ready",
    zone: "lon-a",
    resource_pool: "retail",
    power_type: "redfish",
    tags: ["h100", "nvlink"],
    cpu_vendor: "AMD",
    cpu_model: "EPYC 9654",
    cpu_sockets: 2,
    cpu_cores_total: 192,
    ram_gb: 1536,
    local_nvme_gb: 7680,
    network_gbps: 100,
    nvlink_present: true,
    health_state: "healthy",
    maintenance_state: "none",
    gpus: [
      {
        slot_index: 0,
        vendor: "NVIDIA",
        model: "H100 SXM",
        memory_gb: 80,
        mig_capable: true
      }
    ]
  });

  assert.equal(normalized.infrastructure_state, "ready");
  assert.equal(normalized.lease_state, "none");
  assert.equal(normalized.sellability_state, "sellable");
  assert.equal(normalized.gpus[0].model, "H100 SXM");
});
