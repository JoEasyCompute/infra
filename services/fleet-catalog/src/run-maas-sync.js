import { runMaasSync } from "./maas-sync-runner.js";

try {
  const result = await runMaasSync();
  console.log(JSON.stringify(result, null, 2));
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
}
