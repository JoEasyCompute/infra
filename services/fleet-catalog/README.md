# Fleet Catalog Service

System-of-record service for normalized machine inventory.

## Current scope

* expose health and machine inventory endpoints
* normalize MAAS payloads into platform inventory/state fields
* centralize sellability derivation rules
* upsert normalized machine and GPU inventory into PostgreSQL
* provide a fixture-driven MAAS adapter boundary for later live integration
* provide a thin MAAS client layer for live fetch integration

## Planned responsibilities

* sync inventory and lifecycle data from MAAS
* normalize raw hardware facts into machine and GPU records
* derive health and sellability state
* expose inventory queries to other services

## Run

From the repo root:

```bash
cp .env.example .env
docker compose up -d postgres
```

From `services/fleet-catalog`:

```bash
cd services/fleet-catalog
npm install
cp .env.example .env
npm start
```

The API expects a PostgreSQL database reachable through `DATABASE_URL`.

The service reads shared `POSTGRES_*` values from the repo-root `.env` and derives `DATABASE_URL` automatically unless you override `DATABASE_URL` in `services/fleet-catalog/.env`.
The bind host resolves from `FLEET_CATALOG_HOST` in the repo-root `.env`, with optional service-local override via `HOST`.
The listen port resolves from `FLEET_CATALOG_PORT` in the repo-root `.env`, with optional service-local override via `PORT`.

On startup, the service logs the resolved database host, port, database name, and config source. `/healthz` also performs a live database connectivity check.

## Internal sync contract

`POST /api/v1/internal/maas/sync` accepts a normalized machine payload plus local placement context:

* `site_code` is required
* `rack_name` is optional
* `sku_code` is optional
* `machine` contains the normalized MAAS-derived machine and GPU fields

The sync path:

* upserts the machine by `maas_system_id`
* replaces GPU inventory for that machine
* records a row in `machine_state_transitions`

## MAAS adapter boundary

`src/maas-adapter.js` is the raw-MAAS-facing layer.

It is responsible for:

* accepting raw MAAS-style machine payloads
* extracting CPU, memory, network, storage, power, and GPU facts
* translating them into the normalized internal sync contract

This keeps MAAS-specific response handling separate from the catalog write path.

## MAAS client boundary

`src/maas-client.js` is the live fetch layer.

It is responsible for:

* authenticating to MAAS using `MAAS_API_KEY`
* fetching raw machine JSON from the MAAS API
* returning raw MAAS responses without applying DB writes

`src/maas-integration.js` bridges the live client to the adapter layer by:

* fetching one or more MAAS machines
* applying platform-owned placement context
* building normalized sync payloads for the existing write path

## MAAS sync runner

`src/maas-sync-runner.js` performs a batch sync by:

* fetching raw machines from MAAS
* resolving placement from a platform-owned placement map
* building normalized sync payloads
* calling the existing transactional write path

The default placement map file is `config/maas-placement.json`.
Use [maas-placement.example.json](/Users/josephcheung/Desktop/dev/ezc-platfrom/services/fleet-catalog/config/maas-placement.example.json) as the starting point.

Run the manual sync with:

```bash
cd services/fleet-catalog
npm run sync:maas
```
