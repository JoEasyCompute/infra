#!/usr/bin/env bash
set -euo pipefail

### CONFIG ############################################################

BASE_DIR="/opt/ipmi-watch"
CSV_FILE="$BASE_DIR/targets.csv"
STATE_FILE="$BASE_DIR/state.json"
LOCK_FILE="/var/lock/ipmi-watch.lock"

IPMI_USER="ADMIN"
IPMI_PASS='TTTSSSSSS11$'   # MUST be single-quoted
MAIL_TO="you@example.com"
MAIL_SUBJECT_PREFIX="IPMI DOWN"

IPMITOOL_TIMEOUT=8   # seconds

# Prometheus textfile collector (node_exporter)
PROM_DIR="/var/lib/node_exporter/textfile_collector"
PROM_FILE="$PROM_DIR/ipmi_watch.prom"

########################################################################

NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
NOW_EPOCH="$(date -u +%s)"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

mkdir -p "$BASE_DIR"

# Initialise state file if missing
if [[ ! -f "$STATE_FILE" ]]; then
  jq -n \
    --arg now "$NOW_ISO" \
    '{
      version: 1,
      updated_at: $now,
      hosts: {}
    }' > "$STATE_FILE"
fi

STATE="$(cat "$STATE_FILE")"
ALERTS=()

# Helper: run ipmitool check
check_ipmi() {
  local ip="$1"
  local out rc

  out="$(
    timeout "$IPMITOOL_TIMEOUT" \
      ipmitool -I lanplus -H "$ip" -U "$IPMI_USER" -P "$IPMI_PASS" \
      chassis power status 2>&1
  )" || rc=$?

  rc="${rc:-0}"

  if [[ "$rc" -eq 0 ]]; then
    echo "UP|$out"
  else
    echo "DOWN|$out"
  fi
}

while IFS=, read -r ipmi_ip hostname server_ip; do
  [[ -z "${ipmi_ip// }" ]] && continue
  [[ "$ipmi_ip" =~ ^# ]] && continue

  RESULT="$(check_ipmi "$ipmi_ip")"
  STATUS="${RESULT%%|*}"
  REASON="${RESULT#*|}"
  REASON="$(echo "$REASON" | head -n1 | tr -s ' ')"

  HOST_EXISTS="$(jq -r --arg ip "$ipmi_ip" '.hosts[$ip] != null' <<<"$STATE")"

  if [[ "$HOST_EXISTS" != "true" ]]; then
    STATE="$(jq \
      --arg ip "$ipmi_ip" \
      --arg hn "$hostname" \
      --arg sip "$server_ip" \
      '.hosts[$ip] = {
        hostname: $hn,
        server_ip: $sip,
        status: "UNKNOWN",
        down_since: null,
        alert_count: 0,
        last_alert_ts: null,
        last_error: null,
        last_ok_ts: null
      }' <<<"$STATE")"
  fi

  PREV_STATUS="$(jq -r --arg ip "$ipmi_ip" '.hosts[$ip].status' <<<"$STATE")"
  ALERT_COUNT="$(jq -r --arg ip "$ipmi_ip" '.hosts[$ip].alert_count' <<<"$STATE")"

  # Always refresh metadata from CSV
  STATE="$(jq \
    --arg ip "$ipmi_ip" \
    --arg hn "$hostname" \
    --arg sip "$server_ip" \
    '
    .hosts[$ip].hostname = $hn |
    .hosts[$ip].server_ip = $sip
    ' <<<"$STATE")"

  if [[ "$STATUS" == "UP" ]]; then
    if [[ "$PREV_STATUS" == "DOWN" ]]; then
      STATE="$(jq \
        --arg ip "$ipmi_ip" \
        --arg now "$NOW_ISO" \
        '
        .hosts[$ip].status = "UP" |
        .hosts[$ip].down_since = null |
        .hosts[$ip].alert_count = 0 |
        .hosts[$ip].last_alert_ts = null |
        .hosts[$ip].last_error = null |
        .hosts[$ip].last_ok_ts = $now
        ' <<<"$STATE")"
    else
      STATE="$(jq \
        --arg ip "$ipmi_ip" \
        --arg now "$NOW_ISO" \
        '.hosts[$ip].status = "UP" | .hosts[$ip].last_ok_ts = $now' <<<"$STATE")"
    fi
    continue
  fi

  # STATUS == DOWN
  if [[ "$PREV_STATUS" != "DOWN" ]]; then
    STATE="$(jq \
      --arg ip "$ipmi_ip" \
      --arg now "$NOW_ISO" \
      '
      .hosts[$ip].status = "DOWN" |
      .hosts[$ip].down_since = $now |
      .hosts[$ip].alert_count = 0
      ' <<<"$STATE")"
    ALERT_COUNT=0
  fi

  if (( ALERT_COUNT < 2 )); then
    ALERTS+=(
      "$(printf "%s | %s | %s | down since %s | alert %d/2 | %s" \
        "$hostname" "$server_ip" "$ipmi_ip" \
        "$(jq -r --arg ip "$ipmi_ip" '.hosts[$ip].down_since' <<<"$STATE")" \
        "$((ALERT_COUNT + 1))" "$REASON")"
    )

    STATE="$(jq \
      --arg ip "$ipmi_ip" \
      --arg now "$NOW_ISO" \
      --arg err "$REASON" \
      '
      .hosts[$ip].alert_count += 1 |
      .hosts[$ip].last_alert_ts = $now |
      .hosts[$ip].last_error = $err
      ' <<<"$STATE")"
  fi

done < "$CSV_FILE"

STATE="$(jq --arg now "$NOW_ISO" '.updated_at = $now' <<<"$STATE")"

# Persist state atomically
TMP_STATE="${STATE_FILE}.tmp"
echo "$STATE" > "$TMP_STATE"
mv "$TMP_STATE" "$STATE_FILE"

# --- Prometheus textfile export (node_exporter textfile collector) ---
mkdir -p "$PROM_DIR"
PROM_TMP="${PROM_FILE}.tmp"

{
  echo "# HELP ipmi_watch_up IPMI reachability via ipmitool (1=up, 0=down/unknown)"
  echo "# TYPE ipmi_watch_up gauge"
  echo "# HELP ipmi_watch_alert_count Number of alerts sent in the current outage (0..2)"
  echo "# TYPE ipmi_watch_alert_count gauge"
  echo "# HELP ipmi_watch_last_check_epoch Last time the check ran for this target (unix epoch)"
  echo "# TYPE ipmi_watch_last_check_epoch gauge"
  echo "# HELP ipmi_watch_down_since_epoch Outage start time if down, else 0 (unix epoch)"
  echo "# TYPE ipmi_watch_down_since_epoch gauge"
  echo "# HELP ipmi_watch_last_ok_epoch Last successful check time, else 0 (unix epoch)"
  echo "# TYPE ipmi_watch_last_ok_epoch gauge"

  jq -r --argjson now_epoch "$NOW_EPOCH" '
    .hosts
    | to_entries[]
    | .key as $ipmi
    | .value.hostname as $hn
    | .value.server_ip as $sip
    | .value.status as $st
    | (.value.alert_count // 0) as $ac
    | (.value.down_since // "") as $ds
    | (.value.last_ok_ts // "") as $ok
    | {
        ipmi: $ipmi,
        hn: ($hn // ""),
        sip: ($sip // ""),
        up: (if $st == "UP" then 1 else 0 end),
        ac: $ac,
        ds: $ds,
        ok: $ok
      }
    | [
        "ipmi_watch_up{ipmi_ip=\"" + .ipmi + "\",hostname=\"" + (.hn|gsub("\"";"\\\\\"")) + "\",server_ip=\"" + (.sip|gsub("\"";"\\\\\"")) + "\"} " + (.up|tostring),
        "ipmi_watch_alert_count{ipmi_ip=\"" + .ipmi + "\",hostname=\"" + (.hn|gsub("\"";"\\\\\"")) + "\",server_ip=\"" + (.sip|gsub("\"";"\\\\\"")) + "\"} " + (.ac|tostring),
        "ipmi_watch_last_check_epoch{ipmi_ip=\"" + .ipmi + "\",hostname=\"" + (.hn|gsub("\"";"\\\\\"")) + "\",server_ip=\"" + (.sip|gsub("\"";"\\\\\"")) + "\"} " + ($now_epoch|tostring),
        "ipmi_watch_down_since_epoch{ipmi_ip=\"" + .ipmi + "\",hostname=\"" + (.hn|gsub("\"";"\\\\\"")) + "\",server_ip=\"" + (.sip|gsub("\"";"\\\\\"")) + "\"} " +
          (if .ds == "" then "0" else (try ((.ds|fromdateiso8601)|tostring) catch "0") end),
        "ipmi_watch_last_ok_epoch{ipmi_ip=\"" + .ipmi + "\",hostname=\"" + (.hn|gsub("\"";"\\\\\"")) + "\",server_ip=\"" + (.sip|gsub("\"";"\\\\\"")) + "\"} " +
          (if .ok == "" then "0" else (try ((.ok|fromdateiso8601)|tostring) catch "0") end)
      ]
    | .[]
  ' "$STATE_FILE"
} > "$PROM_TMP"

mv "$PROM_TMP" "$PROM_FILE"
# --- end Prometheus export ---

# Send email if required
if (( ${#ALERTS[@]} > 0 )); then
  {
    echo "The following IPMI endpoints are unreachable:"
    echo
    printf '%s\n' "${ALERTS[@]}"
    echo
    echo "This alert will be sent at most twice per outage."
  } | mail -s "$MAIL_SUBJECT_PREFIX (${#ALERTS[@]})" "$MAIL_TO"
fi
