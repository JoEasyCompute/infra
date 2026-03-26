import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const serviceRoot = path.resolve(__dirname, "..");

function loadPlacementConfig() {
  const placementPath =
    process.env.FLEET_CATALOG_PLACEMENT_FILE ||
    path.join(serviceRoot, "config", "maas-placement.json");

  if (!fs.existsSync(placementPath)) {
    throw new Error(`placement file not found: ${placementPath}`);
  }

  return JSON.parse(fs.readFileSync(placementPath, "utf8"));
}

export function createPlacementResolver(config = loadPlacementConfig()) {
  const systems = config.systems || {};
  const zones = config.zones || {};
  const defaultPlacement = config.default || null;

  return async function resolvePlacement(machine) {
    if (machine.system_id && systems[machine.system_id]) {
      return systems[machine.system_id];
    }

    const zoneName = machine.zone?.name || machine.zone || null;
    if (zoneName && zones[zoneName]) {
      return zones[zoneName];
    }

    return defaultPlacement;
  };
}
