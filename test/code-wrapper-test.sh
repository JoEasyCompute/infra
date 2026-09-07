#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d /tmp/code-wrapper-test.XXXXXX)"
trap 'rm -rf "$tmp_dir"' EXIT
cp "$ROOT_DIR/test/code.sh" "$tmp_dir/code.sh"

# A deployment must include its source even if an old binary is cached.
mkdir -p "$tmp_dir/build"
printf '#!/usr/bin/env bash\necho stale-binary-ran\n' > "$tmp_dir/build/code"
chmod +x "$tmp_dir/build/code"
printf 'arch=native\n' > "$tmp_dir/build/code.nvcc.sig"
if output=$(bash "$tmp_dir/code.sh" 1 0 2>&1); then
    echo "FAIL: wrapper accepted a deployment without code.cu" >&2
    exit 1
fi
if [[ "$output" != *"CUDA source file not found or not readable:"* ]]; then
    echo "FAIL: missing source was not diagnosed before CUDA setup: $output" >&2
    exit 1
fi
[[ "$output" != *stale-binary-ran* ]] || exit 1
bash "$tmp_dir/code.sh" --help >/dev/null
echo "CUDA wrapper deployment tests passed"
