# ipmi-watch.sh

`monitor/ipmi-watch.sh` checks that each server's BMC answers (`ipmitool -I lanplus ... chassis power status`), records outages in `/opt/ipmi-watch/state.json`, emails when a BMC goes down, and writes Prometheus metrics to node_exporter's textfile collector (`/var/lib/node_exporter/textfile_collector/ipmi_watch.prom`). It runs on one monitoring host and checks every BMC over the network, so it needs BMC credentials. In-band `-I open` only reaches the local machine's own BMC and can't be used here.

## Targets

`/opt/ipmi-watch/targets.csv`, one line per server, no header needed (lines starting with `#` are skipped):

```text
<ipmi_ip>,<hostname>,<server_ip>
```

Keep the real file on the monitoring host only. The repo's `monitor/target.csv` is an empty template.

## Credentials

The password is **never** stored in the script or the repo. The script looks, in order, for:

1. `IPMI_PASS` or `IPMI_PASSWORD` in the environment (and `IPMI_USER`, default `ADMIN`)
2. A credentials file, `/etc/ipmi-watch/credentials` by default (`IPMI_WATCH_CRED_FILE` overrides it)

Create the file on the monitoring host:

```bash
sudo install -d -m 700 /etc/ipmi-watch
sudo install -m 600 /dev/null /etc/ipmi-watch/credentials
sudoedit /etc/ipmi-watch/credentials
```

```text
IPMI_USER=ADMIN
IPMI_PASS=<from the password manager>
```

The script refuses a file that isn't owned by the user running it or that group or others can read. The file is parsed as data, never sourced. The password goes to `ipmitool` through the `IPMI_PASSWORD` environment variable with `-E`, not `-P`, so it doesn't appear in `ps` output.

Optional: `IPMI_WATCH_MAIL_TO=<address>` sets the alert recipient.

## Metrics

| Metric | Meaning |
|---|---|
| `ipmi_watch_up` | 1 = BMC answered, 0 = down or unknown |
| `ipmi_watch_down_since_epoch` | Outage start, or 0 |
| `ipmi_watch_last_ok_epoch` | Last successful check, or 0 |
| `ipmi_watch_last_check_epoch` | Last check time |
| `ipmi_watch_alert_count` | Alerts sent in the current outage |

## History note

From February 2026 until 2026-11-07 the script had the BMC password written into it, in a public repository. On 2026-11-07 the git history was rewritten to remove it (`git filter-repo --replace-text`), but anyone who cloned or viewed the repo before then may have it. Treat that password as exposed: it must be changed on every BMC that used it.
