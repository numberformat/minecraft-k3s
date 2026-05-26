# Minecraft Java + Bedrock on k3s

This project deploys Minecraft Java Edition servers on k3s using
`itzg/minecraft-server:latest` with:

- `TYPE=PAPER`
- `VERSION=1.21.11`
- Geyser for Bedrock protocol support
- Floodgate for Bedrock authentication
- a per-instance `hostPath` PV and PVC mounted at `/data`
- one `LoadBalancer` Service per instance exposing both Java and Bedrock ports

The Kubernetes structure stays the same as the earlier Bedrock-only version:

- namespace-local Deployment and Service
- per-instance static PV/PVC
- per-instance values file under `clusters/<cluster>/instances/`
- idempotent `install.sh` driven by `envsubst`

This repo is already plain Kubernetes manifests. It does not use Helm.

## Files

```text
setup.sh                      Create an instance config
install.sh                    Install or update one instance
status.sh                     Show configured instances and live Kubernetes status
uninstall.sh                  Remove one instance's Kubernetes resources
import_world.sh               Import server data or one world into an instance
export_world.sh               Export one instance's /data as a tar.gz file
export_allowlist.sh           Export /data/whitelist.json from an instance
import_allowlist.sh           Import /data/whitelist.json into an instance
backup.sh                     Back up all instances to MinIO
lib/clusters.sh               Resolve current cluster from ../noami-k3s
k8s/                          Kubernetes manifests rendered with envsubst
clusters/<cluster>/instances/ Per-instance values.env files
instances/                    Legacy single-cluster fallback
examples/values.yaml
MIGRATION.md
```

## Multi-Cluster Usage

The repo now follows the same cluster-aware pattern as the rest of the stack.

Examples:

```bash
./setup.sh --cluster homelab
./install.sh --cluster homelab minecraft3
./status.sh --cluster homelab
```

If `--cluster` is omitted, the scripts try to resolve the current cluster from
`../noami-k3s/.current-cluster`.

## What Gets Deployed

For each instance, `install.sh` applies:

- Namespace
- PersistentVolume
- PersistentVolumeClaim
- Deployment
- LoadBalancer Service

The Deployment runs:

```text
image: itzg/minecraft-server:latest
type: PAPER
data mount: /data
plugins persisted in: /data/plugins
java container port: 25565/tcp
bedrock container port: 19132/udp
```

The container auto-downloads these plugins at startup using the image's supported `PLUGINS` mechanism:

- Geyser-Spigot
- Floodgate-Spigot

## Requirements

Local tools:

```bash
kubectl
envsubst
tar
```

Cluster requirements:

- k3s cluster reachable by `kubectl`
- ServiceLB enabled, or another `LoadBalancer` implementation that supports mixed TCP and UDP ports
- at least one node labeled for Minecraft, default label `minecraft=true`
- router or firewall rules for Java TCP and Bedrock UDP if clients connect from outside the LAN

The scripts can resolve the kubeconfig automatically from `noami-k3s`, but
manual `kubectl` work still benefits from:

```bash
source ../noami-k3s/profile.sh
kubectl get nodes
```

## Create an Instance

Run:

```bash
./setup.sh --cluster homelab
```

The script writes:

```text
clusters/<cluster>/instances/<instance>/values.env
```

New configs now include both external ports:

- `JAVA_PORT` for Java Edition clients over TCP
- `BEDROCK_PORT` for Bedrock clients over UDP through Geyser

The setup defaults are:

- `TYPE=PAPER`
- `VERSION=1.21.11`
- `MEMORY=4G`
- `ENABLE_RCON=true`
- `DIFFICULTY=normal`
- `MODE=survival`
- `PVP=true`
- `ENABLE_WHITELIST=false`
- `ONLINE_MODE=false`

`ONLINE_MODE=false` is intentional. Floodgate works by allowing Bedrock-authenticated users to join the Java server without requiring a paid Java account login on the backend Paper server.

Run `./setup.sh` again with a different instance name to create another server. The script suggests the next unused Java port starting from `25565` and the next unused Bedrock port starting from `19132`.

To see configured instance names and ports later:

```bash
./status.sh
```

## Install or Update an Instance

Run:

```bash
./install.sh --cluster homelab <instance>
```

Example:

```bash
./setup.sh --cluster homelab
./install.sh --cluster homelab minecraft1
```

The Service exposes both protocols:

```text
service/minecraft-<instance> TCP <JAVA_PORT> -> pod TCP 25565
service/minecraft-<instance> UDP <BEDROCK_PORT> -> pod UDP 19132
```

Connectivity differs by client type:

- Java Edition clients connect to `<host>:<JAVA_PORT>`
- Bedrock Edition clients connect to `<host>:<BEDROCK_PORT>`

Java and Bedrock do not share a protocol. Java speaks directly to Paper on TCP `25565`. Bedrock speaks to Geyser on UDP `19132`, and Geyser bridges that traffic into the Java server.

UDP `19132` must remain exposed because that is the Bedrock-facing listener used by Geyser. Without it, Java clients will still work, but Bedrock clients will not.

## Storage

Each instance uses a static `hostPath` PersistentVolume and a matching PersistentVolumeClaim:

```text
/data/minecraft/<instance>
```

The pod mounts `/data` from PVC `minecraft-<instance>-data`, which is bound to PV `minecraft-<instance>-pv` for that host path.

The pod and PV are pinned to nodes with the selected label key and value `true`.

Default:

```bash
kubectl label node <node-name> minecraft=true --overwrite
```

The host path is created with `DirectoryOrCreate`, but you can pre-create it if you need explicit ownership:

```bash
sudo mkdir -p /data/minecraft/<instance>
sudo chown -R 1000:1000 /data/minecraft/<instance>
```

## Status

Show configured instances and their live status:

```bash
./status.sh --cluster homelab
```

This prints:

- instance name
- Java and Bedrock external ports
- namespace and subdomain
- data path and storage size
- Deployment readiness
- Service ports and external endpoint
- PVC and PV status
- pod phase, readiness, restart count, and node

## World Import and Export

`export_world.sh` exports one instance's full `/data` directory to a local
`.tar.gz` file:

```bash
./export_world.sh --cluster homelab <instance> <output-tar.gz>
```

`import_world.sh` imports either:

- a full server data directory or `.tar.gz` archive into `/data`
- a single world into `/data/worlds/<name>`

```bash
./import_world.sh --cluster homelab <instance> <source-path-or-tar.gz>
```

Both scripts are multi-instance aware and target the instance name from `instances/<instance>/values.env`.

## Whitelist Import and Export

Export the current Java whitelist:

```bash
./export_allowlist.sh --cluster homelab <instance> <output-json>
```

Import a whitelist file back into the instance:

```bash
./import_allowlist.sh --cluster homelab <instance> <source-json>
```

The helper script names are unchanged for compatibility, but they now operate on `/data/whitelist.json`.

## Backup

Back up all configured instances to MinIO:

```bash
export MINIO_ENDPOINT=https://minio.example.com
export MINIO_ACCESS_KEY=...
export MINIO_SECRET_KEY=...
export MINIO_BUCKET=minecraft-backups
./backup.sh --cluster homelab
```

## Backup Boundary

Minecraft is a stateful app.

The durable app state is the full `/data` directory for each instance. That
includes:

- world data
- `server.properties`
- plugins and plugin configs
- whitelist and player data
- generated Paper/Geyser/Floodgate state

That means the app-scoped backup boundary is simple:

- back up the full `/data` directory per instance
- restore the full `/data` directory per instance

The existing repo already does that in two ways:

- `export_world.sh` and `import_world.sh` for local tarball export/import
- `backup.sh` for MinIO-backed per-instance archive export

Because the server uses a hostPath PV under `/data/minecraft/<instance>`, you may
also choose to rely on host-level backups of that directory. If you do, be clear
which mechanism is authoritative:

- host-level backup of `/data/minecraft/<instance>`
- or app-level MinIO/tarball export from this repo

## Uninstall

Run:

```bash
./uninstall.sh --cluster homelab
```

The script asks separately before deleting:

- Deployment and Service
- PVC
- PV
- host files under `/data/minecraft/<instance>`

Deleting the PV removes only the Kubernetes PV object. Deleting the host files is the step that actually removes the saved world and plugin data from disk.

## Migration

If you already have Bedrock-era instance configs, read [MIGRATION.md](./MIGRATION.md) before reinstalling them. The important change is that migrated instances need a `JAVA_PORT` if you want more than one Java/Paper server exposed at the same time.

## Useful Checks

Show Minecraft resources:

```bash
kubectl -n apps get deploy,pod,svc,pvc -l app.kubernetes.io/name=minecraft-bedrock -o wide
```

Show one instance logs:

```bash
kubectl -n apps logs deploy/minecraft-<instance> --tail=100
```

Show Services and external IPs:

```bash
kubectl -n apps get svc -l app.kubernetes.io/name=minecraft-bedrock -o wide
```
