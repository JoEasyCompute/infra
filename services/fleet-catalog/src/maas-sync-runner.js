import { fetchMachinesAndBuildSyncPayloads } from "./maas-integration.js";
import { syncMachineFromNormalizedPayload } from "./repository.js";
import { createPlacementResolver } from "./placement.js";

export async function runMaasSync(options = {}) {
  const placementResolver = options.placementResolver || createPlacementResolver(options.placementConfig);
  const payloads = await fetchMachinesAndBuildSyncPayloads(placementResolver, options.clientOptions || options);
  const syncFn = options.syncMachineFromNormalizedPayload || syncMachineFromNormalizedPayload;

  const results = [];
  for (const payload of payloads) {
    const result = await syncFn(payload);
    results.push({
      maas_system_id: payload.machine.maas_system_id,
      hostname: payload.machine.hostname,
      site_code: payload.site_code,
      rack_name: payload.rack_name || null,
      sku_code: payload.sku_code || null,
      gpu_count: result.gpu_count
    });
  }

  return {
    synced: results.length,
    results
  };
}
