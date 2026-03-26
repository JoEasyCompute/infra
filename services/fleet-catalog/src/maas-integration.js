import { buildSyncPayloadFromMaasMachine } from "./maas-adapter.js";
import { createMaasClient } from "./maas-client.js";

export async function fetchMachineAndBuildSyncPayload(systemId, placement, options = {}) {
  const client = options.client || createMaasClient(options);
  const machine = await client.getMachine(systemId);
  return buildSyncPayloadFromMaasMachine(machine, placement);
}

export async function fetchMachinesAndBuildSyncPayloads(placementResolver, options = {}) {
  const client = options.client || createMaasClient(options);
  const machines = await client.listMachines();

  const payloads = [];
  for (const machine of machines) {
    const placement = await placementResolver(machine);
    if (!placement) {
      continue;
    }

    payloads.push(buildSyncPayloadFromMaasMachine(machine, placement));
  }

  return payloads;
}
