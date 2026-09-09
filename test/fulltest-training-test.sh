#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 - "$SCRIPT_DIR/fulltest.sh" <<'PY'
import ast
import importlib.util
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
function = source.split("test_pytorch() {", 1)[1]
payload = function.split("<< 'PYEOF'\n", 1)[1].split("\nPYEOF", 1)[0]
tree = ast.parse(payload)
calls = [ast.unparse(node.func) for node in ast.walk(tree) if isinstance(node, ast.Call)]
for call in ("loss.backward", "optimizer.step", "optimizer.zero_grad", "dist.broadcast",
             "dist.all_reduce", "torch.isfinite", "torch.allclose"):
    assert call in calls, f"Missing training/synchronization contract: {call}"
assert payload.index("torch.cuda.set_device") < payload.index("dist.init_process_group")
assert "timeout=timedelta(seconds=120)" in payload
assert "parameter.grad is None" in payload
assert "parameters did not update" in payload
assert "gradients differ from rank 0" in payload
assert "parameters differ from rank 0" in payload
assert "range(5)" in payload
print("PASS: training, finite-value, rank agreement, device ordering and timeout contracts")

if importlib.util.find_spec("torch") is None:
    print("SKIP: CPU/Gloo execution (PyTorch unavailable); AST checks do not verify tensor behavior")
    sys.exit(0)

# Adapt only the device/backend so the production payload is exercised on CPU.
cpu = payload.replace("torch.cuda.set_device(local_rank)", "pass")
cpu = cpu.replace('device = torch.device(f"cuda:{local_rank}")', 'device = torch.device("cpu")')
cpu = cpu.replace('backend="nccl"', 'backend="gloo"')
cpu = cpu.replace("device_ids=[local_rank]", "device_ids=None")
cpu = cpu.replace("torch.cuda.synchronize()", "pass")
cases = {
    "training": (cpu, True, "training completed"),
    "missing backward": (cpu.replace("loss.backward()", "pass"), False, "missing or non-finite gradients"),
    "NaN loss": (cpu.replace("loss = criterion(model(x), target)",
                             'loss = criterion(model(x), target) * float("nan")'), False, "non-finite loss"),
    "rank divergence": (cpu.replace("optimizer.step()", "optimizer.step()\n        if rank == 1:\n            with torch.no_grad():\n                next(model.parameters()).add_(1.0)"), False, "parameters differ from rank 0"),
    "missing optimizer update": (cpu.replace("optimizer.step()", "pass"), False, "parameters did not update"),
}
with tempfile.TemporaryDirectory(prefix="fulltest-training-") as directory:
    for name, (code, expected_success, diagnostic) in cases.items():
        script = pathlib.Path(directory) / "payload.py"
        script.write_text(code)
        result = subprocess.run([sys.executable, "-m", "torch.distributed.run", "--standalone",
                                 "--nproc_per_node=2", str(script)], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        assert (result.returncode == 0) == expected_success, f"{name}: {result.stdout}"
        assert diagnostic in result.stdout, f"{name}: missing diagnostic: {result.stdout}"
        print(f"PASS: CPU/Gloo {name}")
PY
