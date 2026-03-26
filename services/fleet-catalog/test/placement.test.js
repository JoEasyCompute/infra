import test from "node:test";
import assert from "node:assert/strict";

import { createPlacementResolver } from "../src/placement.js";

test("createPlacementResolver prefers system-specific mappings over zone mappings", async () => {
  const resolvePlacement = createPlacementResolver({
    systems: {
      "maas-01": {
        site_code: "lon1",
        rack_name: "rack-a1",
        sku_code: "gpu-h100x8-2tb-15tb-100g"
      }
    },
    zones: {
      "lon-a": {
        site_code: "lon1",
        rack_name: "rack-z1"
      }
    }
  });

  const placement = await resolvePlacement({
    system_id: "maas-01",
    zone: { name: "lon-a" }
  });

  assert.deepEqual(placement, {
    site_code: "lon1",
    rack_name: "rack-a1",
    sku_code: "gpu-h100x8-2tb-15tb-100g"
  });
});

test("createPlacementResolver falls back to zone and then default mapping", async () => {
  const resolvePlacement = createPlacementResolver({
    systems: {},
    zones: {
      "lon-a": {
        site_code: "lon1",
        rack_name: "rack-a1"
      }
    },
    default: {
      site_code: "lon1"
    }
  });

  const zonePlacement = await resolvePlacement({
    system_id: "maas-zone",
    zone: { name: "lon-a" }
  });
  const defaultPlacement = await resolvePlacement({
    system_id: "maas-default",
    zone: { name: "unknown" }
  });

  assert.deepEqual(zonePlacement, {
    site_code: "lon1",
    rack_name: "rack-a1"
  });
  assert.deepEqual(defaultPlacement, {
    site_code: "lon1"
  });
});
