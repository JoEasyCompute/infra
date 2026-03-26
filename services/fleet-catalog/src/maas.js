const MAAS_STATUS_TO_INFRASTRUCTURE_STATE = {
  new: "discovered",
  commissioning: "commissioning",
  ready: "ready",
  allocated: "reserved",
  deploying: "deploying",
  deployed: "active",
  releasing: "releasing",
  "disk erasing": "wiping",
  "rescue mode": "maintenance",
  "failed commissioning": "quarantined",
  "failed deployment": "broken",
  "failed disk erasing": "quarantined",
  broken: "broken"
};

export function mapMaasStatusToInfrastructureState(statusName) {
  const normalized = statusName.trim().toLowerCase();
  return MAAS_STATUS_TO_INFRASTRUCTURE_STATE[normalized] || "quarantined";
}

export function deriveSellabilityState({
  infrastructureState,
  leaseState,
  healthState,
  maintenanceState
}) {
  if (healthState !== "healthy") {
    return "not_sellable";
  }

  if (maintenanceState !== "none") {
    return "internal_only";
  }

  if (infrastructureState !== "ready") {
    return "not_sellable";
  }

  if (leaseState !== "none") {
    return "not_sellable";
  }

  return "sellable";
}

export function normalizeMaasMachine(payload) {
  const infrastructureState = mapMaasStatusToInfrastructureState(payload.status_name);

  let leaseState = "none";
  if (infrastructureState === "reserved") {
    leaseState = "reserved";
  } else if (infrastructureState === "deploying") {
    leaseState = "provisioning";
  } else if (infrastructureState === "active") {
    leaseState = "active";
  }

  const sellabilityState = deriveSellabilityState({
    infrastructureState,
    leaseState,
    healthState: payload.health_state,
    maintenanceState: payload.maintenance_state
  });

  return {
    hostname: payload.hostname,
    serial_number: payload.serial_number || null,
    maas_system_id: payload.maas_system_id,
    maas_zone: payload.zone || null,
    maas_resource_pool: payload.resource_pool || null,
    maas_power_type: payload.power_type || null,
    maas_tags: payload.tags || [],
    maas_annotations: payload.annotations || {},
    cpu_vendor: payload.cpu_vendor || null,
    cpu_model: payload.cpu_model,
    cpu_sockets: payload.cpu_sockets ?? 1,
    cpu_cores_total: payload.cpu_cores_total,
    ram_gb: payload.ram_gb,
    local_nvme_gb: payload.local_nvme_gb ?? 0,
    network_gbps: payload.network_gbps ?? 1,
    nvlink_present: payload.nvlink_present ?? false,
    bmc_address: payload.bmc_address || null,
    numa_topology: payload.numa_topology || {},
    infrastructure_state: infrastructureState,
    lease_state: leaseState,
    health_state: payload.health_state || "unknown",
    sellability_state: sellabilityState,
    maintenance_state: payload.maintenance_state || "none",
    health_reason: payload.health_reason || null,
    metadata: payload.metadata || {},
    gpus: payload.gpus || []
  };
}
