#!/usr/bin/env python3
"""
network-batch.sh - Small orchestration helper for network-test.sh.

Host file format:
    ssh_host [target_ip] [group]

Examples:
    node01 10.0.0.11 rack-a
    node02 10.0.0.12 rack-a
    node03 10.0.0.13 rack-b

Example plan export:
    ./test/network-batch.sh --hosts hosts.txt --mode rotate --group-mode across --groups rack-a,rack-b \
        --rounds 2 --plan-only \
        --export-plan-json ./logs/network-batch/network-plan.json \
        --export-plan-csv ./logs/network-batch/network-plan.csv
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import pathlib
import subprocess
import sys
import time
from dataclasses import dataclass


@dataclass
class Host:
    ssh_host: str
    target_ip: str
    group: str


def log(message: str) -> None:
    ts = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {message}")


def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Small orchestration helper around test/network-test.sh for client acceptance runs."
    )
    parser.add_argument("--hosts", required=True, help="Host list. Format per line: ssh_host [target_ip] [group]")
    parser.add_argument("--mode", default="chain", choices=["chain", "pairs", "rotate"])
    parser.add_argument("--clients", type=int, default=0, help="Use only the first N hosts from the file")
    parser.add_argument("--rounds", type=int, default=0, help="Rotation rounds for --mode rotate")
    parser.add_argument("--group-mode", default="all", choices=["all", "within", "across"])
    parser.add_argument("--groups", default="", help="Comma-separated group filter, e.g. rack-a,rack-b")
    parser.add_argument(
        "--within-each-group",
        action="store_true",
        help="Run the selected mode separately within each discovered group",
    )
    parser.add_argument("--port", type=int, default=5201)
    parser.add_argument("--duration", type=int, default=30)
    parser.add_argument("--stress", action="store_true")
    parser.add_argument("--remote-script", default="/opt/provision/network-test.sh")
    parser.add_argument("--ssh-user", default="")
    parser.add_argument("--server-warmup", type=int, default=2)
    parser.add_argument("--result-dir", default="./logs/network-batch")
    parser.add_argument("--export-plan-json", default="", help="Write planned runs to this JSON file")
    parser.add_argument("--export-plan-csv", default="", help="Write planned runs to this CSV file")
    parser.add_argument("--plan-only", action="store_true", help="Export the plan and exit without running batches")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def load_hosts(path: str, group_filter: set[str], client_limit: int) -> list[Host]:
    hosts: list[Host] = []
    for raw in pathlib.Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        ssh_host = parts[0]
        target_ip = parts[1] if len(parts) >= 2 else ssh_host
        group = parts[2] if len(parts) >= 3 else "default"
        if group_filter and group not in group_filter:
            continue
        hosts.append(Host(ssh_host=ssh_host, target_ip=target_ip, group=group))

    if client_limit > 0:
        hosts = hosts[:client_limit]

    if len(hosts) < 2:
        die("Need at least 2 selected hosts")
    return hosts


def split_hosts_by_group(hosts: list[Host]) -> dict[str, list[Host]]:
    grouped: dict[str, list[Host]] = {}
    for host in hosts:
        grouped.setdefault(host.group, []).append(host)
    return grouped


def remote_host(host: Host, ssh_user: str) -> str:
    return f"{ssh_user}@{host.ssh_host}" if ssh_user else host.ssh_host


def ssh_run(host: Host, ssh_user: str, command: str, dry_run: bool) -> subprocess.CompletedProcess[str] | None:
    rendered = f"ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new {remote_host(host, ssh_user)} {command}"
    if dry_run:
        log(f"DRY RUN remote on {host.ssh_host}: {command}")
        return None
    return subprocess.run(
        [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=accept-new",
            remote_host(host, ssh_user),
            command,
        ],
        text=True,
        check=False,
    )


def start_server(host: Host, args: argparse.Namespace) -> None:
    cmd = (
        f"sudo bash -lc \"nohup '{args.remote_script}' --server --port '{args.port}' "
        f">/tmp/network-test-server-{args.port}.log 2>&1 </dev/null & "
        f"echo \\$! >/tmp/network-test-server-{args.port}.pid\""
    )
    result = ssh_run(host, args.ssh_user, cmd, args.dry_run)
    if result and result.returncode != 0:
        die(f"Failed to start remote server on {host.ssh_host}")
    if not args.dry_run:
        time.sleep(args.server_warmup)


def stop_server(host: Host, args: argparse.Namespace) -> None:
    cmd = (
        f"sudo bash -lc 'if [[ -f /tmp/network-test-server-{args.port}.pid ]]; then "
        f"kill \"$(cat /tmp/network-test-server-{args.port}.pid)\" 2>/dev/null || true; "
        f"rm -f /tmp/network-test-server-{args.port}.pid; fi'"
    )
    result = ssh_run(host, args.ssh_user, cmd, args.dry_run)
    if result and result.returncode != 0:
        die(f"Failed to stop remote server on {host.ssh_host}")


def run_client(src: Host, dst: Host, args: argparse.Namespace) -> subprocess.Popen[str] | None:
    cmd = (
        f"sudo '{args.remote_script}' --client '{dst.target_ip}' "
        f"--port '{args.port}' --duration '{args.duration}'"
    )
    if args.stress:
        cmd += " --stress"

    if args.dry_run:
        log(f"DRY RUN client on {src.ssh_host}: {cmd}")
        return None

    return subprocess.Popen(
        [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=accept-new",
            remote_host(src, args.ssh_user),
            cmd,
        ],
        text=True,
    )


def pair_allowed(src: Host, dst: Host, group_mode: str) -> bool:
    if group_mode == "within":
        return src.group == dst.group
    if group_mode == "across":
        return src.group != dst.group
    return True


def skip_reason(src: Host, dst: Host, group_mode: str) -> str:
    if group_mode == "within" and src.group != dst.group:
        return f"group mismatch ({src.group} vs {dst.group})"
    if group_mode == "across" and src.group == dst.group:
        return f"same group ({src.group})"
    return ""


def run_pair_batch(pairs: list[tuple[Host, Host]], label: str, args: argparse.Namespace) -> None:
    started: list[Host] = []
    procs: list[subprocess.Popen[str]] = []

    for src, dst in pairs:
        if not pair_allowed(src, dst, args.group_mode):
            reason = skip_reason(src, dst, args.group_mode)
            log(f"SKIP {label} {src.ssh_host} -> {dst.ssh_host} due to {reason}")
            continue

        log(f"{label} {src.ssh_host} -> {dst.ssh_host} ({dst.target_ip})")
        start_server(dst, args)
        started.append(dst)
        proc = run_client(src, dst, args)
        if proc is not None:
            procs.append(proc)

    rc = 0
    for proc in procs:
        if proc.wait() != 0:
            rc = 1

    for host in started:
        stop_server(host, args)

    if rc != 0:
        die(f"One or more runs failed in {label}")


def run_chain(hosts: list[Host], args: argparse.Namespace) -> None:
    for i in range(len(hosts) - 1):
        src = hosts[i]
        dst = hosts[i + 1]
        if not pair_allowed(src, dst, args.group_mode):
            reason = skip_reason(src, dst, args.group_mode)
            log(f"SKIP chain {src.ssh_host} -> {dst.ssh_host} due to {reason}")
            continue
        run_pair_batch([(src, dst)], "CHAIN", args)


def run_pairs(hosts: list[Host], args: argparse.Namespace) -> None:
    pairs: list[tuple[Host, Host]] = []
    for i in range(0, len(hosts) - 1, 2):
        pairs.append((hosts[i], hosts[i + 1]))
    run_pair_batch(pairs, "PAIR", args)
    if len(hosts) % 2 == 1:
        log(f"INFO skipping unpaired trailing host: {hosts[-1].ssh_host}")


def rotated_rounds(hosts: list[Host], rounds: int) -> list[list[tuple[Host, Host]]]:
    order = list(hosts)
    bye_needed = len(order) % 2 == 1
    if bye_needed:
        order.append(None)  # type: ignore[arg-type]

    max_rounds = len(order) - 1
    if rounds > 0:
        max_rounds = min(max_rounds, rounds)

    result: list[list[tuple[Host, Host]]] = []
    for _ in range(max_rounds):
        round_pairs: list[tuple[Host, Host]] = []
        for i in range(len(order) // 2):
            left = order[i]
            right = order[-1 - i]
            if left is None or right is None:
                continue
            round_pairs.append((left, right))
        result.append(round_pairs)
        order = [order[0], order[-1], *order[1:-1]]
    return result


def run_rotate(hosts: list[Host], args: argparse.Namespace) -> None:
    rounds = rotated_rounds(hosts, args.rounds)
    for idx, pairs in enumerate(rounds, start=1):
        log(f"ROUND {idx}/{len(rounds)}")
        if len(hosts) % 2 == 1:
            paired_hosts = {h.ssh_host for pair in pairs for h in pair}
            for host in hosts:
                if host.ssh_host not in paired_hosts:
                    log(f"ROUND {idx} bye host: {host.ssh_host}")
                    break
        run_pair_batch(pairs, "ROTATE", args)


def collect_plan_for_pairs(
    pairs: list[tuple[Host, Host]],
    label: str,
    args: argparse.Namespace,
    round_no: int | None = None,
    group_name: str | None = None,
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for src, dst in pairs:
        allowed = pair_allowed(src, dst, args.group_mode)
        rows.append(
            {
                "group": group_name or "",
                "round": round_no if round_no is not None else "",
                "mode": args.mode,
                "label": label,
                "src_host": src.ssh_host,
                "src_group": src.group,
                "dst_host": dst.ssh_host,
                "dst_group": dst.group,
                "target_ip": dst.target_ip,
                "allowed": allowed,
                "skip_reason": "" if allowed else skip_reason(src, dst, args.group_mode),
                "port": args.port,
                "duration": args.duration,
                "stress": args.stress,
            }
        )
    return rows


def build_plan(hosts: list[Host], args: argparse.Namespace) -> list[dict[str, object]]:
    plan: list[dict[str, object]] = []

    def build_for_group(group_hosts: list[Host], group_name: str) -> None:
        if len(group_hosts) < 2:
            plan.append(
                {
                    "group": group_name,
                    "round": "",
                    "mode": args.mode,
                    "label": "SKIP",
                    "src_host": "",
                    "src_group": group_name,
                    "dst_host": "",
                    "dst_group": "",
                    "target_ip": "",
                    "allowed": False,
                    "skip_reason": "fewer than 2 selected hosts",
                    "port": args.port,
                    "duration": args.duration,
                    "stress": args.stress,
                }
            )
            return

        if args.mode == "chain":
            pairs = [(group_hosts[i], group_hosts[i + 1]) for i in range(len(group_hosts) - 1)]
            plan.extend(collect_plan_for_pairs(pairs, "CHAIN", args, group_name=group_name))
        elif args.mode == "pairs":
            pairs = [(group_hosts[i], group_hosts[i + 1]) for i in range(0, len(group_hosts) - 1, 2)]
            plan.extend(collect_plan_for_pairs(pairs, "PAIR", args, group_name=group_name))
            if len(group_hosts) % 2 == 1:
                plan.append(
                    {
                        "group": group_name,
                        "round": "",
                        "mode": args.mode,
                        "label": "INFO",
                        "src_host": group_hosts[-1].ssh_host,
                        "src_group": group_hosts[-1].group,
                        "dst_host": "",
                        "dst_group": "",
                        "target_ip": "",
                        "allowed": False,
                        "skip_reason": "unpaired trailing host",
                        "port": args.port,
                        "duration": args.duration,
                        "stress": args.stress,
                    }
                )
        else:
            rounds = rotated_rounds(group_hosts, args.rounds)
            for idx, pairs in enumerate(rounds, start=1):
                plan.extend(collect_plan_for_pairs(pairs, "ROTATE", args, round_no=idx, group_name=group_name))
                if len(group_hosts) % 2 == 1:
                    paired_hosts = {h.ssh_host for pair in pairs for h in pair}
                    for host in group_hosts:
                        if host.ssh_host not in paired_hosts:
                            plan.append(
                                {
                                    "group": group_name,
                                    "round": idx,
                                    "mode": args.mode,
                                    "label": "BYE",
                                    "src_host": host.ssh_host,
                                    "src_group": host.group,
                                    "dst_host": "",
                                    "dst_group": "",
                                    "target_ip": "",
                                    "allowed": False,
                                    "skip_reason": "bye host",
                                    "port": args.port,
                                    "duration": args.duration,
                                    "stress": args.stress,
                                }
                            )
                            break

    if args.within_each_group:
        grouped_hosts = split_hosts_by_group(hosts)
        for group_name in sorted(grouped_hosts):
            build_for_group(grouped_hosts[group_name], group_name)
    else:
        build_for_group(hosts, "")

    return plan


def export_plan(plan: list[dict[str, object]], args: argparse.Namespace) -> None:
    if args.export_plan_json:
        json_path = pathlib.Path(args.export_plan_json)
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(json.dumps(plan, indent=2) + "\n")
        log(f"Plan JSON written to {json_path}")

    if args.export_plan_csv:
        csv_path = pathlib.Path(args.export_plan_csv)
        csv_path.parent.mkdir(parents=True, exist_ok=True)
        fieldnames = [
            "group",
            "round",
            "mode",
            "label",
            "src_host",
            "src_group",
            "dst_host",
            "dst_group",
            "target_ip",
            "allowed",
            "skip_reason",
            "port",
            "duration",
            "stress",
        ]
        with csv_path.open("w", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(plan)
        log(f"Plan CSV written to {csv_path}")


def write_summary(hosts: list[Host], args: argparse.Namespace) -> None:
    result_dir = pathlib.Path(args.result_dir)
    result_dir.mkdir(parents=True, exist_ok=True)
    path = result_dir / f"network-batch-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}.txt"
    path.write_text(
        "\n".join(
            [
                f"mode={args.mode}",
                f"hosts_file={args.hosts}",
                f"selected_hosts={len(hosts)}",
                f"rounds={args.rounds}",
                f"group_mode={args.group_mode}",
                f"groups={args.groups}",
                f"within_each_group={args.within_each_group}",
                f"plan_only={args.plan_only}",
                f"port={args.port}",
                f"duration={args.duration}",
                f"stress={args.stress}",
                f"remote_script={args.remote_script}",
            ]
        )
        + "\n"
    )
    log(f"Summary written to {path}")


def main() -> None:
    args = parse_args()
    if args.within_each_group and args.group_mode != "within":
        die("--within-each-group requires --group-mode within")
    group_filter = {item.strip() for item in args.groups.split(",") if item.strip()}
    hosts = load_hosts(args.hosts, group_filter, args.clients)
    plan = build_plan(hosts, args)
    export_plan(plan, args)

    log(f"Selected {len(hosts)} host(s) from {args.hosts}")
    log(
        f"Mode={args.mode} Duration={args.duration}s Stress={args.stress} "
        f"Rounds={args.rounds} GroupMode={args.group_mode} "
        f"Groups={args.groups or 'all'} RemoteScript={args.remote_script}"
    )

    if args.plan_only:
        log("Plan-only mode enabled; exiting after plan export")
        write_summary(hosts, args)
        return

    if args.within_each_group:
        grouped_hosts = split_hosts_by_group(hosts)
        for group_name in sorted(grouped_hosts):
            group_hosts = grouped_hosts[group_name]
            if len(group_hosts) < 2:
                log(f"SKIP group {group_name}: fewer than 2 selected hosts")
                continue
            log(f"GROUP {group_name}: {len(group_hosts)} host(s)")
            if args.mode == "chain":
                run_chain(group_hosts, args)
            elif args.mode == "pairs":
                run_pairs(group_hosts, args)
            else:
                run_rotate(group_hosts, args)
    elif args.mode == "chain":
        run_chain(hosts, args)
    elif args.mode == "pairs":
        run_pairs(hosts, args)
    else:
        run_rotate(hosts, args)

    write_summary(hosts, args)


if __name__ == "__main__":
    main()
