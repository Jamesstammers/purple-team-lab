# Purple Team Lab

A self-configuring purple-team lab that runs entirely in Docker: an Elastic SIEM
with prebuilt detection rules, a **real Windows target** shipping Sysmon +
Winlogbeat telemetry, and the **Tuoni C2** — all brought up with one script for
detection-engineering practice.

## What's included

- **Elasticsearch + Kibana** — secured single node; prebuilt Elastic detection rules installed and enabled automatically.
- **Windows target** — a real Windows VM ([dockur/windows](https://github.com/dockur/windows)) under KVM, headless (SSH), with **Sysmon** ([sysmon-modular](https://github.com/olafhartong/sysmon-modular)) and **Winlogbeat** auto-installed and shipping to Elastic.
- **Tuoni C2** — community edition ([shell-dot/tuoni](https://github.com/shell-dot/tuoni)), installed via its official script.

## Prerequisites

- **Docker** with the WSL2 backend (Docker Desktop) or Docker Engine on Linux.
- **KVM / nested virtualization** for the Windows VM — check with `ls -l /dev/kvm`.
- **16 GB host RAM recommended.** The Windows VM needs ≥2 GB *free* just to boot, on top of Elastic and Tuoni. On Docker Desktop, raise the WSL2 memory limit — see [Memory](#memory-docker-desktop--wsl2). ~60 GB disk.
- Run everything **from a WSL2 (or Linux) shell** where `docker` works.

## Quick start

**First-time Docker Desktop setup (Windows/WSL2) — do this once:**

1. **Give WSL2 enough memory.** In PowerShell, create `%UserProfile%\.wslconfig`
   (use `memory=12GB` on a 16 GB host; `memory=7GB` on 8 GB):
   ```powershell
   @"
   [wsl2]
   memory=12GB
   processors=4
   "@ | Set-Content -Encoding ascii "$env:USERPROFILE\.wslconfig"

   wsl --shutdown
   ```
   Then restart Docker Desktop. Verify inside WSL with `free -h` (total ≈ 11–12 GiB).
2. **Enable host networking** (needed by Tuoni): Docker Desktop → **Settings →
   Resources → Network → Enable host networking** (Docker Desktop ≥ 4.34), Apply & restart.

**Then clone into your WSL2 home (not the Windows filesystem) and run:**

```bash
git clone https://github.com/jamesstammers/purple-team-lab.git
cd purple-team-lab
chmod +x *.sh
./start-lab.sh
```

First run creates `.env` from `.env.example` (edit it to change the default lab
passwords), brings up Elastic + Kibana + the Windows target, installs and enables
the detection rules, then stands up Tuoni. The Windows VM installs itself
unattended on first boot (~10–20 min) — watch at <http://localhost:8006>.

## Access

| Service | URL / command | Credentials |
|---|---|---|
| Kibana | <http://localhost:5601> | `elastic` / see `.env` |
| Elasticsearch | <http://localhost:9200> | `elastic` / see `.env` |
| Windows target (SSH) | `ssh labadmin@localhost -p 2222` | see `.env` |
| Windows target (console) | <http://localhost:8006> | — |
| Tuoni C2 | <https://localhost:12702> | `cd ~/tuoni && ./tuoni print-credentials` |

## How it works

- Static internal IPs on `172.30.0.0/24` — Elasticsearch `.10`, Kibana `.11`, Windows `.20`. The Windows target ships to `172.30.0.10:9200`; users just use `localhost`.
- `config-render` writes the Windows provisioning files from `.env`; the VM runs `install.bat` on first boot (Sysmon + Winlogbeat + OpenSSH). Guest log: `C:\lab-provision.log`.
- `rules-setup` installs + enables the prebuilt Elastic rules (needs Kibana internet the first time). Re-run any time with `./install-rules.sh`.

## Tuoni on Docker Desktop

Tuoni's server uses host networking (designed for a native Linux Docker host).
On **Docker Desktop**, enable **Settings → Resources → Network → Enable host
networking** (Docker Desktop ≥ 4.34) — a one-time setting — then re-run
`./start-lab.sh` (or `cd ~/tuoni && ./tuoni restart`).

`start-lab.sh` automatically points Tuoni's browser client at a reachable host
(`TUONI_HOST_FQDN`), so you don't need a hosts-file entry for the internal
`local-c2` alias. It uses `TUONI_FQDN` from `.env` if set, otherwise the
machine's detected IP. **Set `TUONI_FQDN` to this box's LAN IP/DNS name for team
access.** Each browser still accepts the self-signed cert once at
`https://<TUONI_FQDN>:8443`.

Get the login with `cd ~/tuoni && ./tuoni print-credentials`. To point a beacon
at the Windows target, use the Docker host's LAN IP as the callback address (not
the internal `172.30.0.x` IPs — Tuoni isn't on that network).

## Ingest mode: Winlogbeat vs Elastic Agent (Fleet)

Set `INGEST` in `.env`:

- **`winlogbeat`** (default) — one binary on the target. Simple, but Sysmon events
  land largely as raw `winlog.event_data.*` (e.g. `destination.ip` is not populated).
- **`elastic-agent`** — stands up a **Fleet Server** and enrols an **Elastic Agent**
  with the **Windows** integration. Full ECS normalisation (`destination.ip`,
  `source.ip`, `process.*`, …) and the `logs-windows.*` prebuilt rules start firing.

Switching is just:
```bash
# in .env
INGEST=elastic-agent
```
then `./start-lab.sh` (it adds `docker-compose.fleet.yml`, brings up `fleet-server`
on `:8220`, and the target enrols itself into the `pl-windows` policy on first boot).
Check enrolment in Kibana → **Fleet → Agents**, and `./status.sh` shows Fleet health
+ agent count.

Notes / caveats for Fleet mode:
- Kibana needs internet the first time to download the `fleet_server`, `windows`, and `system` integration packages.
- The target still installs **Sysmon** (the Windows integration parses the Sysmon channel — it doesn't generate the events). If Sysmon events aren't collected, enable the **Sysmon/Operational** input in Fleet → the Windows integration policy.
- Agents ship to `http://172.30.0.10:9200` and enrol against `http://172.30.0.40:8220` (insecure HTTP — lab only).
- Switching modes on an already-provisioned box won't re-run enrolment (provisioning only runs on a fresh Windows install); wipe the Windows volume to re-provision under the new mode.

## Memory (Docker Desktop / WSL2)

The Windows VM needs ≥2 GB free at boot; if WSL2 is starved you'll see
`requires at least 2.0 GB of RAM` in `docker logs pl-windows` and the container
restarts in a loop. On a 16 GB host, create `%UserProfile%\.wslconfig`:

```ini
[wsl2]
memory=12GB
processors=4
```

Then `wsl --shutdown` (PowerShell) and restart Docker Desktop. Tune footprint in
`.env` via `ES_MEM` (e.g. `1g`) and `WIN_RAM` (e.g. `3G`). On an 8 GB host, install
Windows with Tuoni stopped first, then start Tuoni.

## The `purple` CLI (optional one-liner)

Install once to drive everything with short commands from anywhere:

```bash
./purple install        # symlinks purple into /usr/local/bin (uses sudo)
```

Then:

```bash
purple start            # bring the lab up
purple stop             # stop (add --wipe to delete data)
purple restart
purple status           # health snapshot
purple rules            # (re)install + enable detection rules
purple clear-logs -y    # reset telemetry (add --alerts to clear fired alerts)
purple save clean       # snapshot the Windows target
purple revert clean     # roll back to a snapshot
purple -h               # full help
```

The underlying `*.sh` scripts still work directly if you prefer.

## Managing the lab

```bash
./status.sh            # health snapshot: containers, ES, telemetry, rules, Tuoni
./stop-lab.sh          # stop (keeps data)
./stop-lab.sh --wipe   # stop and delete the Windows disk + Elastic data
```

## Resetting telemetry between runs

To clear ingested Windows logs for a clean slate before the next attack (rules
and config are untouched; Winlogbeat recreates its index automatically):

```bash
./reset-logs.sh            # asks to confirm
./reset-logs.sh -y         # skip the prompt
./reset-logs.sh -y --alerts# also clear fired detection alerts
```

Prefer the UI? In Kibana → **Dev Tools** run `DELETE winlogbeat-*`, or use
**Stack Management → Index Management** to delete the `winlogbeat-*` indices.

## Snapshotting / reverting the Windows target

After beacons or malware have been run on the target, revert it to a clean disk
snapshot instead of reinstalling:

`start-lab.sh` **auto-saves a `clean` baseline** in the background once the
target is provisioned (telemetry flowing) — one-time, and it never overwrites an
existing baseline. Disable with `AUTO_SNAPSHOT=0` in `.env`. Manual control:

```bash
./snapshot.sh save clean       # take/replace a baseline yourself
# ...run your attacks...
./snapshot.sh restore clean    # revert to that baseline
./snapshot.sh list             # list snapshots
```

The VM is stopped for a consistent copy, then restarted; snapshots are stored in
the `pl_snapshots` Docker volume. Take the baseline **after** Windows has
installed and Sysmon/Winlogbeat are running, so a restore lands on a ready box.

Full factory reset (reinstall Windows, keep Elastic):

```bash
docker compose rm -sf windows && docker volume rm "$(docker volume ls -q | grep _win_storage)" && docker compose up -d windows
```

`start-lab.sh` shows a banner and staged progress with live spinners; on the
first run the Windows target installs in the background — use `./status.sh` to
watch telemetry start flowing.

## Notes

- Set `STACK_VERSION` in `.env` to a real Elastic tag — `start-lab.sh` validates it on pull.
- `LICENSE=trial` gives 30-day full SIEM/detection features; switch to `basic` after.
- All prebuilt rules are enabled (noisy by design). Narrow to Windows/Sysmon rules in Kibana → Security → Rules if you prefer.
- **Isolated lab use only** — this runs a C2 and generates attack telemetry on purpose. Keep it off production networks and don't expose these ports.
