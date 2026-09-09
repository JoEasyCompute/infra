#!/usr/bin/env bash
# Hardware-free validation of load-cycle runtime and inventory checks.
set -euo pipefail
export FULLTEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fulltest.sh"
python3 - <<'PY'
import ast
import os
from pathlib import Path
import subprocess
import tempfile
import types
import contextlib
import io
import sys
import re
source = Path(os.environ['FULLTEST']).read_text()
assert 'test_load_cycles() {' in source, 'load-cycle function missing'
function = 'test_load_cycles() {' + source.split('test_load_cycles() {', 1)[1].split('\ntest_gpu_policy()', 1)[0]
script = function.split("<<'PYLOAD'\n", 1)[1].split('\nPYLOAD', 1)[0]
ast.parse(script)
scan_nodes = [n for n in ast.parse(script).body if isinstance(n, ast.FunctionDef) and n.name in ('kernel_scan', 'pci_addresses')]
scan_ns = {'re': re, 'subprocess': subprocess, 'started': 100,
           'selected_bdfs': {(0, 101, 0)}, 'expected': ['GPU-a']}
exec(compile(ast.Module(body=scan_nodes, type_ignores=[]), '<kernel-scan>', 'exec'), scan_ns)
for journal, fails, remark in [
    ('NVRM: Xid (PCI:0000:65:00): 79, GPU has fallen off the bus', True, False),
    ('NVRM: Xid (PCI:00000000:65:00): 79', True, False),
    ('NVRM: Xid (PCI:0000:66:00): 79', False, False),
    ('nvidia 0000:65:00.0: PCIe Bus Error: severity=Uncorrected (Fatal)', True, False),
    ('nvidia 0000:66:00.0: AER: severity=Fatal', False, False),
    ('nvidia 0000:65:00.0: PCIe Bus Error: severity=Uncorrected (Non-Fatal)', False, False),
    ('NVRM: GPU has fallen off the bus', False, True),
    ('NVRM: Xid GPU-a 79', True, False),
    ('PCIe fatal error with no address', False, True),
]:
    original = subprocess.run
    subprocess.run = lambda *a, **k: types.SimpleNamespace(returncode=0, stdout=journal, stderr='')
    failed = False
    try:
        with contextlib.redirect_stdout(io.StringIO()) as output:
            try: scan_ns['kernel_scan']()
            except RuntimeError: failed = True
        assert failed == fails, (journal, failed)
        assert ('REMARK:' in output.getvalue()) == remark, (journal, output.getvalue())
    finally:
        subprocess.run = original
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / 'bin').mkdir()
    runner = root / 'bin/python'
    for prepare, child, option, expected in [(2,0,'',0),(1,0,'',1),(0,0,'',0),(0,7,'',7),(0,124,'',124),(0,0,'GPU_LOAD_CYCLES=0',1),(0,0,'GPU_LOAD_SECONDS=301',1),(0,0,'GPU_LOAD_IDLE_SECONDS=abc',1)]:
        runner.write_text('#!/bin/sh\ntest -s "$2" || exit 99\necho invoked\nexit '+str(child)+'\n')
        runner.chmod(0o755)
        harness = function + f'''
prepare_pytorch_runtime() {{ return {prepare}; }}
record_not_run() {{ echo NOT_RUN; }}
record_remark() {{ echo REMARK "$*"; }}
log() {{ echo "$*"; }}
timeout() {{ shift 2; "$@"; }}
PYTORCH_RUNTIME_SKIP_REASON=missing
PYTORCH_VENV='{root}'
LOG_FILE='{root}/log'
SMI_FILTER=''
{option}
test_load_cycles
'''
        result = subprocess.run(['bash','-c',harness],capture_output=True,text=True)
        assert result.returncode == expected, (prepare, child, option, result)
        assert ('NOT_RUN' in result.stdout) == (prepare == 2), result
    # Execute the actual inventory comparison with mocked driver output.
    tree = ast.parse(script)
    selected = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'snapshot']
    ns = {'subprocess': subprocess, 'smi_args': [], 'print': lambda *a, **k: None}
    exec(compile(ast.Module(body=selected, type_ignores=[]), '<snapshot>', 'exec'), ns)
    class Result:
        stdout = 'GPU-a\nGPU-b\n'
    original = subprocess.run
    subprocess.run = lambda *a, **k: Result()
    try:
        assert ns['snapshot']('initial') == ['GPU-a', 'GPU-b']
        ns['snapshot']('unchanged', ['GPU-a', 'GPU-b'])
        Result.stdout = 'GPU-a\n'
        try:
            ns['snapshot']('missing', ['GPU-a', 'GPU-b'])
        except RuntimeError:
            pass
        else:
            raise AssertionError('missing selected GPU accepted')
    finally:
        subprocess.run = original
    # Run the real Python payload with a fake CUDA runtime, clock and journal.
    calls = []
    class Tensor:
        def clone(self): return self
        def all(self): return self
        def item(self): return True
    ticks = iter(range(1000))
    clock = types.SimpleNamespace(time=lambda: 100, monotonic=lambda: next(ticks), sleep=lambda seconds: None)
    cuda = types.SimpleNamespace(is_available=lambda: True, device_count=lambda: 2,
        device=lambda index: contextlib.nullcontext(), synchronize=lambda index: calls.append(('sync', index)))
    fake_torch = types.SimpleNamespace(cuda=cuda, float32='float32',
        backends=types.SimpleNamespace(cuda=types.SimpleNamespace(matmul=types.SimpleNamespace(allow_tf32=True))),
        full=lambda *a, **k: Tensor(), empty_like=lambda a: Tensor(),
        mm=lambda *a, **k: calls.append(('launch', None)), isfinite=lambda out: out)
    def command(args, **kwargs):
        assert kwargs['timeout'] in (10, 15)
        stdout = ''
        if args[0] == 'nvidia-smi':
            stdout = '00000000:65:00.0\n00000000:66:00.0\n' if '--query-gpu=pci.bus_id' in args else 'GPU-a\nGPU-b\n'
        return types.SimpleNamespace(returncode=0, stdout=stdout, stderr='')
    originals = {name: sys.modules.get(name) for name in ('torch', 'time', 'subprocess')}
    old_argv = sys.argv
    try:
        sys.modules.update(torch=fake_torch, time=clock, subprocess=types.SimpleNamespace(
            run=command, TimeoutExpired=subprocess.TimeoutExpired))
        # Fake clock reaches the deadline before the first loop check.
        sys.argv = ['payload', '1', '1', '1', '-i 0,1']
        with contextlib.redirect_stdout(io.StringIO()) as output:
            exec(compile(script, '<load-cycle>', 'exec'), {})
        assert 'Completed 1 idle/load cycles' in output.getvalue()
        assert calls[2:6] == [('launch', None), ('launch', None), ('sync', 0), ('sync', 1)], calls
    finally:
        sys.argv = old_argv
        for name, module in originals.items():
            if module is None: sys.modules.pop(name, None)
            else: sys.modules[name] = module
print('PASS: load-cycle options, runtime routing, failure/timeout propagation, inventory, selected kernel events, nonfatal exclusions and Python syntax')
PY
