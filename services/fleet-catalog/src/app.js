import express from "express";

import { getConfig } from "./config.js";
import { checkDatabaseConnection } from "./db.js";
import { normalizeMaasMachine } from "./maas.js";
import { getMachine, listMachines, syncMachineFromNormalizedPayload } from "./repository.js";
import { validateSyncRequest } from "./sync.js";

const config = getConfig();

export function createApp() {
  const app = express();
  app.use(express.json());

  app.get("/healthz", async (_req, res) => {
    try {
      const databaseOk = await checkDatabaseConnection();
      res.json({
        service: config.serviceName,
        status: databaseOk ? "ok" : "degraded",
        database: {
          status: databaseOk ? "ok" : "degraded",
          host: config.databaseDebug.host,
          port: config.databaseDebug.port,
          database: config.databaseDebug.database
        }
      });
    } catch (error) {
      res.status(503).json({
        service: config.serviceName,
        status: "degraded",
        database: {
          status: "unreachable",
          host: config.databaseDebug.host,
          port: config.databaseDebug.port,
          database: config.databaseDebug.database
        },
        detail: error instanceof Error ? error.message : "unknown error"
      });
    }
  });

  app.get(`${config.apiPrefix}/machines`, async (_req, res, next) => {
    try {
      const machines = await listMachines();
      res.json(machines);
    } catch (error) {
      next(error);
    }
  });

  app.get(`${config.apiPrefix}/machines/:machineId`, async (req, res, next) => {
    try {
      const machine = await getMachine(req.params.machineId);
      if (!machine) {
        res.status(404).json({ error: "machine not found" });
        return;
      }

      res.json(machine);
    } catch (error) {
      next(error);
    }
  });

  app.post(`${config.apiPrefix}/internal/maas/normalize`, (req, res, next) => {
    try {
      const normalized = normalizeMaasMachine(req.body);
      res.json(normalized);
    } catch (error) {
      next(error);
    }
  });

  app.post(`${config.apiPrefix}/internal/maas/sync`, async (req, res, next) => {
    try {
      const errors = validateSyncRequest(req.body);
      if (errors.length > 0) {
        res.status(400).json({
          error: "invalid sync request",
          details: errors
        });
        return;
      }

      const result = await syncMachineFromNormalizedPayload(req.body);
      res.status(200).json({
        status: "ok",
        machine: result.machine,
        gpu_count: result.gpu_count
      });
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("unknown ")) {
        res.status(400).json({
          error: "invalid sync request",
          detail: error.message
        });
        return;
      }

      next(error);
    }
  });

  app.use((error, _req, res, _next) => {
    res.status(500).json({
      error: "internal server error",
      detail: error instanceof Error ? error.message : "unknown error"
    });
  });

  return app;
}
