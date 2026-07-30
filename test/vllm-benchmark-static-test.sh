#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/test/vllm-benchmark-test.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local text="$1"
    local expected="$2"
    grep -Fq -- "$expected" <<<"$text" \
        || fail "missing expected text: $expected"
}

test_help_and_safe_dry_run() {
    local tmp_dir="$1"
    local help_output dry_run_output

    help_output="$(bash "$SCRIPT" --help)"
    for option in \
        --profile --backend --model --model-revision --vllm-image --gpus --tp-size --port \
        --max-model-len --tool-call-parser --reasoning-parser --dataset --agent \
        --harbor-parser --temperature --top-p --task-cpus --task-memory-mb \
        --n-concurrent --startup-timeout --output-dir --smoke --dry-run \
        --no-pull --keep-server
    do
        require_text "$help_output" "$option"
    done
    require_text "$help_output" "auto, nvidia, or amd (default: auto)"

    dry_run_output="$(
        HF_TOKEN="do-not-print-this-token" \
            bash "$SCRIPT" \
                --backend nvidia \
                --dry-run \
                --gpus 0,1 \
                --tp-size 2 \
                --output-dir "$tmp_dir/dry-run-output"
    )"

    require_text "$dry_run_output" "Profile: ornith-35b-practical"
    require_text "$dry_run_output" "Profile modified: false"
    require_text "$dry_run_output" "vllm/vllm-openai:v"
    require_text "$dry_run_output" "deepreinforce-ai/Ornith-1.0-35B"
    require_text "$dry_run_output" "127.0.0.1:"
    require_text "$dry_run_output" "--gpus \\\"device=0\\,1\\\""
    require_text "$dry_run_output" "--tensor-parallel-size 2"
    require_text "$dry_run_output" "--max-model-len 16384"
    require_text "$dry_run_output" "--revision"
    require_text "$dry_run_output" "harbor==0.20.0"
    require_text "$dry_run_output" "--dataset terminal-bench@2.0"
    require_text "$dry_run_output" "--agent-kwarg"
    require_text "$dry_run_output" "api_base=http://127.0.0.1:"
    ! grep -Fq -- "--override-cpus" <<<"$dry_run_output" \
        || fail "practical profile unexpectedly overrides task CPUs"
    ! grep -Fq -- "--override-memory-mb" <<<"$dry_run_output" \
        || fail "practical profile unexpectedly overrides task memory"
    [[ ! -e "$tmp_dir/dry-run-output" ]] \
        || fail "--dry-run created its output directory"
    ! grep -Fq "do-not-print-this-token" <<<"$dry_run_output" \
        || fail "--dry-run exposed HF_TOKEN"
}

test_published_profile_dry_run() {
    local tmp_dir="$1"
    local dry_run_output

    dry_run_output="$(
        HF_TOKEN="do-not-print-this-token" \
            bash "$SCRIPT" \
                --backend nvidia \
                --profile ornith-397b-published \
                --dry-run \
                --gpus 0,1,2,3,4,5,6,7 \
                --tp-size 8 \
                --output-dir "$tmp_dir/published-dry-run-output" \
                2>&1
    )"

    require_text "$dry_run_output" "Profile: ornith-397b-published"
    require_text "$dry_run_output" "Profile modified: false"
    require_text "$dry_run_output" "deepreinforce-ai/Ornith-1.0-397B"
    require_text "$dry_run_output" "5e3e761811e804c295c1d3c0ce68b21da6154209"
    require_text "$dry_run_output" "--dataset terminal-bench/terminal-bench-2-1@6"
    require_text "$dry_run_output" "--max-model-len 131072"
    require_text "$dry_run_output" "--tool-call-parser qwen3_xml"
    require_text "$dry_run_output" "--reasoning-parser qwen3"
    require_text "$dry_run_output" "parser_name=json"
    require_text "$dry_run_output" "temperature=1.0"
    require_text "$dry_run_output" "top_p=1.0"
    require_text "$dry_run_output" "--override-cpus 32"
    require_text "$dry_run_output" "--override-memory-mb 49152"
    require_text "$dry_run_output" "397B BF16 checkpoint requires an exceptionally large multi-GPU memory pool"
    [[ ! -e "$tmp_dir/published-dry-run-output" ]] \
        || fail "published profile --dry-run created its output directory"
    ! grep -Fq "do-not-print-this-token" <<<"$dry_run_output" \
        || fail "published profile --dry-run exposed HF_TOKEN"
}

test_profile_overrides_are_order_independent() {
    local first_output second_output

    first_output="$(
        bash "$SCRIPT" \
            --backend nvidia \
            --profile ornith-397b-published \
            --dataset custom/tasks@1 \
            --max-model-len 65536 \
            --temperature 0.7 \
            --task-cpus 16 \
            --dry-run \
            --gpus 0,1 \
            --tp-size 2 \
            2>&1
    )"
    second_output="$(
        bash "$SCRIPT" \
            --backend nvidia \
            --dataset custom/tasks@1 \
            --max-model-len 65536 \
            --temperature 0.7 \
            --task-cpus 16 \
            --profile ornith-397b-published \
            --dry-run \
            --gpus 0,1 \
            --tp-size 2 \
            2>&1
    )"

    for output in "$first_output" "$second_output"; do
        require_text "$output" "Profile: ornith-397b-published"
        require_text "$output" "Profile modified: true"
        require_text "$output" "--dataset custom/tasks@1"
        require_text "$output" "--max-model-len 65536"
        require_text "$output" "temperature=0.7"
        require_text "$output" "--override-cpus 16"
        require_text "$output" "not directly comparable with the unmodified ornith-397b-published profile"
    done
}

test_unknown_profile_fails_before_host_checks() {
    local tmp_dir="$1"
    local console_output="$tmp_dir/unknown-profile-output"

    if PATH="/usr/bin:/bin" \
        bash "$SCRIPT" --profile unknown --dry-run >"$console_output" 2>&1
    then
        fail "unknown profile was accepted"
    fi

    grep -Fq -- "unsupported profile: unknown" "$console_output" \
        || fail "unknown profile failure was not actionable"
    ! grep -Fq -- "Required command not found" "$console_output" \
        || fail "unknown profile reached host prerequisite checks"
}

write_backend_detection_mocks() {
    local fake_bin="$1"

    mkdir -p "$fake_bin"

    cat > "$fake_bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${MOCK_NVIDIA_DETECTED:-false}" == true ]] || exit 1
printf '0\n'
EOF

    cat > "$fake_bin/rocminfo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${MOCK_AMD_DETECTED:-false}" == true ]] || exit 1
printf '  Name:                    gfx1201\n'
EOF

    chmod +x "$fake_bin/nvidia-smi" "$fake_bin/rocminfo"
}

test_auto_backend_detection() {
    local tmp_dir="$1"
    local fake_bin="$tmp_dir/bin"
    local nvidia_output amd_output mixed_output undetected_output

    write_backend_detection_mocks "$fake_bin"
    mkdir -p "$tmp_dir/amd-dev/dri"
    touch "$tmp_dir/amd-dev/kfd"

    nvidia_output="$(
        PATH="$fake_bin:/usr/bin:/bin" \
        MOCK_NVIDIA_DETECTED=true \
        MOCK_AMD_DETECTED=false \
        VLLM_BENCHMARK_DEVICE_ROOT="$tmp_dir/no-amd-dev" \
            bash "$SCRIPT" --dry-run --gpus 0 --tp-size 1 2>&1
    )"
    require_text "$nvidia_output" "Backend: nvidia"
    require_text "$nvidia_output" "vllm/vllm-openai:v"

    amd_output="$(
        PATH="$fake_bin:/usr/bin:/bin" \
        MOCK_NVIDIA_DETECTED=false \
        MOCK_AMD_DETECTED=true \
        VLLM_BENCHMARK_DEVICE_ROOT="$tmp_dir/amd-dev" \
            bash "$SCRIPT" --dry-run --gpus 0 --tp-size 1 2>&1
    )"
    require_text "$amd_output" "Backend: amd"
    require_text "$amd_output" "rocm/vllm:rocm7.13.0_gfx120X-all"

    if PATH="$fake_bin:/usr/bin:/bin" \
        MOCK_NVIDIA_DETECTED=true \
        MOCK_AMD_DETECTED=true \
        VLLM_BENCHMARK_DEVICE_ROOT="$tmp_dir/amd-dev" \
            bash "$SCRIPT" --dry-run >"$tmp_dir/mixed-output" 2>&1
    then
        fail "auto backend accepted a mixed NVIDIA/AMD host"
    fi
    mixed_output="$(<"$tmp_dir/mixed-output")"
    require_text "$mixed_output" "detected both NVIDIA and AMD GPUs"
    require_text "$mixed_output" "use --backend nvidia or --backend amd"

    if PATH="$fake_bin:/usr/bin:/bin" \
        MOCK_NVIDIA_DETECTED=false \
        MOCK_AMD_DETECTED=false \
        VLLM_BENCHMARK_DEVICE_ROOT="$tmp_dir/no-amd-dev" \
            bash "$SCRIPT" \
                --dry-run \
                --output-dir "$tmp_dir/undetected-run" \
                >"$tmp_dir/undetected-output" 2>&1
    then
        fail "auto backend accepted a host without a usable GPU backend"
    fi
    undetected_output="$(<"$tmp_dir/undetected-output")"
    require_text "$undetected_output" "could not detect a usable NVIDIA or AMD GPU backend"
    [[ ! -e "$tmp_dir/undetected-run" ]] \
        || fail "failed auto detection created an output directory"
}

test_amd_dry_run_contract() {
    local tmp_dir="$1"
    local all_gpu_output dry_run_output

    dry_run_output="$(
        HF_TOKEN="do-not-print-this-token" \
            bash "$SCRIPT" \
                --backend amd \
                --dry-run \
                --gpus 0,1 \
                --tp-size 2 \
                --output-dir "$tmp_dir/amd-dry-run-output"
    )"

    require_text "$dry_run_output" "rocm/vllm:rocm7.13.0_gfx120X-all"
    require_text "$dry_run_output" "--device /dev/kfd"
    require_text "$dry_run_output" "--device /dev/dri"
    require_text "$dry_run_output" "--group-add video"
    require_text "$dry_run_output" "--security-opt seccomp=unconfined"
    require_text "$dry_run_output" "--env ROCR_VISIBLE_DEVICES=0\\,1"
    require_text "$dry_run_output" "--entrypoint vllm"
    require_text "$dry_run_output" "serve"
    require_text "$dry_run_output" "--enforce-eager"
    ! grep -Fq -- "--gpus" <<<"$dry_run_output" \
        || fail "AMD dry run contains NVIDIA --gpus runtime flags"
    [[ ! -e "$tmp_dir/amd-dry-run-output" ]] \
        || fail "AMD --dry-run created its output directory"
    ! grep -Fq "do-not-print-this-token" <<<"$dry_run_output" \
        || fail "AMD --dry-run exposed HF_TOKEN"

    all_gpu_output="$(bash "$SCRIPT" --backend amd --dry-run)"
    ! grep -Fq -- 'ROCR_VISIBLE_DEVICES=all' <<<"$all_gpu_output" \
        || fail "AMD all-GPU dry run emitted an invalid ROCr selector"
}

test_source_safety_contract() {
    grep -Fq 'set -euo pipefail' "$SCRIPT" \
        || fail "strict Bash mode is not enabled"
    ! grep -Eq 'fuser[[:space:]]+-k' "$SCRIPT" \
        || fail "script still kills arbitrary port owners"
    ! grep -Eq '(pip|uv pip)[[:space:]]+install.*vllm' "$SCRIPT" \
        || fail "script installs vLLM into host Python"
    grep -Fq -- '--name "$CONTAINER_NAME"' "$SCRIPT" \
        || fail "vLLM server does not use a named container"
    grep -Fq -- 'docker rm -f "$CONTAINER_NAME"' "$SCRIPT" \
        || fail "cleanup does not target the named container"
}

write_mock_commands() {
    local fake_bin="$1"

    mkdir -p "$fake_bin"

    cat > "$fake_bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"--query-gpu=index --format=csv,noheader,nounits"* ]]; then
    printf '0\n1\n'
elif [[ "$*" == *"--query-gpu=index,name,memory.total"* ]]; then
    printf '0, Mock GPU 0, 32768\n1, Mock GPU 1, 32768\n'
else
    printf 'GPU 0: Mock GPU 0\nGPU 1: Mock GPU 1\n'
fi
EOF

cat > "$fake_bin/rocminfo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '  Name:                    %s\n' "${MOCK_ROCM_ARCH:-gfx1201}"
printf '  Name:                    %s\n' "${MOCK_ROCM_ARCH:-gfx1201}"
EOF

    cat > "$fake_bin/rocm-smi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
    printf 'ROCm-SMI version: 7.13.0\n'
else
    printf 'device,card series,vram total\n'
    printf 'card0,AMD Radeon AI PRO R9700S,34359738368\n'
    printf 'card1,AMD Radeon AI PRO R9700S,34359738368\n'
fi
EOF

    cat > "$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${MOCK_DOCKER_LOG:?}"
printf '\n' >> "${MOCK_DOCKER_LOG:?}"

case "${1:-} ${2:-}" in
    "info --format")
        printf '%s\n' "${MOCK_DOCKER_ROOT:?}"
        ;;
    "info "*)
        ;;
    "version --format")
        printf '29.0.0\n'
        ;;
    "container inspect")
        exit 1
        ;;
    "volume inspect")
        exit 1
        ;;
    "volume create")
        printf '%s\n' "${@: -1}"
        ;;
    "image inspect")
        printf 'vllm/vllm-openai@sha256:mockdigest\n'
        ;;
    "inspect --format")
        printf 'true\n'
        ;;
    "logs --follow")
        printf 'mock vLLM server log\n'
        ;;
    "rm -f")
        ;;
    "run "*)
        if [[ " $* " == *" --detach "* ]]; then
            printf 'mock-container-id\n'
        else
            printf 'GPU 0: Mock GPU 0\nGPU 1: Mock GPU 1\n'
        fi
        ;;
    *)
        ;;
esac
EOF

    cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${MOCK_CURL_LOG:?}"
printf '\n' >> "${MOCK_CURL_LOG:?}"

output=""
previous=""
for arg in "$@"; do
    if [[ "$previous" == "-o" || "$previous" == "--output" ]]; then
        output="$arg"
    fi
    previous="$arg"
done

if [[ " $* " == *"/v1/models"* ]]; then
    payload='{"data":[{"id":"Ornith-1.0-35B"}]}'
elif [[ -n "${MOCK_SMOKE_RESPONSE:-}" ]]; then
    payload="$MOCK_SMOKE_RESPONSE"
else
    payload='{"choices":[{"message":{"content":"vLLM smoke test passed"}}]}'
fi

if [[ -n "$output" ]]; then
    printf '%s\n' "$payload" > "$output"
else
    printf '%s\n' "$payload"
fi
EOF

    cat > "$fake_bin/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${MOCK_UV_LOG:?}"
printf '\n' >> "${MOCK_UV_LOG:?}"

if [[ " $* " == *" harbor --version"* ]]; then
    printf 'harbor 0.20.0\n'
elif [[ " $* " == *" harbor run "* ]]; then
    mkdir -p jobs/mock-job
    printf '{"reward": 1}\n' > jobs/mock-job/result.json
    printf 'mock Harbor benchmark complete\n'
fi
EOF

    chmod +x \
        "$fake_bin/nvidia-smi" \
        "$fake_bin/rocminfo" \
        "$fake_bin/rocm-smi" \
        "$fake_bin/docker" \
        "$fake_bin/curl" \
        "$fake_bin/uv"
}

test_mocked_full_lifecycle() {
    local tmp_dir="$1"
    local fake_bin="$tmp_dir/bin"
    local output_dir="$tmp_dir/run"
    local console_output="$tmp_dir/console-output"

    write_mock_commands "$fake_bin"
    mkdir -p "$tmp_dir/docker-root"
    : > "$tmp_dir/docker.log"
    : > "$tmp_dir/curl.log"
    : > "$tmp_dir/uv.log"

    if ! PATH="$fake_bin:/usr/bin:/bin" \
        VLLM_BENCHMARK_DEVICE_ROOT="$tmp_dir/no-amd-dev" \
        MOCK_DOCKER_LOG="$tmp_dir/docker.log" \
        MOCK_DOCKER_ROOT="$tmp_dir/docker-root" \
        MOCK_CURL_LOG="$tmp_dir/curl.log" \
        MOCK_UV_LOG="$tmp_dir/uv.log" \
        HF_TOKEN="mock-secret-token" \
            bash "$SCRIPT" \
                --gpus 0,1 \
                --tp-size 2 \
                --startup-timeout 5 \
                --min-free-gb 0 \
            --no-pull \
            --output-dir "$output_dir" \
            -- \
            --task-name mock-task \
            >"$console_output" 2>&1
    then
        cat "$console_output" >&2
        fail "mock lifecycle exited unsuccessfully"
    fi

    grep -Fq -- '--detach' "$tmp_dir/docker.log" \
        || fail "mock lifecycle did not launch a detached vLLM container"
    grep -Fq -- '--env HF_TOKEN' "$tmp_dir/docker.log" \
        || fail "HF_TOKEN was not passed by environment name"
    ! grep -Fq "mock-secret-token" "$tmp_dir/docker.log" "$console_output" \
        || fail "HF_TOKEN value leaked into logs"
    grep -Fq -- 'rm -f infra-vllm-benchmark-8000' "$tmp_dir/docker.log" \
        || fail "named vLLM container was not cleaned up"
    grep -Fq -- '--agent-kwarg api_base=http://127.0.0.1:8000/v1' "$tmp_dir/uv.log" \
        || fail "Harbor was not routed explicitly to the local vLLM API"
    [[ -f "$output_dir/metadata.json" ]] \
        || fail "metadata.json was not written"
    grep -Fq -- '"backend": "nvidia"' "$output_dir/metadata.json" \
        || fail "auto-resolved NVIDIA backend was not recorded in metadata"
    grep -Fq -- '"profile": "ornith-35b-practical"' "$output_dir/metadata.json" \
        || fail "practical profile was not recorded in metadata"
    grep -Fq -- '"profile_modified": false' "$output_dir/metadata.json" \
        || fail "unmodified practical profile was not recorded in metadata"
    grep -Fq -- '"harbor_parser": "json"' "$output_dir/metadata.json" \
        || fail "effective Harbor parser was not recorded in metadata"
    grep -Fq -- '"task_cpus": null' "$output_dir/metadata.json" \
        || fail "practical task CPU default was not recorded in metadata"
    grep -Fq -- 'profile=ornith-35b-practical' "$output_dir/summary.txt" \
        || fail "practical profile was not recorded in the summary"
    [[ -f "$output_dir/smoke-response.json" ]] \
        || fail "chat-completion smoke response was not preserved"
    [[ -f "$output_dir/jobs/mock-job/result.json" ]] \
        || fail "Harbor job output was not preserved under the run directory"
    grep -Fq -- '--task-name mock-task' "$output_dir/metadata.json" "$output_dir/summary.txt" \
        || fail "forwarded Harbor arguments were not preserved in run metadata"
}

test_mocked_amd_lifecycle() {
    local tmp_dir="$1"
    local fake_bin="$tmp_dir/bin"
    local output_dir="$tmp_dir/run"
    local console_output="$tmp_dir/console-output"

    write_mock_commands "$fake_bin"
    mkdir -p "$tmp_dir/docker-root" "$tmp_dir/dev/dri"
    touch "$tmp_dir/dev/kfd"
    : > "$tmp_dir/docker.log"
    : > "$tmp_dir/curl.log"
    : > "$tmp_dir/uv.log"

    if ! PATH="$fake_bin:/usr/bin:/bin" \
        VLLM_BENCHMARK_DEVICE_ROOT="$tmp_dir/dev" \
        MOCK_DOCKER_LOG="$tmp_dir/docker.log" \
        MOCK_DOCKER_ROOT="$tmp_dir/docker-root" \
        MOCK_CURL_LOG="$tmp_dir/curl.log" \
        MOCK_UV_LOG="$tmp_dir/uv.log" \
            bash "$SCRIPT" \
                --backend amd \
                --gpus 0,1 \
                --tp-size 2 \
                --startup-timeout 5 \
                --min-free-gb 0 \
                --no-pull \
                --output-dir "$output_dir" \
                >"$console_output" 2>&1
    then
        cat "$console_output" >&2
        fail "mock AMD lifecycle exited unsuccessfully"
    fi

    grep -Fq -- '--device /dev/kfd' "$tmp_dir/docker.log" \
        || fail "AMD lifecycle did not expose /dev/kfd"
    grep -Fq -- '--device /dev/dri' "$tmp_dir/docker.log" \
        || fail "AMD lifecycle did not expose /dev/dri"
    grep -Fq -- '--env ROCR_VISIBLE_DEVICES=0\,1' "$tmp_dir/docker.log" \
        || fail "AMD lifecycle did not select the requested GPUs"
    grep -Fq -- '--entrypoint vllm' "$tmp_dir/docker.log" \
        || fail "AMD lifecycle did not override the image entrypoint"
    grep -Fq -- '--enforce-eager' "$tmp_dir/docker.log" \
        || fail "AMD lifecycle did not enable eager execution"
    ! grep -Fq -- '--gpus' "$tmp_dir/docker.log" \
        || fail "AMD lifecycle used NVIDIA Docker GPU flags"
    grep -Fq -- 'rm -f infra-vllm-benchmark-amd-8000' "$tmp_dir/docker.log" \
        || fail "named AMD vLLM container was not cleaned up"
    grep -Fq -- '"backend": "amd"' "$output_dir/metadata.json" \
        || fail "AMD backend was not recorded in metadata"
    grep -Fq -- '"gfx1201"' "$output_dir/metadata.json" \
        || fail "AMD GPU architecture was not recorded in metadata"
    [[ -f "$output_dir/smoke-response.json" ]] \
        || fail "AMD chat-completion smoke response was not preserved"
    [[ -f "$output_dir/jobs/mock-job/result.json" ]] \
        || fail "AMD Harbor job output was not preserved"
}

test_amd_rejects_unsupported_default_image() {
    local tmp_dir="$1"
    local fake_bin="$tmp_dir/bin"
    local console_output="$tmp_dir/console-output"

    write_mock_commands "$fake_bin"
    mkdir -p "$tmp_dir/docker-root" "$tmp_dir/dev/dri"
    touch "$tmp_dir/dev/kfd"
    : > "$tmp_dir/docker.log"
    : > "$tmp_dir/curl.log"
    : > "$tmp_dir/uv.log"

    if PATH="$fake_bin:/usr/bin:/bin" \
        VLLM_BENCHMARK_DEVICE_ROOT="$tmp_dir/dev" \
        MOCK_ROCM_ARCH="gfx942" \
        MOCK_DOCKER_LOG="$tmp_dir/docker.log" \
        MOCK_DOCKER_ROOT="$tmp_dir/docker-root" \
        MOCK_CURL_LOG="$tmp_dir/curl.log" \
        MOCK_UV_LOG="$tmp_dir/uv.log" \
            bash "$SCRIPT" \
                --backend amd \
                --gpus 0,1 \
                --tp-size 2 \
                --min-free-gb 0 \
                --no-pull \
                >"$console_output" 2>&1
    then
        fail "default gfx120X image accepted an unsupported AMD architecture"
    fi

    grep -Fq -- 'default AMD image supports gfx120X GPUs' "$console_output" \
        || fail "unsupported AMD architecture failure was not actionable"
}

test_smoke_rejects_wrong_answer() {
    local tmp_dir="$1"
    local fake_bin="$tmp_dir/bin"
    local output_dir="$tmp_dir/run"

    write_mock_commands "$fake_bin"
    mkdir -p "$tmp_dir/docker-root"
    : > "$tmp_dir/docker.log"
    : > "$tmp_dir/curl.log"
    : > "$tmp_dir/uv.log"

    if PATH="$fake_bin:/usr/bin:/bin" \
        VLLM_BENCHMARK_DEVICE_ROOT="$tmp_dir/no-amd-dev" \
        MOCK_DOCKER_LOG="$tmp_dir/docker.log" \
        MOCK_DOCKER_ROOT="$tmp_dir/docker-root" \
        MOCK_CURL_LOG="$tmp_dir/curl.log" \
        MOCK_UV_LOG="$tmp_dir/uv.log" \
        MOCK_SMOKE_RESPONSE='{"choices":[{"message":{"content":"wrong answer"}}]}' \
            bash "$SCRIPT" \
                --smoke \
                --gpus 0,1 \
                --tp-size 2 \
                --startup-timeout 5 \
                --min-free-gb 0 \
                --no-pull \
                --output-dir "$output_dir" \
                >/dev/null 2>&1
    then
        fail "smoke test accepted a semantically incorrect response"
    fi

    grep -Fq -- 'rm -f infra-vllm-benchmark-8000' "$tmp_dir/docker.log" \
        || fail "failed smoke test did not clean up its named container"
}

main() {
    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/vllm-benchmark-static.XXXXXX)"
    trap "rm -rf '$tmp_dir'" EXIT

    test_help_and_safe_dry_run "$tmp_dir"
    test_published_profile_dry_run "$tmp_dir"
    test_profile_overrides_are_order_independent
    test_unknown_profile_fails_before_host_checks "$tmp_dir"
    test_auto_backend_detection "$tmp_dir/auto-detection"
    test_amd_dry_run_contract "$tmp_dir"
    test_source_safety_contract
    test_mocked_full_lifecycle "$tmp_dir/mock"
    test_mocked_amd_lifecycle "$tmp_dir/mock-amd"
    test_amd_rejects_unsupported_default_image "$tmp_dir/unsupported-amd"
    test_smoke_rejects_wrong_answer "$tmp_dir/wrong-smoke"
    echo "vLLM benchmark static tests passed"
}

main "$@"
