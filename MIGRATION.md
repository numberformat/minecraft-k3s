# Migration Notes

This project now deploys Java Edition `itzg/minecraft-server:latest` with `TYPE=PAPER` and Bedrock compatibility via Geyser and Floodgate.

It is also now cluster-aware:

- active instance configs live under `clusters/<cluster>/instances/`
- the old top-level `instances/` directory is treated as a legacy fallback

## What changed

- The runtime image changed from `itzg/minecraft-bedrock-server:latest` to `itzg/minecraft-server:latest`.
- The server version is pinned to Java `1.21.11` so the bundled Paper target stays compatible with current Geyser support.
- The pod now exposes:
  - Java clients on container TCP `25565`
  - Bedrock clients on container UDP `19132`
- The Service now exposes both protocols.
- `setup.sh` now writes:
  - `JAVA_PORT`
  - `BEDROCK_PORT`
  - Java Edition settings such as `MODE`, `LEVEL`, `SIMULATION_DISTANCE`, `MEMORY`, `ENABLE_RCON`, `PVP`, and `ENABLE_WHITELIST`

## Existing instances

Existing Bedrock-era `instances/<instance>/values.env` files can still be read by `install.sh` through compatibility fallbacks, but they do not contain `JAVA_PORT`.

Important:

- a migrated instance without `JAVA_PORT` defaults to external Java port `25565`
- that is fine for a single migrated instance
- if you will run multiple migrated instances, assign each instance a unique `JAVA_PORT`

The simplest path is:

1. Re-run `./setup.sh` for new instances created after this migration.
2. For existing instances, either:
   - add `JAVA_PORT=<unique-port>` manually to `instances/<instance>/values.env`, or
   - recreate the instance config with the new `setup.sh`

## Connectivity

- Java Edition players connect to `<host>:<JAVA_PORT>` over TCP.
- Bedrock Edition players connect to `<host>:<BEDROCK_PORT>` over UDP.
- `ONLINE_MODE=false` is intentional so Floodgate-authenticated Bedrock identities can join the Paper server.

## Plugin persistence

Plugins remain persistent under `/data/plugins`, which is inside the existing PVC-backed `/data` mount.
