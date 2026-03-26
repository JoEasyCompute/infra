# EZC Platform

Foundational monorepo scaffold for a MAAS-backed GPU bare-metal rental platform.

## Repository Layout

* `docs/` - architecture, domain model, and state model documentation
* `db/` - PostgreSQL schema and migrations
* `services/` - control-plane services
* `packages/` - shared libraries and contracts
* `infra/` - infrastructure definitions and image/bootstrap assets

## Initial Focus

The first implementation milestone is the platform's core domain model:

* machine inventory
* GPU inventory
* sellable SKU definitions
* lifecycle and lease states
* MAAS field mapping

See [docs/architecture.md](docs/architecture.md), [docs/domain-model.md](docs/domain-model.md), and [db/migrations/0001_initial_schema.sql](db/migrations/0001_initial_schema.sql).

## First service

The first runnable service is [services/fleet-catalog](services/fleet-catalog), a Node.js service that:

* lists normalized machine inventory from PostgreSQL
* exposes machine detail records with GPU inventory
* normalizes raw MAAS machine payloads into platform state fields
* upserts normalized machine and GPU inventory into PostgreSQL
* records machine state transitions during sync
* provides a fixture-driven MAAS adapter layer ahead of live MAAS integration
* includes a manual MAAS sync runner with placement-map-based resolution

## Local development

Local development is split intentionally:

* `PostgreSQL` runs via [docker-compose.yml](/Users/josephcheung/Desktop/dev/ezc-platfrom/docker-compose.yml)
* platform services run directly on the host machine
* `MAAS` runs on a separate host or VM

Shared Postgres defaults live in [`.env.example`](/Users/josephcheung/Desktop/dev/ezc-platfrom/.env.example) at the repo root.
Service-level shared defaults such as `FLEET_CATALOG_HOST` and `FLEET_CATALOG_PORT` also live there.

See [docs/local-development.md](/Users/josephcheung/Desktop/dev/ezc-platfrom/docs/local-development.md).
