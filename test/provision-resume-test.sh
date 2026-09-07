#!/usr/bin/env bash
# Run copied orchestrators with temporary paths and mocked host commands only.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT_DIR" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
failures = []

def check(condition, message):
    if not condition:
        raise AssertionError(message)

with tempfile.TemporaryDirectory(prefix="provision-resume-test-") as temp:
    workspace = Path(temp)
    mocks = workspace / "bin"
    mocks.mkdir()
    mock = mocks / "mock"
    mock.write_text('''#!/usr/bin/env python3
import os, pathlib, stat, sys
name = pathlib.Path(sys.argv[0]).name
node = pathlib.Path(os.environ["TEST_NODE"])
if name == "stat":
    info = pathlib.Path(sys.argv[-1]).stat()
    print("0:" + oct(stat.S_IMODE(info.st_mode))[2:])
elif name == "sed" and sys.argv[1] == "-i":
    path = pathlib.Path(sys.argv[-1])
    prefix = sys.argv[2][2:-3]
    path.write_text("".join(line for line in path.read_text().splitlines(True) if not line.startswith(prefix)))
elif name == "sed":
    os.execv("/usr/bin/sed", ["sed"] + sys.argv[1:])
elif name == "reboot":
    (node / "rebooted").touch()
elif name == "rocm-smi" and not (node / "rebooted").exists():
    sys.exit(1)
elif name == "mountpoint":
    args = node / "docker.args"
    sys.exit(0 if args.exists() and "--runpod-storage-layout" in args.read_text() else 1)
elif name == "findmnt":
    print("/var/lib/docker/containerd")
elif name == "df":
    print("Filesystem Size Used Avail Use% Mounted\\ntest 10G 1G 9G 10% /test")
elif name == "nvidia-smi":
    print("test-driver")
''')
    mock.chmod(0o755)
    for name in ("stat", "sed", "reboot", "sleep", "systemctl", "nvidia-smi", "rocm-smi", "rocminfo", "rocm-bandwidth-test", "mountpoint", "findmnt", "df", "docker", "xfs_info", "lsmod"):
        (mocks / name).symlink_to(mock)

    def fixture(kind, label):
        node = workspace / (kind + "-" + label)
        node.mkdir()
        systemd = node / "systemd"
        systemd.mkdir()
        script_name = "provision" + ("-amd" if kind == "amd" else "") + ".sh"
        source = (root / "install" / script_name).read_text()
        source = source.replace("/opt/provision-amd" if kind == "amd" else "/opt/provision", str(node))
        source = source.replace("/etc/systemd/system", str(systemd))
        source = source.replace("$EUID -ne 0", "$EUID -ne " + str(os.geteuid()))
        script = node / script_name
        script.write_text(source)
        for name, label in (("amd-base-install.sh" if kind == "amd" else "base-install.sh", "base"), ("docker-install.sh", "docker"), ("fulltest.sh", "fulltest"), ("code.sh", "code")):
            path = node / name
            path.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$TEST_NODE/' + label + '.args"\n')
            path.chmod(0o755)
        (node / "code.cu").write_text("// fixture\n")
        return node, script

    def run(node, script, *args, ok=True):
        result = subprocess.run(["bash", str(script), *args], env={**os.environ, "PATH": str(mocks) + ":/usr/bin:/bin", "TEST_NODE": str(node)}, capture_output=True, text=True)
        check((result.returncode == 0) == ok, "unexpected exit " + str(result.returncode) + "\n" + result.stdout + result.stderr)
        return result.stdout + result.stderr

    def scenario(kind):
        node, script = fixture(kind, "resume")
        run(node, script, "--non-interactive", "--disk", "/dev/nvme2n1", "--vg", "gpu-vg", "--with-compose", "--runpod-storage-layout", "--freeze-gpu-stack")
        config = node / "state/provision.config"
        check(config.exists(), "provision options were not saved before reboot")
        check(not (node / "docker.args").exists(), "stage2 ran after reboot was requested")
        check(config.stat().st_mode & 0o777 == 0o600, "config permissions must be 600")
        check(config.parent.stat().st_mode & 0o777 == 0o700, "state directory permissions must be 700")
        run(node, script, "--resume", "--non-interactive")
        args = (node / "docker.args").read_text().splitlines()
        for arg in ("--disk", "/dev/nvme2n1", "--vg", "gpu-vg", "--with-compose", "--runpod-storage-layout"):
            check(arg in args, "resume lost " + arg)
        check((node / "state/.provision_complete").exists(), "resume did not complete")
        before = config.read_bytes()
        run(node, script, "--status", "--disk", "/dev/ignored")
        check(config.read_bytes() == before, "status changed saved config")
        (node / "state/provision.state").write_text("")
        run(node, script, "--resume", "--disk", "/dev/nvme3n1", "--unfreeze-gpu-stack")
        check("--unfreeze-gpu-stack" in (node / "base.args").read_text(), "explicit unfreeze did not override saved freeze")
        check("--freeze-gpu-stack\n" not in (node / "base.args").read_text(), "saved freeze conflicts with explicit unfreeze")
        run(node, script, "--resume", "--non-interactive")
        check("/dev/nvme3n1" in (node / "docker.args").read_text(), "override did not persist")
        run(node, script, "--reset-state", "--non-interactive")
        run(node, script, "--resume", "--non-interactive")
        check("--disk" not in (node / "docker.args").read_text(), "reset retained old disk")
        config.write_text("WITH_COMPOSE=$(touch " + str(node / "injected") + ")\n")
        run(node, script, "--resume", ok=False)
        check(not (node / "injected").exists(), "config executed shell code")
        run(node, script, "--status")
        run(node, script, "--reset-state", "--non-interactive")
        config.chmod(0o644)
        run(node, script, "--resume", ok=False)
        config.unlink()
        run(node, script, "--resume", "--non-interactive")
        check(config.exists(), "legacy state without config did not migrate")
        run(node, script, "--disk", "--with-compose", ok=False)

    def preflight():
        for missing in ("code.sh", "code.cu"):
            node, script = fixture("nvidia", "missing-" + missing)
            (node / missing).unlink()
            output = run(node, script, "--non-interactive", ok=False)
            check(missing in output, "preflight did not identify " + missing)
            check(not (node / "base.args").exists(), "base installation started without " + missing)
        node, script = fixture("nvidia", "nonexecutable-code")
        (node / "code.sh").chmod(0o644)
        run(node, script, "--non-interactive", ok=False)
        check(not (node / "base.args").exists(), "base installation started with nonexecutable code.sh")

    for name, test in (("NVIDIA resume lifecycle", lambda: scenario("nvidia")), ("AMD resume lifecycle", lambda: scenario("amd")), ("CUDA preflight", preflight)):
        try:
            test()
            print("PASS: " + name)
        except AssertionError as error:
            failures.append(name)
            print("FAIL: " + name + ": " + str(error), file=sys.stderr)
if failures:
    sys.exit(1)
PY
