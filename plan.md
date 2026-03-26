# 1. Product strategy: define the service in layers

Do not start with “build a Vast.ai competitor.”
Start with a controlled progression of service layers:

## Layer 1 — Bare-metal fleet control

This is MAAS territory:

* discover servers
* commission hardware
* classify GPU nodes
* manage power/BMC
* deploy/redeploy images
* release and wipe machines
* allocate nodes to internal workflows

## Layer 2 — Rental control plane

This is your own platform:

* inventory catalog
* order flow
* reservation/lease lifecycle
* tenancy and RBAC
* machine allocation policy
* pricing, billing, metering
* support and abuse controls

## Layer 3 — Workload platform

This is where you start resembling Vast.ai:

* customer job environments
* Docker/container execution
* base images
* data volumes
* SSH/Jupyter endpoints
* optional Kubernetes or single-host schedulers
* GPU telemetry and limits
* job startup/teardown UX

## Layer 4 — Marketplace and advanced orchestration

Later:

* spot/preemptible inventory
* auction or dynamic pricing
* third-party capacity providers
* federated supply
* placement across sites/providers
* reputation, quality scoring, SLAs

That sequence matters. If you try to jump directly to Layer 3 or 4, you will create a control-plane mess.

---

# 2. Target end-state architecture

The clean architecture is:

### A. Infrastructure control plane

* **MAAS**
* BMC integration via Redfish/IPMI
* PXE/iPXE boot
* network and image deployment
* machine lifecycle and state transitions

### B. Fleet metadata and policy service

Your service that sits above MAAS and maintains:

* normalized machine catalog
* GPU model/family/topology
* health state
* sellable capacity state
* pricing class
* availability state
* maintenance state
* lease assignment state

### C. Provisioning orchestrator

A service that:

* watches order events
* selects eligible machine(s)
* calls MAAS API to allocate/deploy/release
* configures post-deploy bootstrap
* hands the node to the workload layer

### D. Workload bootstrap and runtime

Initially:

* cloud-init + systemd + Docker/Containerd
  Later:
* lightweight Kubernetes, Nomad, or your own job agent
* remote access services
* persistent volume handling
* runtime telemetry

### E. Commerce and tenancy plane

* customer accounts
* organizations/projects
* API keys
* quotas
* billing
* invoices
* usage metering

### F. Operations plane

* monitoring
* alerting
* GPU health
* ECC/XID errors
* thermal/power alerts
* support workflows
* audit trail
* abuse detection

---

# 3. What MAAS should own vs what your platform should own

This boundary needs to be explicit from day one.

## MAAS should own

* machine discovery
* commissioning
* BMC control
* rack/controller-level provisioning
* base network definitions
* OS/image deployment
* release/wipe cycle
* hardware grouping primitives
* machine state as infrastructure truth

## Your platform should own

* commercial inventory
* customer-facing inventory status
* lease lifecycle
* placement policy
* reservations
* image offerings visible to users
* user auth and tenancy
* billing/metering
* runtime access model
* health scoring
* scheduling workloads onto provisioned hosts

## MAAS should not become

* your billing engine
* your tenancy engine
* your marketplace engine
* your job scheduler
* your product catalog

That separation will save you a lot of pain later.

---

# 4. Delivery roadmap

I would structure this into **8 workstreams** and **4 delivery phases**.

---

## Phase 0 — Foundations and design freeze

### Objectives

* lock architecture boundaries
* define MVP scope
* standardize hardware onboarding
* define sellable SKUs

### Deliverables

1. **Product scope document**

   * dedicated bare-metal rentals only for MVP
   * no third-party marketplace at launch
   * no multi-tenant GPU sharing at launch
   * no spot/preemptible at launch unless absolutely required

2. **Machine SKU model**
   Every physical node needs a sellable SKU, for example:

   * `1x RTX 4090 / 24GB / 128GB RAM / 2TB NVMe / 10G`
   * `4x A100 80GB SXM / NVLink / 1TB RAM / 2x 3.84TB NVMe`
   * `8x H100 SXM / NVSwitch / 2TB RAM / 100G`

3. **State model**
   Standardize machine states across MAAS and your platform:

   * discovered
   * commissioning
   * ready
   * quarantined
   * reserved
   * deploying
   * active lease
   * draining
   * wiping
   * maintenance
   * broken
   * retired

4. **Service definition**
   Define:

   * billing granularity
   * minimum lease term
   * whether users get root
   * whether persistent storage survives redeploy
   * network model
   * support model
   * abuse thresholds

### Exit criteria

* architecture agreed
* MVP narrowed
* no ambiguity on who owns which state

---

## Phase 1 — MAAS fleet platform

This is the infrastructure baseline.

### Objectives

* stand up production MAAS
* onboard initial hardware
* prove repeatable provisioning
* standardize machine classification

MAAS supports lifecycle control, grouping, and API-based automation, and custom commissioning scripts can extend hardware detection and preparation. It also supports custom images built with Packer, which is relevant for CUDA-ready deployable templates. ([Canonical][2])

### Work packages

#### 1. MAAS deployment topology

Design:

* highly available region/rack controller layout where needed
* management network separation
* BMC network separation
* provisioning network design
* DHCP/DNS authority model
* upstream IPAM/DNS integration boundaries

#### 2. Hardware onboarding standard

For every server class, define:

* BIOS/UEFI baseline
* Secure Boot stance
* firmware update policy
* BMC config standard
* Redfish preferred where possible
* NIC naming standard
* disk layout standard

#### 3. Commissioning pipeline

Use MAAS commissioning plus custom scripts to detect and annotate:

* GPU count
* GPU model
* VRAM
* PCIe generation/width
* NVLink/NVSwitch presence
* local NVMe performance class
* RAM size
* NUMA topology
* NIC speed and count
* thermals/fan anomalies
* ECC/XID precheck status

Write all useful metadata back into:

* tags
* annotations
* your external inventory database

#### 4. Machine grouping strategy

Use MAAS grouping deliberately:

* **zones** = physical placement / site / rack corridor
* **resource pools** = ownership/quota domain
* **tags** = GPU family, NIC type, NVLink, storage class, customer class, maintenance flags

Canonical specifically documents tags, zones, and resource pools as the primary grouping tools, and recommends using them intentionally. ([Canonical][3])

#### 5. Image strategy

Create at least three base image families:

* **Ubuntu base**
* **CUDA runtime host**
* **CUDA + Docker host**

Do not expose dozens of variants initially. Keep it tight.

#### 6. Release and wipe standard

Define what happens when a lease ends:

* release in MAAS
* wipe policy
* credential rotation
* ephemeral disk sanitation
* data retention policy
* post-release health check
* return to ready pool only if passed

### Exit criteria

* machines can be commissioned and classified automatically
* tags/annotations are correct
* a node can go from new hardware to ready state without human improvisation
* redeploy/release cycle is repeatable

---

## Phase 2 — Internal orchestration layer

This is the most important piece after MAAS.

### Objectives

* create your system of record above MAAS
* make provisioning policy-driven
* stop relying on manual operator decisions

### Core components

#### 1. Fleet catalog service

A database-backed service storing:

* machine ID
* MAAS system ID
* BMC details reference
* site/zone/rack
* SKU
* GPU config
* networking profile
* health score
* lease state
* maintenance status
* customer assignment
* runtime agent status

#### 2. MAAS integration service

A thin integration boundary that:

* syncs machine inventory from MAAS
* translates MAAS states into product states
* triggers allocate/deploy/release actions
* subscribes to MAAS events if feasible
* shields the rest of your platform from MAAS-specific API semantics

This is critical. Do not let the whole platform talk directly to MAAS in an ad hoc way.

#### 3. Placement engine

Given an order request:

* match eligible SKU
* exclude unhealthy nodes
* enforce zone/site policy
* enforce redundancy policy
* respect network/storage requirements
* prefer lowest-fragmentation placement
* optionally price by desirability

#### 4. Provisioning workflow engine

Typical flow:

1. order accepted
2. choose node
3. reserve node in your DB
4. allocate in MAAS
5. deploy chosen image
6. bootstrap node agent
7. validate runtime readiness
8. attach lease metadata
9. expose access details to customer

#### 5. Reconciliation loops

You need controllers for:

* MAAS state drift
* broken deployment recovery
* stuck nodes
* nodes that fail post-deploy validation
* lease end handling
* maintenance drains

### Exit criteria

* all allocations run through APIs and workflows
* no manual MAAS clicks required for normal operations
* machine state in your DB and MAAS stays converged

---

## Phase 3 — Customer-facing bare-metal rental MVP

This is your first sellable product.

### Objectives

* launch dedicated GPU rentals
* no shared-host scheduler yet
* stable commercial workflows

### MVP features

#### 1. Customer identity and tenancy

* users
* orgs/projects
* API keys
* roles
* spending limits
* allowed regions/zones

#### 2. Inventory catalog

Expose:

* GPU model
* count
* VRAM
* CPU/RAM/storage
* network speed
* region/site
* pricing
* availability

#### 3. Order lifecycle

* create reservation
* deploy machine
* show progress
* active lease dashboard
* terminate/reinstall
* view credentials/access
* view usage and charges

#### 4. Network and access

MVP should support:

* public IP or VPN model
* SSH key injection
* serial console or rescue path
* firewall defaults
* customer-visible networking info

#### 5. Billing and metering

At bare minimum:

* per-hour or per-day lease accounting
* start/stop timestamps
* invoice generation
* prepaid balance or card-backed billing
* failed payment handling

#### 6. Operational controls

* maintenance mode
* node quarantine
* support notes
* abuse suspension
* hardware incident tracking

### Exit criteria

* a customer can rent a node end-to-end without operator intervention
* deployment success rate is acceptable
* support burden is not exploding

---

## Phase 4 — Container/job platform on top of leased capacity

Now you begin to simulate Vast.ai-style behavior.

### Important strategic choice

You need to decide whether the container layer is:

### Option A — Single-tenant host runtime

Each customer leases an entire host and then runs Docker workloads on it.

Pros:

* simplest
* closest to dedicated bare metal
* clean isolation
* fastest to launch

Cons:

* less cloud-like
* underutilization risk
* not true marketplace fragmentation

### Option B — Multi-job runtime on dedicated host

Customer leases a host through your platform, but your agent manages jobs/containers on it.

Pros:

* better UX
* controlled image lifecycle
* easier product expansion

Cons:

* more platform complexity
* runtime isolation/security harder

### Option C — Shared host / fractional GPU

This is where many teams get hurt.

Do **not** start here unless you already have:

* airtight isolation model
* MIG/vGPU/PCI passthrough strategy
* strong abuse containment
* advanced telemetry
* scheduler maturity

For your end product, I recommend:

* **MVP = Option A**
* **V2 = Option B**
* **fractional GPU only after the platform is operationally boring**

### Work packages

#### 1. Host bootstrap stack

After MAAS deploys the host:

* install/activate Docker or containerd
* install NVIDIA drivers/toolkit
* install node agent
* register host to your control plane
* validate GPU visibility and health

#### 2. Runtime agent

Per host agent should:

* report health
* receive job specs
* pull images
* run containers
* manage volumes
* manage SSH/Jupyter exposure
* stream logs
* terminate workloads
* wipe residual runtime state

#### 3. Image catalog

Start with a curated list:

* PyTorch CUDA
* TensorFlow CUDA
* JAX CUDA
* Ubuntu CUDA dev
* vLLM/TGI inference images
* base Jupyter stack

#### 4. Data and storage model

Decide early:

* ephemeral local NVMe only
* optional object storage
* optional persistent volumes
* upload/download path
* snapshot model or none

#### 5. User job model

Define whether a “job” is:

* one container
* one compose bundle
* one Jupyter instance
* one inference endpoint
* one SSH runtime

Avoid supporting everything at launch.

### Exit criteria

* workloads launch reliably on provisioned hosts
* runtime teardown leaves no customer residue
* telemetry is good enough to support billing and support

---

# 5. Cross-cutting workstreams

These run in parallel.

## A. Networking

This is a critical path, not a side issue.

You need separate models for:

* management network
* BMC network
* provisioning/PXE network
* customer data plane
* storage replication plane if any

Questions to settle:

* public IP direct on host or VPN ingress?
* customer VLAN per lease or shared?
* L2 adjacency or routed isolation?
* outbound anti-abuse controls?
* bandwidth metering?
* DDoS posture?

For MVP, keep networking conservative:

* routed design
* strongly controlled ingress
* minimal customer-controlled L2 features

## B. Security

Need hard standards for:

* secret handling
* BMC credential rotation
* SSH key injection
* image signing/trust
* tenant isolation
* audit logging
* abuse detection
* wipe/release verification

MAAS has its own security posture around access control and secret handling, but your overall platform security burden sits above it. ([Canonical][4])

## C. Observability

Track:

* machine lifecycle success/failure
* deploy latency
* node health
* GPU temps/power/utilization
* ECC/XID
* network throughput
* storage SMART/NVMe wear
* failed commissions
* failed releases
* customer job failures
* provisioning bottlenecks

## D. Reliability engineering

Define SLOs for:

* deploy success rate
* median deploy time
* lease start latency
* hardware incident response
* reclaim/release time
* runtime launch success
* support response class

## E. Finance and pricing

Before launch, define:

* list price by SKU
* regional uplift
* reserve capacity discount
* minimum billing increment
* idle host billing treatment
* failed deployment credit policy
* abuse/overage treatment

---

# 6. Recommended data model

You need a strong internal model early.

## Core entities

* Site
* Rack
* Machine
* GPU device
* SKU
* Image
* Network profile
* Lease
* Customer org
* User
* Runtime host agent
* Job
* Invoice line
* Incident
* Maintenance window

## Most important relationships

* Machine belongs to Site/Rack
* Machine maps to one MAAS system ID
* Machine resolves to one sellable SKU
* Lease binds customer to machine
* Job runs on leased machine or runtime host
* Image is deployable via MAAS and/or runtime
* Machine health influences sellability

Without this model, your platform turns into API glue and collapses under operational load.

---

# 7. Suggested tech decisions

These are not the only choices, but they are sane.

## Control plane

* backend: Go or Python
* relational DB: PostgreSQL
* message bus/workflows: NATS / RabbitMQ / Temporal / Celery depending on team preference
* cache: Redis
* API: REST first, maybe GraphQL later

## Infra automation

* Terraform for MAAS-managed infrastructure where practical, since Canonical provides a MAAS Terraform provider. ([Canonical][5])
* Ansible only for deterministic config that does not belong in images
* Packer for custom MAAS images, which Canonical documents directly. ([Canonical][6])

## Host runtime

* Docker initially for speed
* containerd later if you need tighter control
* lightweight node agent in Go or Rust
* NVIDIA Container Toolkit

## Frontend

* admin console first
* then customer portal
* then public catalog/ordering

---

# 8. Risks you should address now

## Risk 1 — treating MAAS as the whole platform

It is not. It is the infrastructure substrate.

## Risk 2 — too many SKUs

Too much variance kills automation. Normalize aggressively.

## Risk 3 — building shared GPU too early

Operational and security blast radius is much higher than people admit.

## Risk 4 — weak post-deploy validation

A node is not sellable just because MAAS deployed it.

## Risk 5 — state drift between systems

You need explicit reconciliation loops.

## Risk 6 — network design deferred too long

That always comes back and hurts margins and support.

## Risk 7 — image sprawl

Limit image families and support burden.

---

# 9. Recommended MVP scope

I would launch with this and nothing more:

### Product

* dedicated bare-metal GPU rentals
* hourly or daily billing
* Ubuntu-based CUDA-ready host images
* SSH access
* optional Docker preinstalled
* customer dashboard for deploy/reinstall/terminate
* no fractional GPUs
* no marketplace supply-side onboarding
* no complex persistent storage product

### Internal platform

* MAAS-backed provisioning
* placement engine
* lease manager
* billing/metering
* admin console
* basic health monitoring
* image pipeline
* runtime bootstrap hooks

That gets you a credible v1 without overcommitting.

---

# 10. Practical sequence of build execution

Here is the exact order I would use:

## Step 1

Design the **machine/SKU/state model**.

## Step 2

Stand up **production-grade MAAS** and onboard a small pilot fleet.

## Step 3

Build **custom commissioning scripts** for GPU and hardware characterization.

## Step 4

Establish **golden images** for Ubuntu + NVIDIA + Docker.

## Step 5

Build the **fleet catalog service** that syncs with MAAS.

## Step 6

Build the **provisioning orchestrator** with allocate/deploy/release workflows.

## Step 7

Build **admin operations console** before customer portal.

## Step 8

Build **customer tenancy + lease API**.

## Step 9

Launch **dedicated rentals**.

## Step 10

Add **runtime agent and container job orchestration** on dedicated hosts.

## Step 11

Only later evaluate **fractional GPU / marketplace / spot**.

---

# 11. What we should work through together next

The best way to proceed is to turn this into a structured build program and go one domain at a time.

The right first deep-dive is:

## **Step 1: machine model, SKU model, and lifecycle/state model**

That is the foundation for everything:

* how MAAS tags machines
* how your catalog represents them
* how allocation works
* how billing works
* how support works

If you skip that and jump into controllers or APIs, you will rework everything later.

So next I recommend I draft:
**a concrete schema for machines, GPUs, SKUs, and lease states**, including MAAS field mapping and the exact tags/annotations you should standardize from day one.

[1]: https://canonical.com/maas/docs?utm_source=chatgpt.com "MAAS documentation"
[2]: https://canonical.com/maas/docs/about-the-machine-life-cycle?utm_source=chatgpt.com "About the machine life-cycle - MAAS"
[3]: https://canonical.com/maas/docs/about-machine-groups?utm_source=chatgpt.com "About machine groups - MAAS"
[4]: https://canonical.com/maas/docs/about-maas-security?utm_source=chatgpt.com "About MAAS security"
[5]: https://canonical.com/maas/docs/reference-terraform?utm_source=chatgpt.com "Terraform reference"
[6]: https://canonical.com/maas/docs/how-to-build-custom-images?utm_source=chatgpt.com "How to build custom images - MAAS"
