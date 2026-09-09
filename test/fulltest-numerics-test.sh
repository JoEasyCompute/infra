#!/usr/bin/env bash
# CPU-only regression checks; no provisioning, CUDA, or third-party dependencies.
set -euo pipefail
FULLTEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fulltest.sh"
export FULLTEST
python3 - <<'PY'
import ast
import math
import os
from pathlib import Path
import subprocess
import tempfile

text = Path(os.environ['FULLTEST']).read_text()
assert 'test_numerics() {' in text, 'numerics test function missing'
function = text.split('test_numerics() {', 1)[1].split('\ntest_cuda_code()', 1)[0]
script = function.split("<< 'PYEOF'\n", 1)[1].split('\nPYEOF', 1)[0]
# Execute the real dependency-free scalar validator, not a copied implementation.
tree = ast.parse(script)
ns = {'math': math}
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'validate_values'], type_ignores=[]), '<validator>', 'exec'), ns)
validate = ns['validate_values']
assert validate([0., 2.], [0., 2.], 1e-5, 1e-4)[2]
assert validate([1e-6], [0.], 1e-5, 1e-4)[2]
assert not validate([0.1], [0.], 1e-5, 1e-4)[2]
assert not validate([0., 0.], [1., -1.], 1e-5, 1e-4)[2]
# Known 2x2 product with cancellation and a near-zero entry; a transposed
# result must fail even though it has the same values and overall norm.
assert validate([0., 5., -2., 11.], [0., 5., -2., 11.], 2e-5, 2e-5)[2]
assert not validate([0., -2., 5., 11.], [0., 5., -2., 11.], 2e-5, 2e-5)[2]
for value in [math.nan, math.inf, -math.inf]:
    assert not validate([value], [0.], 1e-5, 1e-4)[2]
    assert not validate([0.], [value], 1e-5, 1e-4)[2]
with tempfile.TemporaryDirectory() as tmp:
    for prepare, run, expected in [(2, 0, 0), (1, 0, 1), (0, 0, 0), (0, 7, 7)]:
        (Path(tmp) / 'bin').mkdir(exist_ok=True)
        runner = Path(tmp) / 'bin' / 'python'
        runner.write_text('#!/bin/sh\ntest -s "$1" || exit 99\necho "script=$1"\necho invoked\nexit ' + str(run) + '\n')
        runner.chmod(0o755)
        harness = 'test_numerics() {' + function + '\n'
        harness += f'''\nprepare_pytorch_runtime() {{ return {prepare}; }}
record_not_run() {{ echo NOT_RUN; }}
log() {{ echo "$*"; }}
PYTORCH_RUNTIME_SKIP_REASON=missing
PYTORCH_VENV='{tmp}'
LOG_FILE='{tmp}/log'
test_numerics
'''
        result = subprocess.run(['bash', '-c', harness], capture_output=True, text=True)
        assert result.returncode == expected, result
        assert ('NOT_RUN' in result.stdout) == (prepare == 2), result
        assert ('invoked' in result.stdout) == (prepare == 0), result
        for line in result.stdout.splitlines():
            if line.startswith('script='):
                assert not Path(line.split('=', 1)[1]).exists(), 'temporary script leaked'
print('PASS: numerics validator and runtime routing')
PY
