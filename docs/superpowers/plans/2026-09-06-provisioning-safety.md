# Provisioning safety fixes implementation plan

**Goal:** Correct the five install/test review findings, update affected operator documentation, verify, commit, and push.

**Approach:** Keep shell-first workflows and existing command interfaces. Reproduce bugs with host commands mocked in temporary directories; never format, mount, reboot, or stress this development host. No new dependencies.

- [x] Storage selection (`install/docker-install.sh`): reproduce selection of a signed whole disk and ignored `--vg`; reject occupied/signed devices and honour explicit disk/VG choices; test safe candidates and rejected choices.
- [x] Storage conversion (`install/docker-storage-layout-convert.sh`): reproduce reverse conversion moving data outside its filesystem; move Docker children within the mounted volume before remounting; verify data placement and collisions with temporary fixtures.
- [x] Reboot resume (`install/provision.sh`, `install/provision-amd.sh`): reproduce lost options; persist validated settings with restricted permissions, restore before building stage arguments, define reset/status behavior; test both orchestrators without host mutations.
- [x] Network result (`test/network-test.sh`): reproduce failed iperf with successful client result; propagate bandwidth/stress failures to exit status and JSON completion; test success, failure, and optional bidirectional behavior.
- [x] CUDA deployment (`test/code.sh`, provisioning preflight, README and relevant docs): reproduce missing source; require code.sh and code.cu before provisioning; include source in every deployment example.
- [x] Documentation: reconcile README, Docker install/conversion, provisioning, fulltest, and network guides with implemented behavior and regression commands.
- [x] Verification: run focused new tests, all existing regression suites, syntax checks and network helper help; review full diff; commit all intended files and push current branch to origin; verify remote commit.
