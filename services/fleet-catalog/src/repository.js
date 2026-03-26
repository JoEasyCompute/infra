import { query, withTransaction } from "./db.js";

function mapMachineSummary(row) {
  return {
    id: row.id,
    hostname: row.hostname,
    serial_number: row.serial_number,
    maas_system_id: row.maas_system_id,
    maas_zone: row.maas_zone,
    maas_resource_pool: row.maas_resource_pool,
    infrastructure_state: row.infrastructure_state,
    lease_state: row.lease_state,
    health_state: row.health_state,
    sellability_state: row.sellability_state,
    maintenance_state: row.maintenance_state,
    site_code: row.site_code,
    rack_name: row.rack_name,
    sku_code: row.sku_code,
    gpu_count: Number(row.gpu_count || 0),
    activated_at: row.activated_at
  };
}

export async function listMachines() {
  const result = await query(
    `
      SELECT
        m.id,
        m.hostname,
        m.serial_number,
        m.maas_system_id,
        m.maas_zone,
        m.maas_resource_pool,
        m.infrastructure_state,
        m.lease_state,
        m.health_state,
        m.sellability_state,
        m.maintenance_state,
        s.code AS site_code,
        r.name AS rack_name,
        sk.sku_code,
        COUNT(g.id) AS gpu_count,
        m.activated_at
      FROM machines m
      JOIN sites s ON s.id = m.site_id
      LEFT JOIN racks r ON r.id = m.rack_id
      LEFT JOIN skus sk ON sk.id = m.sku_id
      LEFT JOIN gpu_devices g ON g.machine_id = m.id
      GROUP BY m.id, s.code, r.name, sk.sku_code
      ORDER BY m.hostname ASC
    `
  );

  return result.rows.map(mapMachineSummary);
}

async function getMachineWithExecutor(executor, machineId) {
  const machineResult = await executor(
    `
      SELECT
        m.id,
        m.hostname,
        m.serial_number,
        m.maas_system_id,
        m.maas_zone,
        m.maas_resource_pool,
        m.maas_power_type,
        m.infrastructure_state,
        m.lease_state,
        m.health_state,
        m.sellability_state,
        m.maintenance_state,
        m.health_reason,
        s.code AS site_code,
        r.name AS rack_name,
        m.maas_tags,
        m.maas_annotations,
        m.metadata,
        m.discovered_at,
        m.commissioned_at,
        m.ready_at,
        m.activated_at,
        m.retired_at,
        sk.id AS sku_id,
        sk.sku_code,
        sk.display_name,
        sk.gpu_model,
        sk.gpu_count,
        sk.gpu_memory_gb,
        sk.cpu_model AS sku_cpu_model,
        sk.cpu_cores,
        sk.ram_gb AS sku_ram_gb,
        sk.local_nvme_gb AS sku_local_nvme_gb,
        sk.network_gbps AS sku_network_gbps,
        sk.interconnect
      FROM machines m
      JOIN sites s ON s.id = m.site_id
      LEFT JOIN racks r ON r.id = m.rack_id
      LEFT JOIN skus sk ON sk.id = m.sku_id
      WHERE m.id = $1
    `,
    [machineId]
  );

  if (machineResult.rows.length === 0) {
    return null;
  }

  const machine = machineResult.rows[0];
  const gpuResult = await executor(
    `
      SELECT
        id,
        slot_index,
        vendor,
        model,
        memory_gb,
        health_state,
        mig_capable,
        nvlink_group
      FROM gpu_devices
      WHERE machine_id = $1
      ORDER BY slot_index ASC
    `,
    [machineId]
  );

  return {
    id: machine.id,
    hostname: machine.hostname,
    serial_number: machine.serial_number,
    maas_system_id: machine.maas_system_id,
    maas_zone: machine.maas_zone,
    maas_resource_pool: machine.maas_resource_pool,
    maas_power_type: machine.maas_power_type,
    infrastructure_state: machine.infrastructure_state,
    lease_state: machine.lease_state,
    health_state: machine.health_state,
    sellability_state: machine.sellability_state,
    maintenance_state: machine.maintenance_state,
    health_reason: machine.health_reason,
    site_code: machine.site_code,
    rack_name: machine.rack_name,
    sku: machine.sku_id
      ? {
          id: machine.sku_id,
          sku_code: machine.sku_code,
          display_name: machine.display_name,
          gpu_model: machine.gpu_model,
          gpu_count: machine.gpu_count,
          gpu_memory_gb: machine.gpu_memory_gb,
          cpu_model: machine.sku_cpu_model,
          cpu_cores: machine.cpu_cores,
          ram_gb: machine.sku_ram_gb,
          local_nvme_gb: machine.sku_local_nvme_gb,
          network_gbps: machine.sku_network_gbps,
          interconnect: machine.interconnect
        }
      : null,
    gpus: gpuResult.rows,
    maas_tags: machine.maas_tags,
    maas_annotations: machine.maas_annotations,
    metadata: machine.metadata,
    discovered_at: machine.discovered_at,
    commissioned_at: machine.commissioned_at,
    ready_at: machine.ready_at,
    activated_at: machine.activated_at,
    retired_at: machine.retired_at
  };
}

export async function getMachine(machineId) {
  return getMachineWithExecutor(query, machineId);
}

async function resolveSiteId(client, siteCode) {
  const result = await client.query("SELECT id FROM sites WHERE code = $1", [siteCode]);
  return result.rows[0]?.id || null;
}

async function resolveRackId(client, siteId, rackName) {
  if (!rackName) {
    return null;
  }

  const result = await client.query("SELECT id FROM racks WHERE site_id = $1 AND name = $2", [siteId, rackName]);
  return result.rows[0]?.id || null;
}

async function resolveSkuId(client, skuCode) {
  if (!skuCode) {
    return null;
  }

  const result = await client.query("SELECT id FROM skus WHERE sku_code = $1", [skuCode]);
  return result.rows[0]?.id || null;
}

function buildStateHistoryMetadata(syncPayload) {
  return {
    sync_source: syncPayload.source || "internal-maas-sync",
    maas_system_id: syncPayload.machine.maas_system_id,
    maas_zone: syncPayload.machine.maas_zone,
    maas_resource_pool: syncPayload.machine.maas_resource_pool
  };
}

export async function syncMachineFromNormalizedPayload(syncPayload) {
  return withTransaction(async (client) => {
    const siteId = await resolveSiteId(client, syncPayload.site_code);
    if (!siteId) {
      throw new Error(`unknown site_code: ${syncPayload.site_code}`);
    }

    const rackId = await resolveRackId(client, siteId, syncPayload.rack_name);
    if (syncPayload.rack_name && !rackId) {
      throw new Error(`unknown rack_name '${syncPayload.rack_name}' for site_code '${syncPayload.site_code}'`);
    }

    const skuId = await resolveSkuId(client, syncPayload.sku_code);
    if (syncPayload.sku_code && !skuId) {
      throw new Error(`unknown sku_code: ${syncPayload.sku_code}`);
    }

    const machineUpsert = await client.query(
      `
        INSERT INTO machines (
          hostname,
          serial_number,
          site_id,
          rack_id,
          sku_id,
          maas_system_id,
          maas_zone,
          maas_resource_pool,
          maas_power_type,
          maas_tags,
          maas_annotations,
          bmc_address,
          cpu_vendor,
          cpu_model,
          cpu_sockets,
          cpu_cores_total,
          ram_gb,
          local_nvme_gb,
          network_gbps,
          numa_topology,
          nvlink_present,
          infrastructure_state,
          lease_state,
          health_state,
          sellability_state,
          maintenance_state,
          health_reason,
          metadata,
          discovered_at,
          commissioned_at,
          ready_at,
          activated_at,
          retired_at
        )
        VALUES (
          $1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb, $11::jsonb, $12::inet,
          $13, $14, $15, $16, $17, $18, $19, $20::jsonb, $21, $22::infrastructure_state,
          $23::lease_state, $24::health_state, $25::sellability_state, $26::maintenance_state,
          $27, $28::jsonb, $29, $30, $31, $32, $33
        )
        ON CONFLICT (maas_system_id) DO UPDATE SET
          hostname = EXCLUDED.hostname,
          serial_number = EXCLUDED.serial_number,
          site_id = EXCLUDED.site_id,
          rack_id = EXCLUDED.rack_id,
          sku_id = EXCLUDED.sku_id,
          maas_zone = EXCLUDED.maas_zone,
          maas_resource_pool = EXCLUDED.maas_resource_pool,
          maas_power_type = EXCLUDED.maas_power_type,
          maas_tags = EXCLUDED.maas_tags,
          maas_annotations = EXCLUDED.maas_annotations,
          bmc_address = EXCLUDED.bmc_address,
          cpu_vendor = EXCLUDED.cpu_vendor,
          cpu_model = EXCLUDED.cpu_model,
          cpu_sockets = EXCLUDED.cpu_sockets,
          cpu_cores_total = EXCLUDED.cpu_cores_total,
          ram_gb = EXCLUDED.ram_gb,
          local_nvme_gb = EXCLUDED.local_nvme_gb,
          network_gbps = EXCLUDED.network_gbps,
          numa_topology = EXCLUDED.numa_topology,
          nvlink_present = EXCLUDED.nvlink_present,
          infrastructure_state = EXCLUDED.infrastructure_state,
          lease_state = EXCLUDED.lease_state,
          health_state = EXCLUDED.health_state,
          sellability_state = EXCLUDED.sellability_state,
          maintenance_state = EXCLUDED.maintenance_state,
          health_reason = EXCLUDED.health_reason,
          metadata = EXCLUDED.metadata,
          discovered_at = COALESCE(EXCLUDED.discovered_at, machines.discovered_at),
          commissioned_at = COALESCE(EXCLUDED.commissioned_at, machines.commissioned_at),
          ready_at = EXCLUDED.ready_at,
          activated_at = EXCLUDED.activated_at,
          retired_at = EXCLUDED.retired_at,
          updated_at = NOW()
        RETURNING id
      `,
      [
        syncPayload.machine.hostname,
        syncPayload.machine.serial_number,
        siteId,
        rackId,
        skuId,
        syncPayload.machine.maas_system_id,
        syncPayload.machine.maas_zone,
        syncPayload.machine.maas_resource_pool,
        syncPayload.machine.maas_power_type,
        JSON.stringify(syncPayload.machine.maas_tags || []),
        JSON.stringify(syncPayload.machine.maas_annotations || {}),
        syncPayload.machine.bmc_address,
        syncPayload.machine.cpu_vendor,
        syncPayload.machine.cpu_model,
        syncPayload.machine.cpu_sockets,
        syncPayload.machine.cpu_cores_total,
        syncPayload.machine.ram_gb,
        syncPayload.machine.local_nvme_gb,
        syncPayload.machine.network_gbps,
        JSON.stringify(syncPayload.machine.numa_topology || {}),
        syncPayload.machine.nvlink_present,
        syncPayload.machine.infrastructure_state,
        syncPayload.machine.lease_state,
        syncPayload.machine.health_state,
        syncPayload.machine.sellability_state,
        syncPayload.machine.maintenance_state,
        syncPayload.machine.health_reason,
        JSON.stringify(syncPayload.machine.metadata || {}),
        syncPayload.machine.discovered_at || null,
        syncPayload.machine.commissioned_at || null,
        syncPayload.machine.ready_at || null,
        syncPayload.machine.activated_at || null,
        syncPayload.machine.retired_at || null
      ]
    );

    const machineId = machineUpsert.rows[0].id;

    await client.query("DELETE FROM gpu_devices WHERE machine_id = $1", [machineId]);

    for (const gpu of syncPayload.machine.gpus || []) {
      await client.query(
        `
          INSERT INTO gpu_devices (
            machine_id,
            slot_index,
            vendor,
            model,
            memory_gb,
            pci_bus_address,
            pcie_generation,
            pcie_link_width,
            serial_number,
            device_uuid,
            ecc_enabled,
            mig_capable,
            nvlink_group,
            health_state,
            metadata
          )
          VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14::health_state, $15::jsonb
          )
        `,
        [
          machineId,
          gpu.slot_index,
          gpu.vendor,
          gpu.model,
          gpu.memory_gb,
          gpu.pci_bus_address || null,
          gpu.pcie_generation ?? null,
          gpu.pcie_link_width ?? null,
          gpu.serial_number || null,
          gpu.device_uuid || null,
          gpu.ecc_enabled ?? null,
          gpu.mig_capable ?? false,
          gpu.nvlink_group || null,
          gpu.health_state || "unknown",
          JSON.stringify(gpu.metadata || {})
        ]
      );
    }

    await client.query(
      `
        INSERT INTO machine_state_transitions (
          machine_id,
          infrastructure_state,
          lease_state,
          health_state,
          sellability_state,
          maintenance_state,
          reason,
          source,
          metadata
        )
        VALUES ($1, $2::infrastructure_state, $3::lease_state, $4::health_state, $5::sellability_state, $6::maintenance_state, $7, $8, $9::jsonb)
      `,
      [
        machineId,
        syncPayload.machine.infrastructure_state,
        syncPayload.machine.lease_state,
        syncPayload.machine.health_state,
        syncPayload.machine.sellability_state,
        syncPayload.machine.maintenance_state,
        syncPayload.reason || null,
        syncPayload.source || "internal-maas-sync",
        JSON.stringify(buildStateHistoryMetadata(syncPayload))
      ]
    );

    const syncedMachine = await getMachineWithExecutor(client.query.bind(client), machineId);
    return {
      machine: syncedMachine,
      gpu_count: syncPayload.machine.gpus?.length || 0
    };
  });
}
