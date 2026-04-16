# Minecraft Bedrock on k3s

This project deploys multiple Minecraft Bedrock servers on a k3s cluster using direct k3s `LoadBalancer` Services.

It replaces a single Docker command like this:

```bash
docker run -d -it \
  -e EULA=TRUE \
  --name minecraft \
  -p 19132:19132/udp \
  -v /home/verma/data/minecraft_server:/data \
  itzg/minecraft-bedrock-server
```

with reusable Kubernetes instances:

```text
instances/<instance>/values.env
hostPath /data/minecraft/<instance> -> container /data
k3s LoadBalancer Service UDP <external-port> -> Minecraft pod UDP 19132
```

## Important Bedrock Routing Rule

Minecraft Bedrock uses UDP, not HTTP.

There is no hostname or subdomain routing for Bedrock. Each server instance needs a unique external UDP port.

Example:

```text
minecraft1 -> UDP 19132
minecraft2 -> UDP 19133
minecraft3 -> UDP 19134
```

The `SUBDOMAIN` value is stored for documentation and future compatibility only. It is not used for routing.

For public access, your router must port-forward each UDP port to a k3s node or stable ServiceLB/VIP address:

```text
WAN UDP 19132 -> k3s node/VIP UDP 19132
WAN UDP 19133 -> k3s node/VIP UDP 19133
WAN UDP 19134 -> k3s node/VIP UDP 19134
```

## Why Not Traefik

Earlier versions of this project used Traefik `IngressRouteUDP`. That worked, but it required modifying the shared k3s Traefik Helm configuration for every Minecraft instance.

Minecraft Bedrock is simpler as a direct UDP LoadBalancer Service:

```text
client UDP 19133
-> k3s LoadBalancer Service minecraft-test2 UDP 19133
-> pod UDP 19132
```

`noami-routes` remains responsible for HTTP/HTTPS routes. Minecraft does not need it.

## Files

```text
setup.sh              Create an instance config
install.sh            Install or update one instance
uninstall.sh          Remove one instance's Kubernetes resources
import_world.sh       Import server data or one world into an instance
export_world.sh       Export one instance's /data as a tar.gz file
export_allowlist.sh   Export /data/allowlist.json from an instance
import_allowlist.sh   Validate and import /data/allowlist.json into an instance
backup.sh             Back up all instances to MinIO
templates/            Kubernetes templates rendered with envsubst
instances/            Per-instance values.env files
```

## Requirements

Local tools:

```bash
kubectl
envsubst
tar
```

Cluster requirements:

- k3s cluster reachable by `kubectl`
- ServiceLB enabled, or another LoadBalancer implementation that supports UDP
- at least one node labeled for Minecraft, default label `minecraft=true`
- router UDP port forwarding for public access

Load kubeconfig before running cluster commands:

```bash
source ../noami-k3s/profile.sh
kubectl get nodes
```

## Create an Instance

Run:

```bash
./setup.sh
```

The script asks for:

- instance name
- external UDP port, with the next available port suggested from `19132`
- optional subdomain, stored only for documentation
- node label key, default `minecraft`
- storage size, default `10Gi`
- Minecraft server settings such as game mode, difficulty, level name, seed, max players, online mode, view distance, and tick distance

It writes:

```text
instances/<instance>/values.env
```

Then install it:

```bash
./install.sh <instance>
```

Example:

```bash
./setup.sh
./install.sh minecraft1
```

## Node Label and Storage

Each instance uses a hostPath PersistentVolume:

```text
/data/minecraft/<instance>
```

The pod and PV are pinned to nodes with the selected label key and value `true`.

Default:

```bash
kubectl label node <node-name> minecraft=true --overwrite
```

The hostPath is created by Kubernetes with `DirectoryOrCreate`, but you can create it manually if you need explicit ownership:

```bash
sudo mkdir -p /data/minecraft/<instance>
sudo chown -R 1000:1000 /data/minecraft/<instance>
```

## Install or Update an Instance

Run:

```bash
./install.sh <instance>
```

This renders and applies:

- Namespace
- PersistentVolume
- PersistentVolumeClaim
- Deployment
- LoadBalancer Service

The Deployment uses:

```text
image: itzg/minecraft-bedrock-server:latest
container UDP port: 19132
mount: /data
strategy: Recreate
health checks: mc-monitor status-bedrock --host 127.0.0.1
```

The Service is `LoadBalancer` and maps the configured external UDP port to the pod's internal Bedrock port:

```text
service/minecraft-<instance> UDP <PORT> -> pod UDP 19132
```

For example:

```text
minecraft-test  UDP 19132 -> pod UDP 19132
minecraft-test2 UDP 19133 -> pod UDP 19132
```

Verify Services:

```bash
kubectl -n apps get svc -l app.kubernetes.io/name=minecraft-bedrock -o wide
```

## DNS and Router Port Forwarding

DNS can point all Minecraft names to the same public IP:

```text
minecraft1.test-domain.com -> your public IP
minecraft2.test-domain.com -> your public IP
```

Bedrock still routes by port:

```text
minecraft1.test-domain.com:19132
minecraft2.test-domain.com:19133
```

If connecting from inside the LAN, you can also use internal DNS to point the names directly at a k3s node or stable ServiceLB/VIP address.

For public access, configure router port forwards with UDP, not TCP:

```text
WAN UDP 19132 -> k3s node/VIP UDP 19132
WAN UDP 19133 -> k3s node/VIP UDP 19133
```


## Allowlist Management

Minecraft Bedrock uses `allowlist.json` to restrict which players can join when the server allowlist is enabled. Older Bedrock settings and tools may still use the word `whitelist`; in this context, whitelist and allowlist mean the same access-control concept. `allowlist` is the newer term, while `white-list` is still the server.properties setting name used by Bedrock.

Enable allowlist during setup by answering `true` here:

```text
Enable allowlist/whitelist: true or false [false]: true
```

That writes this instance value:

```bash
WHITE_LIST=true
```

To export the current allowlist:

```bash
./export_allowlist.sh <instance> <output-json>
```

Example:

```bash
./export_allowlist.sh test ./allowlist-test.json
```

Edit the JSON locally. A typical file looks like:

```json
[
  {
    "name": "PlayerName",
    "ignoresPlayerLimit": false
  }
]
```

Then import it back into the instance:

```bash
./import_allowlist.sh <instance> <source-json>
```

Example:

```bash
./import_allowlist.sh test ./allowlist-test.json
```

`import_allowlist.sh` validates the JSON, scales the server down, replaces `/data/allowlist.json`, and restores the previous replica count.

## Import Worlds

`import_world.sh` imports either a directory or a `.tar.gz` archive.

Usage:

```bash
./import_world.sh <instance> <source-path-or-tar.gz>
```

Examples:

```bash
./import_world.sh test /Users/verma/data/minecraft_server
./import_world.sh test "/Users/verma/data/minecraft_server/worlds/Bedrock level"
./import_world.sh test /Users/verma/backups/minecraft-test-20260416.tar.gz
```

Accepted source layouts:

Full Bedrock server data:

```text
server.properties
worlds/
behavior_packs/
resource_packs/
...
```

This replaces the instance PVC `/data` contents.

Single Bedrock world:

```text
db/
level.dat
levelname.txt
```

This imports into:

```text
/data/worlds/<source-directory-or-archive-name>
```

The import script scales the instance to zero, streams files through a temporary pod, fixes Bedrock binary execute permissions for full server-data imports, then scales the instance back up.

## Export Worlds

`export_world.sh` exports one instance's full `/data` directory to a local `.tar.gz` file.

Usage:

```bash
./export_world.sh <instance> <output-tar.gz>
```

Example:

```bash
mkdir -p /Users/verma/backups
./export_world.sh test /Users/verma/backups/minecraft-test-20260416.tar.gz
```

The output file must not already exist, and the parent directory must exist.

The script scales the instance to zero for a consistent snapshot, mounts the PVC read-only in a temporary pod, streams `/data` to the requested file, then restores the previous replica count.

## Back Up All Instances to MinIO

`backup.sh` iterates over every instance in `instances/` and streams each `/data` directory to MinIO without temp files.

Required environment variables:

```bash
export MINIO_ENDPOINT=https://minio.example.com
export MINIO_ACCESS_KEY=...
export MINIO_SECRET_KEY=...
export MINIO_BUCKET=minecraft-backups
```

Run:

```bash
./backup.sh
```

Backup object names look like:

```text
world-<instance>-<timestamp>.tar.gz
```

The script scales each deployment to zero before backup and scales it back to one afterward.

## Uninstall an Instance

Run:

```bash
./uninstall.sh
```

The script prints instances that still have live Kubernetes resources or a retained PV. Deleted instances whose PVC and PV are both gone are removed from the local `instances/` directory and no longer appear in the menu.

The menu status values are:

- `installed`: Deployment, Service, or PVC still exists
- `deleted-pv-retained`: workload and PVC are gone, but the retained PV object still exists

For the selected instance, the script asks before deleting:

- Deployment and Service
- PVC
- PV

Deleting the PV removes only the Kubernetes PV object. The script then asks separately whether to delete the hostPath files under `/data/minecraft/<instance>`. Answering yes permanently removes the world files from the storage node by running a temporary cleanup pod pinned to a Minecraft node. The script refuses to delete paths outside `/data/minecraft/*`.

## Useful Checks

Show Minecraft resources:

```bash
kubectl -n apps get deploy,pod,svc,pvc -l app.kubernetes.io/name=minecraft-bedrock -o wide
```

Show one instance logs:

```bash
kubectl -n apps logs deploy/minecraft-<instance> --tail=100
```

Show ServiceLB pods:

```bash
kubectl -n kube-system get pods -l app=svclb-minecraft-<instance>
```

Show Services and external IPs:

```bash
kubectl -n apps get svc -l app.kubernetes.io/name=minecraft-bedrock -o wide
```

## Common Issues

### Direct IP works, DNS name does not

If direct LAN IP works but `minecraft.test-domain.com` does not, DNS probably resolves to the public WAN IP and the router is not forwarding the UDP port to a k3s node or VIP.

Check DNS:

```bash
dig +short minecraft.test-domain.com
```

For public DNS, add router UDP port forwarding.

For LAN-only use, add an internal DNS override pointing the name to a k3s node or stable ServiceLB/VIP address.

### Pod stays Pending

Check that a node has the required label:

```bash
kubectl get nodes --show-labels | grep minecraft
```

Add it if needed:

```bash
kubectl label node <node-name> minecraft=true --overwrite
```

### Service does not get an external IP or port does not answer

Check the LoadBalancer Service and ServiceLB pods:

```bash
kubectl -n apps get svc minecraft-<instance> -o wide
kubectl -n kube-system get pods | grep svclb-minecraft
```

If another Service is already using the same UDP port, ServiceLB cannot bind it. Each Minecraft instance must use a unique external port.

### Import from macOS/NFS has metadata warnings

The import script uses:

```bash
COPYFILE_DISABLE=1 tar --no-xattrs
```

This avoids macOS extended attribute noise and streams only the useful file contents.
