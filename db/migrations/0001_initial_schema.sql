CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE billing_mode AS ENUM (
    'hourly',
    'daily',
    'monthly'
);

CREATE TYPE infrastructure_state AS ENUM (
    'discovered',
    'commissioning',
    'ready',
    'reserved',
    'deploying',
    'active',
    'draining',
    'releasing',
    'wiping',
    'maintenance',
    'quarantined',
    'broken',
    'retired'
);

CREATE TYPE lease_state AS ENUM (
    'none',
    'pending',
    'reserved',
    'provisioning',
    'active',
    'terminating',
    'terminated',
    'failed'
);

CREATE TYPE health_state AS ENUM (
    'unknown',
    'healthy',
    'degraded',
    'failed'
);

CREATE TYPE sellability_state AS ENUM (
    'not_sellable',
    'internal_only',
    'sellable'
);

CREATE TYPE maintenance_state AS ENUM (
    'none',
    'scheduled',
    'in_progress'
);

CREATE TABLE sites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    region TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE racks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    site_id UUID NOT NULL REFERENCES sites(id),
    name TEXT NOT NULL,
    rack_group TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (site_id, name)
);

CREATE TABLE skus (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sku_code TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    gpu_vendor TEXT NOT NULL,
    gpu_model TEXT NOT NULL,
    gpu_count INTEGER NOT NULL CHECK (gpu_count > 0),
    gpu_memory_gb INTEGER NOT NULL CHECK (gpu_memory_gb > 0),
    cpu_model TEXT NOT NULL,
    cpu_cores INTEGER NOT NULL CHECK (cpu_cores > 0),
    ram_gb INTEGER NOT NULL CHECK (ram_gb > 0),
    local_nvme_gb INTEGER NOT NULL CHECK (local_nvme_gb >= 0),
    network_gbps INTEGER NOT NULL CHECK (network_gbps > 0),
    interconnect TEXT,
    billing_mode billing_mode NOT NULL DEFAULT 'hourly',
    hourly_price_usd NUMERIC(10,2),
    daily_price_usd NUMERIC(10,2),
    monthly_price_usd NUMERIC(10,2),
    active BOOLEAN NOT NULL DEFAULT TRUE,
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        hourly_price_usd IS NOT NULL
        OR daily_price_usd IS NOT NULL
        OR monthly_price_usd IS NOT NULL
    )
);

CREATE TABLE images (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    image_code TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    os_family TEXT NOT NULL,
    os_version TEXT NOT NULL,
    cuda_version TEXT,
    docker_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    maas_image_ref TEXT,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE customer_orgs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_code TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    billing_email TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE platform_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_org_id UUID REFERENCES customer_orgs(id),
    email TEXT NOT NULL UNIQUE,
    full_name TEXT,
    role_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE machines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hostname TEXT NOT NULL UNIQUE,
    serial_number TEXT UNIQUE,
    site_id UUID NOT NULL REFERENCES sites(id),
    rack_id UUID REFERENCES racks(id),
    sku_id UUID REFERENCES skus(id),
    maas_system_id TEXT NOT NULL UNIQUE,
    maas_zone TEXT,
    maas_resource_pool TEXT,
    maas_power_type TEXT,
    maas_tags JSONB NOT NULL DEFAULT '[]'::JSONB,
    maas_annotations JSONB NOT NULL DEFAULT '{}'::JSONB,
    bmc_address INET,
    cpu_vendor TEXT,
    cpu_model TEXT NOT NULL,
    cpu_sockets INTEGER NOT NULL DEFAULT 1 CHECK (cpu_sockets > 0),
    cpu_cores_total INTEGER NOT NULL CHECK (cpu_cores_total > 0),
    ram_gb INTEGER NOT NULL CHECK (ram_gb > 0),
    local_nvme_gb INTEGER NOT NULL DEFAULT 0 CHECK (local_nvme_gb >= 0),
    network_gbps INTEGER NOT NULL DEFAULT 1 CHECK (network_gbps > 0),
    numa_topology JSONB NOT NULL DEFAULT '{}'::JSONB,
    nvlink_present BOOLEAN NOT NULL DEFAULT FALSE,
    infrastructure_state infrastructure_state NOT NULL DEFAULT 'discovered',
    lease_state lease_state NOT NULL DEFAULT 'none',
    health_state health_state NOT NULL DEFAULT 'unknown',
    sellability_state sellability_state NOT NULL DEFAULT 'not_sellable',
    maintenance_state maintenance_state NOT NULL DEFAULT 'none',
    health_reason TEXT,
    current_lease_id UUID,
    discovered_at TIMESTAMPTZ,
    commissioned_at TIMESTAMPTZ,
    ready_at TIMESTAMPTZ,
    activated_at TIMESTAMPTZ,
    retired_at TIMESTAMPTZ,
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        sellability_state <> 'sellable'
        OR (
            health_state = 'healthy'
            AND maintenance_state = 'none'
            AND infrastructure_state = 'ready'
            AND lease_state = 'none'
        )
    )
);

CREATE TABLE gpu_devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    machine_id UUID NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
    slot_index INTEGER NOT NULL CHECK (slot_index >= 0),
    vendor TEXT NOT NULL,
    model TEXT NOT NULL,
    memory_gb INTEGER NOT NULL CHECK (memory_gb > 0),
    pci_bus_address TEXT,
    pcie_generation INTEGER CHECK (pcie_generation > 0),
    pcie_link_width INTEGER CHECK (pcie_link_width > 0),
    serial_number TEXT,
    device_uuid TEXT,
    ecc_enabled BOOLEAN,
    mig_capable BOOLEAN NOT NULL DEFAULT FALSE,
    nvlink_group TEXT,
    health_state health_state NOT NULL DEFAULT 'unknown',
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (machine_id, slot_index),
    UNIQUE (device_uuid)
);

CREATE TABLE leases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lease_number TEXT NOT NULL UNIQUE,
    machine_id UUID NOT NULL REFERENCES machines(id),
    customer_org_id UUID NOT NULL REFERENCES customer_orgs(id),
    requested_by_user_id UUID REFERENCES platform_users(id),
    image_id UUID REFERENCES images(id),
    state lease_state NOT NULL DEFAULT 'pending',
    reservation_token TEXT UNIQUE,
    reserved_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    billing_started_at TIMESTAMPTZ,
    billing_ended_at TIMESTAMPTZ,
    hourly_rate_usd NUMERIC(10,2),
    notes TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        state <> 'active'
        OR started_at IS NOT NULL
    )
);

ALTER TABLE machines
ADD CONSTRAINT machines_current_lease_id_fkey
FOREIGN KEY (current_lease_id) REFERENCES leases(id);

CREATE TABLE machine_state_transitions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    machine_id UUID NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
    infrastructure_state infrastructure_state,
    lease_state lease_state,
    health_state health_state,
    sellability_state sellability_state,
    maintenance_state maintenance_state,
    reason TEXT,
    source TEXT NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    CHECK (
        infrastructure_state IS NOT NULL
        OR lease_state IS NOT NULL
        OR health_state IS NOT NULL
        OR sellability_state IS NOT NULL
        OR maintenance_state IS NOT NULL
    )
);

CREATE INDEX idx_machines_site_id ON machines(site_id);
CREATE INDEX idx_machines_sku_id ON machines(sku_id);
CREATE INDEX idx_machines_infrastructure_state ON machines(infrastructure_state);
CREATE INDEX idx_machines_sellability_state ON machines(sellability_state);
CREATE INDEX idx_gpu_devices_machine_id ON gpu_devices(machine_id);
CREATE INDEX idx_leases_machine_id ON leases(machine_id);
CREATE INDEX idx_leases_customer_org_id ON leases(customer_org_id);
CREATE INDEX idx_machine_state_transitions_machine_id ON machine_state_transitions(machine_id);
