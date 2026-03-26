import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../../..");

dotenv.config({ path: path.join(repoRoot, ".env") });
dotenv.config({ path: path.resolve(__dirname, "..", ".env"), override: true });

function buildDatabaseUrl() {
  const host = process.env.POSTGRES_HOST || "localhost";
  const port = process.env.POSTGRES_PORT || "65432";
  const database = process.env.POSTGRES_DB || "ezc_platform";
  const user = process.env.POSTGRES_USER || "postgres";
  const password = process.env.POSTGRES_PASSWORD || "postgres";

  return `postgresql://${user}:${password}@${host}:${port}/${database}`;
}

function getDatabaseDebug() {
  const databaseUrl = process.env.DATABASE_URL || buildDatabaseUrl();
  const parsed = new URL(databaseUrl);

  return {
    host: parsed.hostname,
    port: parsed.port || "5432",
    database: parsed.pathname.replace(/^\//, ""),
    user: decodeURIComponent(parsed.username || ""),
    source: process.env.DATABASE_URL ? "DATABASE_URL" : "POSTGRES_*"
  };
}

export function getConfig() {
  return {
    serviceName: process.env.SERVICE_NAME || "fleet-catalog",
    host: process.env.HOST || process.env.FLEET_CATALOG_HOST || "127.0.0.1",
    port: Number.parseInt(process.env.PORT || process.env.FLEET_CATALOG_PORT || "3000", 10),
    apiPrefix: process.env.API_PREFIX || "/api/v1",
    databaseUrl: process.env.DATABASE_URL || buildDatabaseUrl(),
    databaseDebug: getDatabaseDebug()
  };
}
