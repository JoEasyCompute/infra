import { Pool } from "pg";

import { getConfig } from "./config.js";

const config = getConfig();

export const pool = new Pool({
  connectionString: config.databaseUrl
});

export async function query(text, params) {
  return pool.query(text, params);
}

export async function checkDatabaseConnection() {
  const result = await pool.query("select 1 as ok");
  return result.rows[0]?.ok === 1;
}

export async function withTransaction(callback) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await callback(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
}
