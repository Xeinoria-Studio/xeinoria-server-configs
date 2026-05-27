#!/usr/bin/env bash
# Refresh this repo's content from /home/debian/xeinoria/<server>/ for each server.
# Safe to re-run; redacts secrets before committing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC=/home/debian/xeinoria
SERVERS=(crea hub nwland survie test)
FILES=(start.sh server.properties bukkit.yml spigot.yml commands.yml help.yml permissions.yml wepif.yml eula.txt config/paper-world-defaults.yml)

for s in "${SERVERS[@]}"; do
  mkdir -p "$ROOT/$s/config"
  for f in "${FILES[@]}"; do
    [[ -f "$SRC/$s/$f" ]] && cp -p "$SRC/$s/$f" "$ROOT/$s/$f"
  done
  if [[ -f "$ROOT/$s/server.properties" ]]; then
    sed -i -E 's/^(management-server-secret=).*/\1<REDACTED-SET-LOCALLY>/' "$ROOT/$s/server.properties"
  fi
  # scripts/ : only *.sh and *.txt (no dotfiles, no .log)
  if [[ -d "$SRC/$s/scripts" ]]; then
    mkdir -p "$ROOT/$s/scripts"
    # clear stale entries (only files matching the whitelist would exist anyway)
    find "$ROOT/$s/scripts" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.txt' \) -delete 2>/dev/null || true
    find "$SRC/$s/scripts" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.txt' \) \
      -exec cp -p {} "$ROOT/$s/scripts/" \;
  fi
done
echo "Repo refreshed from live. Review with: git -C \"$ROOT\" diff"
