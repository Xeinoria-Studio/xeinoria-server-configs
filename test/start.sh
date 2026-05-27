while true; do

# Load shared environment (REDIS_PASSWORD, *_DB_PASSWORD, ...).
# File is chmod 600 and lives OUTSIDE any git repo. Read by Skript via
# skript-reflect: import java.lang.System; System.getenv("REDIS_PASSWORD")
XEINORIA_ENV_FILE="${XEINORIA_ENV_FILE:-/home/debian/xeinoria/.env.shared}"
if [[ -r "${XEINORIA_ENV_FILE}" ]]; then
    set -a; . "${XEINORIA_ENV_FILE}"; set +a
fi

    java -server -Xms1G -Xmx1G -jar paper.jar nogui

    echo "If you want to completely stop the server process now, press Ctrl+C before the time is up!"
    echo "Rebooting in:"
    for i in 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1;
    do
        echo "$i..."
        sleep 1
    done
    echo "Rebooting now!"
done;
