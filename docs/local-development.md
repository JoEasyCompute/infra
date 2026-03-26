# Local Development

This repository uses a split local-development model:

* PostgreSQL runs locally in Docker Compose
* platform services run locally on the host machine
* MAAS runs on a separate host or VM

## Why MAAS is separate

MAAS is not treated as a local container dependency because it owns:

* DHCP and PXE flows
* machine commissioning and deployment
* BMC and power control
* infrastructure network behavior

Those concerns should stay isolated from the machine running the platform application services.

## Start PostgreSQL

From the repo root:

```bash
cp .env.example .env
docker compose up -d postgres
```

The container initializes the schema from [db/migrations/0001_initial_schema.sql](/Users/josephcheung/Desktop/dev/ezc-platfrom/db/migrations/0001_initial_schema.sql) on first boot.

Shared connection settings live in the repo-root `.env`:

* `POSTGRES_HOST`
* `POSTGRES_PORT`
* `POSTGRES_DB`
* `POSTGRES_USER`
* `POSTGRES_PASSWORD`
* `FLEET_CATALOG_HOST`
* `FLEET_CATALOG_PORT`

## Run fleet-catalog

From [services/fleet-catalog](/Users/josephcheung/Desktop/dev/ezc-platfrom/services/fleet-catalog):

```bash
npm install
cp .env.example .env
npm start
```

Default `DATABASE_URL`:

```text
postgresql://postgres:postgres@localhost:65432/ezc_platform
```

`fleet-catalog` loads the repo-root `.env` automatically and builds `DATABASE_URL` from `POSTGRES_*` values unless you override `DATABASE_URL` in `services/fleet-catalog/.env`.

The listen port resolves from `FLEET_CATALOG_PORT` in the repo-root `.env`. You can still override it locally with `PORT` in `services/fleet-catalog/.env` if needed.
The bind host resolves from `FLEET_CATALOG_HOST` in the repo-root `.env`. You can still override it locally with `HOST` in `services/fleet-catalog/.env` if needed.

`npm run dev` is still available, but `npm start` is the more reliable local path if file-watch limits are tight on the host.

## Load local seed data

From the repo root:

```bash
docker exec -i ezc-postgres psql -U postgres -d ezc_platform < db/seeds/0001_local_dev_seed.sql
```

This seed adds:

* one site
* one rack
* two SKUs
* one image
* one internal customer org
* two machines
* nine GPU inventory records

## Current internal sync path

`fleet-catalog` now supports a local-write verification path without a live MAAS host:

* `POST /api/v1/internal/maas/normalize`
* `POST /api/v1/internal/maas/sync`

The sync endpoint expects:

* `site_code`
* optional `rack_name`
* optional `sku_code`
* `machine` containing normalized machine and GPU fields

The write path:

* upserts a machine by `maas_system_id`
* replaces GPU inventory for that machine
* appends a row to `machine_state_transitions`

## Fixture-driven MAAS adapter

Before a live MAAS host is connected, the raw MAAS adapter can be exercised with fixture files under [services/fleet-catalog/test/fixtures](/Users/josephcheung/Desktop/dev/ezc-platfrom/services/fleet-catalog/test/fixtures).

Run adapter and sync-related tests with:

```bash
node --test services/fleet-catalog/test/*.test.js
```

For live MAAS integration later, create `services/fleet-catalog/config/maas-placement.json` from the example file and run:

```bash
cd services/fleet-catalog
npm run sync:maas
```

## Expected topology

Minimal working layout:

* machine 1: this repo, local Node.js services, local Docker Postgres
* machine 2: MAAS host or VM
* machine 3+: managed bare-metal nodes provisioned by MAAS

The application services should integrate with MAAS over its API and event surface, not by colocating MAAS on the same machine.
