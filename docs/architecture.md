# Architecture Baseline

This repository starts from a strict separation of concerns:

## MAAS owns infrastructure truth

MAAS is responsible for:

* hardware discovery
* commissioning
* BMC/power control
* image deployment
* release and wipe flows
* infrastructure-oriented grouping

## EZC Platform owns product truth

The platform is responsible for:

* sellable machine catalog
* SKU definitions
* lease lifecycle
* placement policy
* customer tenancy
* billing and metering
* runtime bootstrap and later job execution

## Monorepo structure

### `db/`

PostgreSQL schema, migrations, and future seed data for the control plane.

### `services/fleet-catalog`

System-of-record service for normalized machine metadata, MAAS sync, and health/sellability state.

Current implemented responsibilities:

* read machine inventory from PostgreSQL
* expose machine detail with GPU inventory
* normalize MAAS-derived payloads into platform state fields
* sync normalized machine/GPU payloads into PostgreSQL
* append machine state transition history

### `services/provisioning-orchestrator`

Workflow service for allocate, deploy, validate, release, and reconciliation flows.

### `services/lease-api`

Customer/admin-facing lease management API.

### `packages/domain`

Shared domain contracts, enums, and state transition logic.

### `infra/`

Terraform, image pipeline assets, bootstrap scripts, and environment definitions.

## Delivery sequence

1. lock domain model and schema
2. implement fleet catalog + MAAS integration
3. implement provisioning workflows
4. implement admin operations surfaces
5. implement tenancy and lease APIs

## Development topology

For local development:

* run PostgreSQL in Docker on the application machine
* run Node.js services directly on the application machine
* run MAAS on a separate host or VM

This preserves the boundary between application services and the infrastructure control plane.
