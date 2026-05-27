# xeinoria-server-configs

Versioned Paper server configurations for the Xeinoria Minecraft network.

## Layout
One folder per server: `crea/`, `hub/`, `nwland/`, `survie/`, `test/`.
Each contains the safe-to-publish config files (start.sh, server.properties,
*.yml, eula.txt, config/paper-world-defaults.yml).

## What is EXCLUDED (and why)
- `config/paper-global.yml` → contains the Velocity forwarding secret.
- `ops.json`, `whitelist.json`, `banned-*.json`, `usercache.json` → moderation data with player UUIDs.
- `plugins/`, `world*/`, `logs/`, `cache/`, `libraries/`, `versions/`, `crash-reports/`, `backups/`, `bluemap/` → runtime data, often huge, can be regenerated.
- `*.jar`, `*.zip`, `server-icon.png` → binaries.
- In `server.properties`: the `management-server-secret=` value is replaced with `<REDACTED-SET-LOCALLY>`. The real value lives only on the live server.

## Workflow
This repo is **versioning only** — there is **no auto-deploy to the live servers**, because Paper config changes typically require a server restart.

To capture the current live state into the repo: run [build.sh](./build.sh).
To apply a change from the repo to a server: copy the file by hand and restart the server.
