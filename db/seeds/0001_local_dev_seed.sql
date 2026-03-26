INSERT INTO sites (id, code, name, region)
VALUES
    ('11111111-1111-1111-1111-111111111111', 'lon1', 'London 1', 'eu-west')
ON CONFLICT (code) DO UPDATE
SET
    name = EXCLUDED.name,
    region = EXCLUDED.region,
    updated_at = NOW();

INSERT INTO racks (id, site_id, name, rack_group)
VALUES
    ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'rack-a1', 'gpu-row-a')
ON CONFLICT (site_id, name) DO UPDATE
SET
    rack_group = EXCLUDED.rack_group,
    updated_at = NOW();

INSERT INTO skus (
    id,
    sku_code,
    display_name,
    gpu_vendor,
    gpu_model,
    gpu_count,
    gpu_memory_gb,
    cpu_model,
    cpu_cores,
    ram_gb,
    local_nvme_gb,
    network_gbps,
    interconnect,
    billing_mode,
    hourly_price_usd,
    metadata
)
VALUES
    (
        '33333333-3333-3333-3333-333333333333',
        'gpu-h100x8-2tb-15tb-100g',
        '8x H100 SXM / 2TB RAM / 15TB NVMe / 100G',
        'NVIDIA',
        'H100 SXM',
        8,
        80,
        'AMD EPYC 9654',
        192,
        2048,
        15360,
        100,
        'NVSwitch',
        'hourly',
        42.00,
        '{"tier":"premium","shared":false}'::jsonb
    ),
    (
        '33333333-3333-3333-3333-333333333334',
        'gpu-4090x1-128g-2tb-10g',
        '1x RTX 4090 / 128GB RAM / 2TB NVMe / 10G',
        'NVIDIA',
        'RTX 4090',
        1,
        24,
        'AMD Ryzen 7950X',
        16,
        128,
        2048,
        10,
        NULL,
        'hourly',
        1.95,
        '{"tier":"standard","shared":false}'::jsonb
    )
ON CONFLICT (sku_code) DO UPDATE
SET
    display_name = EXCLUDED.display_name,
    gpu_vendor = EXCLUDED.gpu_vendor,
    gpu_model = EXCLUDED.gpu_model,
    gpu_count = EXCLUDED.gpu_count,
    gpu_memory_gb = EXCLUDED.gpu_memory_gb,
    cpu_model = EXCLUDED.cpu_model,
    cpu_cores = EXCLUDED.cpu_cores,
    ram_gb = EXCLUDED.ram_gb,
    local_nvme_gb = EXCLUDED.local_nvme_gb,
    network_gbps = EXCLUDED.network_gbps,
    interconnect = EXCLUDED.interconnect,
    billing_mode = EXCLUDED.billing_mode,
    hourly_price_usd = EXCLUDED.hourly_price_usd,
    metadata = EXCLUDED.metadata,
    updated_at = NOW();

INSERT INTO images (
    id,
    image_code,
    display_name,
    os_family,
    os_version,
    cuda_version,
    docker_enabled,
    maas_image_ref
)
VALUES
    (
        '44444444-4444-4444-4444-444444444444',
        'ubuntu-22-04-cuda-12-docker',
        'Ubuntu 22.04 CUDA 12 Docker',
        'ubuntu',
        '22.04',
        '12.4',
        TRUE,
        'ubuntu/jammy-cuda-docker'
    )
ON CONFLICT (image_code) DO UPDATE
SET
    display_name = EXCLUDED.display_name,
    os_family = EXCLUDED.os_family,
    os_version = EXCLUDED.os_version,
    cuda_version = EXCLUDED.cuda_version,
    docker_enabled = EXCLUDED.docker_enabled,
    maas_image_ref = EXCLUDED.maas_image_ref,
    updated_at = NOW();

INSERT INTO customer_orgs (id, org_code, display_name, billing_email)
VALUES
    (
        '55555555-5555-5555-5555-555555555555',
        'internal-lab',
        'Internal Lab',
        'lab@example.com'
    )
ON CONFLICT (org_code) DO UPDATE
SET
    display_name = EXCLUDED.display_name,
    billing_email = EXCLUDED.billing_email,
    updated_at = NOW();

INSERT INTO machines (
    id,
    hostname,
    serial_number,
    site_id,
    rack_id,
    sku_id,
    maas_system_id,
    maas_zone,
    maas_resource_pool,
    maas_power_type,
    maas_tags,
    maas_annotations,
    bmc_address,
    cpu_vendor,
    cpu_model,
    cpu_sockets,
    cpu_cores_total,
    ram_gb,
    local_nvme_gb,
    network_gbps,
    numa_topology,
    nvlink_present,
    infrastructure_state,
    lease_state,
    health_state,
    sellability_state,
    maintenance_state,
    health_reason,
    discovered_at,
    commissioned_at,
    ready_at,
    metadata
)
VALUES
    (
        '66666666-6666-6666-6666-666666666666',
        'gpu-h100-01',
        'H100-SERIAL-0001',
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333333',
        'maas-h100-01',
        'lon-a',
        'retail',
        'redfish',
        '["h100","nvswitch","100g"]'::jsonb,
        '{"gpu_family":"hopper","topology":"nvswitch"}'::jsonb,
        '10.0.10.11',
        'AMD',
        'EPYC 9654',
        2,
        192,
        2048,
        15360,
        100,
        '{"nodes":2}'::jsonb,
        TRUE,
        'ready',
        'none',
        'healthy',
        'sellable',
        'none',
        NULL,
        NOW() - INTERVAL '2 days',
        NOW() - INTERVAL '2 days',
        NOW() - INTERVAL '1 day',
        '{"source":"local-seed"}'::jsonb
    ),
    (
        '66666666-6666-6666-6666-666666666667',
        'gpu-4090-01',
        '4090-SERIAL-0001',
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333334',
        'maas-4090-01',
        'lon-b',
        'retail',
        'ipmi',
        '["4090","10g"]'::jsonb,
        '{"gpu_family":"ada"}'::jsonb,
        '10.0.10.21',
        'AMD',
        'Ryzen 7950X',
        1,
        16,
        128,
        2048,
        10,
        '{"nodes":1}'::jsonb,
        FALSE,
        'maintenance',
        'none',
        'healthy',
        'internal_only',
        'scheduled',
        'Awaiting fan replacement',
        NOW() - INTERVAL '5 days',
        NOW() - INTERVAL '5 days',
        NULL,
        '{"source":"local-seed"}'::jsonb
    )
ON CONFLICT (hostname) DO UPDATE
SET
    serial_number = EXCLUDED.serial_number,
    site_id = EXCLUDED.site_id,
    rack_id = EXCLUDED.rack_id,
    sku_id = EXCLUDED.sku_id,
    maas_system_id = EXCLUDED.maas_system_id,
    maas_zone = EXCLUDED.maas_zone,
    maas_resource_pool = EXCLUDED.maas_resource_pool,
    maas_power_type = EXCLUDED.maas_power_type,
    maas_tags = EXCLUDED.maas_tags,
    maas_annotations = EXCLUDED.maas_annotations,
    bmc_address = EXCLUDED.bmc_address,
    cpu_vendor = EXCLUDED.cpu_vendor,
    cpu_model = EXCLUDED.cpu_model,
    cpu_sockets = EXCLUDED.cpu_sockets,
    cpu_cores_total = EXCLUDED.cpu_cores_total,
    ram_gb = EXCLUDED.ram_gb,
    local_nvme_gb = EXCLUDED.local_nvme_gb,
    network_gbps = EXCLUDED.network_gbps,
    numa_topology = EXCLUDED.numa_topology,
    nvlink_present = EXCLUDED.nvlink_present,
    infrastructure_state = EXCLUDED.infrastructure_state,
    lease_state = EXCLUDED.lease_state,
    health_state = EXCLUDED.health_state,
    sellability_state = EXCLUDED.sellability_state,
    maintenance_state = EXCLUDED.maintenance_state,
    health_reason = EXCLUDED.health_reason,
    discovered_at = EXCLUDED.discovered_at,
    commissioned_at = EXCLUDED.commissioned_at,
    ready_at = EXCLUDED.ready_at,
    metadata = EXCLUDED.metadata,
    updated_at = NOW();

DELETE FROM gpu_devices
WHERE machine_id IN (
    '66666666-6666-6666-6666-666666666666',
    '66666666-6666-6666-6666-666666666667'
);

INSERT INTO gpu_devices (
    id,
    machine_id,
    slot_index,
    vendor,
    model,
    memory_gb,
    pci_bus_address,
    pcie_generation,
    pcie_link_width,
    serial_number,
    device_uuid,
    ecc_enabled,
    mig_capable,
    nvlink_group,
    health_state,
    metadata
)
VALUES
    ('77777777-7777-7777-7777-777777777770', '66666666-6666-6666-6666-666666666666', 0, 'NVIDIA', 'H100 SXM', 80, '0000:81:00.0', 5, 16, 'H100-GPU-000', 'GPU-H100-000', TRUE, TRUE, 'fabric-a', 'healthy', '{"source":"local-seed"}'::jsonb),
    ('77777777-7777-7777-7777-777777777771', '66666666-6666-6666-6666-666666666666', 1, 'NVIDIA', 'H100 SXM', 80, '0000:82:00.0', 5, 16, 'H100-GPU-001', 'GPU-H100-001', TRUE, TRUE, 'fabric-a', 'healthy', '{"source":"local-seed"}'::jsonb),
    ('77777777-7777-7777-7777-777777777772', '66666666-6666-6666-6666-666666666666', 2, 'NVIDIA', 'H100 SXM', 80, '0000:83:00.0', 5, 16, 'H100-GPU-002', 'GPU-H100-002', TRUE, TRUE, 'fabric-a', 'healthy', '{"source":"local-seed"}'::jsonb),
    ('77777777-7777-7777-7777-777777777773', '66666666-6666-6666-6666-666666666666', 3, 'NVIDIA', 'H100 SXM', 80, '0000:84:00.0', 5, 16, 'H100-GPU-003', 'GPU-H100-003', TRUE, TRUE, 'fabric-a', 'healthy', '{"source":"local-seed"}'::jsonb),
    ('77777777-7777-7777-7777-777777777774', '66666666-6666-6666-6666-666666666666', 4, 'NVIDIA', 'H100 SXM', 80, '0000:85:00.0', 5, 16, 'H100-GPU-004', 'GPU-H100-004', TRUE, TRUE, 'fabric-b', 'healthy', '{"source":"local-seed"}'::jsonb),
    ('77777777-7777-7777-7777-777777777775', '66666666-6666-6666-6666-666666666666', 5, 'NVIDIA', 'H100 SXM', 80, '0000:86:00.0', 5, 16, 'H100-GPU-005', 'GPU-H100-005', TRUE, TRUE, 'fabric-b', 'healthy', '{"source":"local-seed"}'::jsonb),
    ('77777777-7777-7777-7777-777777777776', '66666666-6666-6666-6666-666666666666', 6, 'NVIDIA', 'H100 SXM', 80, '0000:87:00.0', 5, 16, 'H100-GPU-006', 'GPU-H100-006', TRUE, TRUE, 'fabric-b', 'healthy', '{"source":"local-seed"}'::jsonb),
    ('77777777-7777-7777-7777-777777777777', '66666666-6666-6666-6666-666666666666', 7, 'NVIDIA', 'H100 SXM', 80, '0000:88:00.0', 5, 16, 'H100-GPU-007', 'GPU-H100-007', TRUE, TRUE, 'fabric-b', 'healthy', '{"source":"local-seed"}'::jsonb),
    ('77777777-7777-7777-7777-777777777778', '66666666-6666-6666-6666-666666666667', 0, 'NVIDIA', 'RTX 4090', 24, '0000:21:00.0', 4, 16, '4090-GPU-000', 'GPU-4090-000', FALSE, FALSE, NULL, 'healthy', '{"source":"local-seed"}'::jsonb)
ON CONFLICT (device_uuid) DO UPDATE
SET
    machine_id = EXCLUDED.machine_id,
    slot_index = EXCLUDED.slot_index,
    vendor = EXCLUDED.vendor,
    model = EXCLUDED.model,
    memory_gb = EXCLUDED.memory_gb,
    pci_bus_address = EXCLUDED.pci_bus_address,
    pcie_generation = EXCLUDED.pcie_generation,
    pcie_link_width = EXCLUDED.pcie_link_width,
    serial_number = EXCLUDED.serial_number,
    ecc_enabled = EXCLUDED.ecc_enabled,
    mig_capable = EXCLUDED.mig_capable,
    nvlink_group = EXCLUDED.nvlink_group,
    health_state = EXCLUDED.health_state,
    metadata = EXCLUDED.metadata,
    updated_at = NOW();
