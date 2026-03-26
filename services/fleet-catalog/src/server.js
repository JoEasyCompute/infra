import { createApp } from "./app.js";
import { getConfig } from "./config.js";

const config = getConfig();
const app = createApp();

app.listen(config.port, config.host, () => {
  console.log(`${config.serviceName} listening on ${config.host}:${config.port}`);
  console.log(
    `[startup] database target host=${config.databaseDebug.host} port=${config.databaseDebug.port} db=${config.databaseDebug.database} source=${config.databaseDebug.source}`
  );
});
