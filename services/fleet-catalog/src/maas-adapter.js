import { normalizeMaasMachine } from "./maas.js";

function toInteger(value, fallback = 0) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.trunc(value);
  }

  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number.parseInt(value, 10);
    return Number.isNaN(parsed) ? fallback : parsed;
  }

  return fallback;
}

function toBoolean(value, fallback = false) {
  if (typeof value === "boolean") {
    return value;
  }

  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["true", "1", "yes"].includes(normalized)) {
      return true;
    }
    if (["false", "0", "no"].includes(normalized)) {
      return false;
    }
  }

  return fallback;
}

function pickNvmeGb(machine) {
  if (typeof machine.local_nvme_gb === "number") {
    return machine.local_nvme_gb;
  }

  const blockDevices = Array.isArray(machine.block_devices) ? machine.block_devices : [];
  const nvmeBytes = blockDevices
    .filter((device) => `${device.type || ""}`.toLowerCase() === "nvme")
    .reduce((total, device) => total + Number(device.size_bytes || 0), 0);

  return nvmeBytes > 0 ? Math.floor(nvmeBytes / (1024 ** 3)) : 0;
}

function pickNetworkGbps(machine) {
  if (typeof machine.network_gbps === "number") {
    return machine.network_gbps;
  }

  const interfaces = Array.isArray(machine.interfaces) ? machine.interfaces : [];
  const maxMbps = interfaces.reduce((max, nic) => Math.max(max, Number(nic.link_speed_mbps || 0)), 0);
  return maxMbps > 0 ? Math.floor(maxMbps / 1000) : 1;
}

function deriveHealthState(machine) {
  if (typeof machine.health_state === "string") {
    return machine.health_state;
  }

  if (machine.commissioning_status === "failed" || machine.status_name === "Failed deployment") {
    return "failed";
  }

  return "healthy";
}

function deriveMaintenanceState(machine) {
  if (typeof machine.maintenance_state === "string") {
    return machine.maintenance_state;
  }

  return machine.in_maintenance ? "scheduled" : "none";
}

function mapGpuDevice(device, slotIndex) {
  return {
    slot_index: slotIndex,
    vendor: device.vendor || "NVIDIA",
    model: device.model,
    memory_gb: toInteger(device.memory_gb ?? device.vram_gb, 0),
    pci_bus_address: device.pci_bus_address || null,
    pcie_generation: device.pcie_generation != null ? toInteger(device.pcie_generation) : null,
    pcie_link_width: device.pcie_link_width != null ? toInteger(device.pcie_link_width) : null,
    serial_number: device.serial_number || null,
    device_uuid: device.uuid || device.device_uuid || null,
    ecc_enabled: device.ecc_enabled ?? null,
    mig_capable: toBoolean(device.mig_capable, false),
    nvlink_group: device.nvlink_group || null,
    health_state: device.health_state || "healthy",
    metadata: device.metadata || {}
  };
}

function buildNormalizedMachine(machine) {
  const normalizedInput = {
    hostname: machine.hostname,
    serial_number: machine.serial_number || machine.hardware_info?.system_serial || null,
    maas_system_id: machine.system_id,
    status_name: machine.status_name,
    zone: machine.zone?.name || machine.zone || null,
    resource_pool: machine.pool?.name || machine.resource_pool || null,
    power_type: machine.power_type || null,
    tags: Array.isArray(machine.tag_names) ? machine.tag_names : machine.tags || [],
    annotations: machine.annotations || {},
    cpu_vendor: machine.cpu_vendor || null,
    cpu_model: machine.cpu_model,
    cpu_sockets: toInteger(machine.cpu_sockets, 1),
    cpu_cores_total: toInteger(machine.cpu_count ?? machine.cpu_cores_total, 0),
    ram_gb: toInteger(machine.memory_gb ?? machine.ram_gb, 0),
    local_nvme_gb: pickNvmeGb(machine),
    network_gbps: pickNetworkGbps(machine),
    nvlink_present: toBoolean(machine.nvlink_present, false),
    maintenance_state: deriveMaintenanceState(machine),
    health_state: deriveHealthState(machine),
    health_reason: machine.health_reason || null,
    bmc_address: machine.power_parameters?.power_address || machine.bmc_address || null,
    numa_topology: machine.numa_topology || {},
    metadata: {
      source: "maas-adapter",
      maas_status_name: machine.status_name,
      maas_owner: machine.owner || null
    },
    gpus: (machine.gpu_devices || []).map(mapGpuDevice)
  };

  return normalizeMaasMachine(normalizedInput);
}

export function buildSyncPayloadFromMaasMachine(machine, placement) {
  return {
    site_code: placement.site_code,
    rack_name: placement.rack_name || null,
    sku_code: placement.sku_code || null,
    source: placement.source || "maas-adapter",
    reason: placement.reason || null,
    machine: buildNormalizedMachine(machine)
  };
}
