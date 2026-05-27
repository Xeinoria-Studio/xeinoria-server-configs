#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/scripts/backup_worlds.sh"
BACKUP_SUMMARY_FILE="${SCRIPT_DIR}/backups/worlds/.last_backup_summary"

if [[ -f "${BACKUP_SUMMARY_FILE}" ]]; then
    read -r last_backup_size_bytes last_backup_elapsed_seconds < "${BACKUP_SUMMARY_FILE}" || true
    if [[ "${last_backup_elapsed_seconds:-}" =~ ^[0-9]+$ ]]; then
        minutes=$((last_backup_elapsed_seconds / 60))
        seconds=$((last_backup_elapsed_seconds % 60))
        echo "[backup] Derniere sauvegarde: ${minutes}m${seconds}s pour ${last_backup_size_bytes:-0} octets. Le demarrage peut prendre plusieurs minutes."
    fi
fi

while true; do
    if [[ -x "${BACKUP_SCRIPT}" ]]; then
        "${BACKUP_SCRIPT}" || echo "[backup] Echec du backup au demarrage, lancement du serveur maintenu."
    else
        echo "[backup] Script introuvable ou non executable: ${BACKUP_SCRIPT}"
    fi

    java -server -Xms6G -Xmx6G -Xss512k \
        -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 \
        -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch \
        -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M \
        -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 \
        -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 \
        -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 \
        -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 \
        -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true \
        -jar paper.jar nogui

    echo "If you want to completely stop the server process now, press Ctrl+C before the time is up!"
    echo "Rebooting in:"
    for i in 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1;
    do
        echo "$i..."
        sleep 1
    done
    echo "Rebooting now!"
done;
