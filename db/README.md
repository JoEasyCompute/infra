# Database

PostgreSQL is the initial source of truth for control-plane state.

## Contents

* `migrations/` - ordered SQL migrations
* `seeds/` - deterministic local development seed data

## Current status

The first migration establishes the foundational inventory and lease model:

* sites and racks
* SKUs
* machines
* GPU devices
* images
* customers and users
* leases
* machine state transition history

## Local development seed

Use [0001_local_dev_seed.sql](/Users/josephcheung/Desktop/dev/ezc-platfrom/db/seeds/0001_local_dev_seed.sql) to load a small inventory dataset for local development and API verification.

The current `fleet-catalog` sync path writes against this schema by:

* upserting `machines` by `maas_system_id`
* replacing `gpu_devices` for the synced machine
* appending `machine_state_transitions`
