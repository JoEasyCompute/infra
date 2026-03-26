# Domain Model

This document defines the first-pass schema for machines, GPUs, SKUs, and leases.

## Design principles

* infrastructure state and commercial state are separate
* MAAS identifiers are preserved but isolated behind platform tables
* a machine resolves to exactly one current SKU
* every sellability decision is explainable from health, maintenance, and lease data
* state changes are append-only in history tables even if current state is denormalized on the main row

## Core entities

### Site

Physical datacenter or availability location.

Key fields:

* `code`
* `name`
* `region`

### Rack

Physical rack or placement grouping inside a site.

Key fields:

* `site_id`
* `name`
* `rack_group`

### SKU

The productized shape a machine can be sold as.

Key fields:

* `sku_code`
* `gpu_model`
* `gpu_count`
* `gpu_memory_gb`
* `cpu_model`
* `cpu_cores`
* `ram_gb`
* `local_nvme_gb`
* `network_gbps`
* `interconnect`
* `billing_mode`
* `hourly_price_usd`

Notes:

* SKU is a commercial abstraction, not raw discovery output.
* Multiple machines can map to one SKU if they are operationally equivalent.

### Machine

Canonical representation of a physical host.

Key fields:

* `hostname`
* `site_id`
* `rack_id`
* `sku_id`
* `maas_system_id`
* `maas_resource_pool`
* `maas_zone`
* `bmc_address`
* `cpu_model`
* `cpu_sockets`
* `cpu_cores_total`
* `ram_gb`
* `local_nvme_gb`
* `network_gbps`
* `nvlink_present`
* `infrastructure_state`
* `lease_state`
* `health_state`
* `sellability_state`
* `maintenance_state`

State split:

* `infrastructure_state` tracks hardware/provisioning lifecycle
* `lease_state` tracks reservation and customer occupancy
* `health_state` tracks operational safety
* `sellability_state` is the commercial outcome

### GPU Device

Per-device inventory tied to a machine.

Key fields:

* `machine_id`
* `slot_index`
* `vendor`
* `model`
* `memory_gb`
* `pcie_generation`
* `pcie_link_width`
* `serial_number`
* `uuid`
* `ecc_enabled`
* `mig_capable`
* `nvlink_group`

### Lease

A customer reservation or active rental against a machine.

Key fields:

* `lease_number`
* `machine_id`
* `customer_org_id`
* `state`
* `reserved_at`
* `started_at`
* `ended_at`
* `billing_started_at`
* `billing_ended_at`
* `image_id`

## State model

### Infrastructure state

Allowed values:

* `discovered`
* `commissioning`
* `ready`
* `reserved`
* `deploying`
* `active`
* `draining`
* `releasing`
* `wiping`
* `maintenance`
* `quarantined`
* `broken`
* `retired`

### Lease state

Allowed values:

* `none`
* `pending`
* `reserved`
* `provisioning`
* `active`
* `terminating`
* `terminated`
* `failed`

### Health state

Allowed values:

* `unknown`
* `healthy`
* `degraded`
* `failed`

### Sellability state

Allowed values:

* `not_sellable`
* `internal_only`
* `sellable`

### Maintenance state

Allowed values:

* `none`
* `scheduled`
* `in_progress`

## MAAS mapping

The platform keeps MAAS fields as source references, not as domain truth:

* `maas_system_id` maps the machine to MAAS
* `maas_zone` informs placement constraints
* `maas_resource_pool` informs ownership/quota boundaries
* MAAS tags and annotations are copied into JSONB for traceability

The fleet catalog service should translate MAAS lifecycle states into the platform's `infrastructure_state`.

## Internal sync contract

The current `fleet-catalog` write path does not require a live MAAS host. It accepts a normalized internal payload and applies it transactionally to PostgreSQL.

Required placement context:

* `site_code`

Optional placement/commercial context:

* `rack_name`
* `sku_code`

Machine sync behavior:

* upsert machine by `maas_system_id`
* replace all GPU records for that machine
* append a `machine_state_transitions` row

This keeps MAAS-specific API handling in a thin adapter layer while preserving a stable internal contract for the catalog service.

## Transition rules

Examples:

* A machine cannot be `sellable` if `health_state != healthy`.
* A machine cannot be `sellable` if `maintenance_state != none`.
* A machine cannot move to `active` infrastructure state unless lease state is at least `provisioning`.
* A machine in `broken` or `retired` cannot accept new leases.

See the initial SQL migration for concrete enums and constraints.
