#!/usr/bin/env bash
# ==============================================================================
#  XEINORIA - Export public de la map survie
#
#  - Zippe le monde (sv/) en UN SEUL dossier vanilla-ready :
#       xeinoria-survie-world/   (1 monde, dimensions/minecraft/{overworld,
#                                 the_nether,the_end})
#  - Suit la procedure officielle Paper -> Vanilla 26.1+ :
#       https://docs.papermc.io/paper/migration/#to-vanilla
#       * On conserve l'arbo dimensions/minecraft/* telle quelle
#       * On deplace 5 fichiers (game_rules, scheduled_events, wandering_trader,
#         weather, world_gen_settings) depuis dimensions/minecraft/overworld/
#         data/minecraft/ vers data/minecraft/ a la racine du monde
#       * On supprime data/paper/ et paper-world.yml (specifique Paper)
#  - Filtrage confidentialite : players/ (advancements, playerdata, stats) et
#    data/minecraft/scoreboard.dat sont exclus.
#  - Injecte LICENSE.txt + README.txt + VERSION.txt + AUTHORS.txt en tete.
#  - Ne touche JAMAIS au monde live (zip est read-only sur la source).
#  - Coordonne avec Paper via "save-off" / "save-on" (best-effort, via flag
#    file lu par le Skript map-export.sk si le serveur tourne).
#  - Genere un nom date + un symlink "latest".
#  - Met a jour un manifest JSON consomme par le site norath.fr.
#  - Prune les anciennes versions selon KEEP_VERSIONS et MIN_FREE_GB.
#
#  Le repertoire de publication est INTENTIONNELLEMENT en dehors du dossier
#  Minecraft pour eviter toute exposition de la racine serveur via nginx.
#
#  Usage:
#     ./export_map.sh run            # genere une nouvelle version
#     ./export_map.sh list           # liste les versions publiees
#     ./export_map.sh prune          # supprime les versions excedentaires
#     ./export_map.sh enable         # active la mise a dispo publique
#     ./export_map.sh disable        # desactive la mise a dispo publique
#     ./export_map.sh status         # etat du dernier export
#     ./export_map.sh cron_tick      # appele par cron (decide auto-run)
#     ./export_map.sh config get K   # lit une cle de config
#     ./export_map.sh config set K V # ecrit une cle de config
#     ./export_map.sh config dump    # affiche toute la config
# ==============================================================================
#
#  Fichier de configuration partage avec Skript (KEY=VALUE) :
#     /home/debian/xeinoria/survie/scripts/.mapexport_config
#  Cles :
#     auto_frequency = disabled | daily | weekly | monthly
#     keep_versions  = 1..5
#     last_auto_run  = epoch (gere automatiquement)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORLD_DIR="${SERVER_DIR}/sv"
CONFIG_FILE="${SCRIPT_DIR}/.mapexport_config"

# Valeurs par defaut (utilisees si la cle est absente du fichier)
CFG_DEFAULT_auto_frequency="monthly"
CFG_DEFAULT_keep_versions="2"
CFG_DEFAULT_last_auto_run="0"

# Destination publique (hors arborescence Minecraft, servie par nginx).
# Sous /srv/ pour permettre a www-data de traverser (home/debian est en 700).
PUBLISH_ROOT="${XEINORIA_DOWNLOAD_ROOT:-/srv/xeinoria-downloads}"
SURVIE_PUBLISH_DIR="${PUBLISH_ROOT}/survie"
TMP_DIR="${PUBLISH_ROOT}/.tmp"
MANIFEST_FILE="${SURVIE_PUBLISH_DIR}/manifest.json"
ENABLE_FLAG="${SURVIE_PUBLISH_DIR}/.enabled"
LOCK_FILE="${PUBLISH_ROOT}/.export.lock"
PROGRESS_FILE="${SCRIPT_DIR}/.export_progress"
CANCEL_FILE="${SCRIPT_DIR}/.export_cancel"
PID_FILE="${SCRIPT_DIR}/.export_pid"
EXPORT_PLAYER=""  # Nom du joueur declencheur (optionnel, setté par cmd_run)

# Coordination avec le serveur Paper (lus/ecrits par map-export.sk)
SAVE_OFF_REQUEST="${SCRIPT_DIR}/.export_save_off_request"
SAVE_OFF_DONE="${SCRIPT_DIR}/.export_save_off_done"
SAVE_ON_REQUEST="${SCRIPT_DIR}/.export_save_on_request"

# Nom de l'archive
SERVER_NAME="xeinoria"
MAP_NAME="survie-map"
WORLD_FOLDER_IN_ZIP="xeinoria-survie-world"

# Politique de retention (KEEP_VERSIONS peut etre redefini par la config)
KEEP_VERSIONS="${KEEP_VERSIONS:-2}"     # nb de versions datees a garder
MIN_FREE_GB="${MIN_FREE_GB:-15}"        # plancher d'espace libre apres export
SAVE_OFF_WAIT_SECONDS="${SAVE_OFF_WAIT_SECONDS:-90}"
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"  # 0-9, 6 = bon ratio/vitesse pour MC

log() { printf '[mapexport][%s] %s\n' "$(date +'%F %T')" "$*"; }
err() { log "ERREUR: $*" >&2; }

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Commande requise introuvable: $1"
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "${SURVIE_PUBLISH_DIR}" "${TMP_DIR}"
}

filesystem_free_bytes() {
    df -PB1 "${PUBLISH_ROOT}" | awk 'NR==2 { print $4 }'
}

human_size() {
    numfmt --to=iec --suffix=B --format='%.2f' "$1" 2>/dev/null || echo "${1}B"
}

eta_format() {
    local s="${1:-0}"
    if (( s <= 0 )); then printf 'calcul...'; return; fi
    if (( s >= 3600 )); then
        printf '%dh %02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
    elif (( s >= 60 )); then
        printf '%dm %02ds' $(( s / 60 )) $(( s % 60 ))
    else
        printf '%ds' "${s}"
    fi
}

# Ecrit (de facon atomique) le fichier de progression lu par map-export.sk.
# Necessite que 'started_at' soit defini en scope global avant l'appel.
progress_write() {
    local phase="${1:-unknown}" current="${2:-0}" total="${3:-0}" pct="${4:-0}" eta="${5:-0}"
    local elapsed=$(( $(date +%s) - ${started_at:-0} ))
    (( elapsed < 0 )) && elapsed=0
    printf 'phase=%s\npid=%s\ntotal_files=%s\ncurrent_files=%s\npct=%s\nelapsed=%s\neta_seconds=%s\nplayer=%s\n' \
        "${phase}" "$$" "${total}" "${current}" "${pct}" "${elapsed}" "${eta}" "${EXPORT_PLAYER:-}" \
        > "${PROGRESS_FILE}.tmp" 2>/dev/null || return 0
    mv -f "${PROGRESS_FILE}.tmp" "${PROGRESS_FILE}" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
#  Configuration partagee (lue/ecrite aussi par le Skript)
# ------------------------------------------------------------------------------
# Format: une cle=valeur par ligne, sans guillemets. Cles inconnues ignorees.
# Cles valides: auto_frequency, keep_versions, last_auto_run

config_validate_key() {
    case "$1" in
        auto_frequency|keep_versions|last_auto_run) return 0 ;;
        *) return 1 ;;
    esac
}

config_validate_value() {
    # $1 = key, $2 = value
    case "$1" in
        auto_frequency)
            case "$2" in
                disabled|daily|weekly|monthly) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        keep_versions)
            [[ "$2" =~ ^[1-5]$ ]] && return 0 || return 1
            ;;
        last_auto_run)
            [[ "$2" =~ ^[0-9]+$ ]] && return 0 || return 1
            ;;
    esac
    return 1
}

config_get() {
    local key="$1"
    local val=""
    if [[ -f "${CONFIG_FILE}" ]]; then
        # Recupere la DERNIERE occurrence (les writes append puis re-trim)
        val="$(grep -E "^${key}=" "${CONFIG_FILE}" 2>/dev/null \
            | sed -n '$s/^[^=]*=//p')" || val=""
    fi
    if [[ -z "$val" ]]; then
        local def_var="CFG_DEFAULT_${key}"
        val="${!def_var:-}"
    fi
    printf '%s\n' "$val"
}

config_set() {
    local key="$1" val="$2"
    if ! config_validate_key "$key"; then
        err "config: cle invalide: ${key}"
        return 1
    fi
    if ! config_validate_value "$key" "$val"; then
        err "config: valeur invalide pour ${key}: ${val}"
        return 1
    fi
    ensure_dirs
    local tmp="${CONFIG_FILE}.tmp.$$"
    # Recopie le fichier en remplacant/ajoutant la cle
    {
        if [[ -f "${CONFIG_FILE}" ]]; then
            grep -vE "^${key}=" "${CONFIG_FILE}" || true
        fi
        printf '%s=%s\n' "$key" "$val"
    } > "$tmp"
    mv -f "$tmp" "${CONFIG_FILE}"
    chmod 644 "${CONFIG_FILE}" 2>/dev/null || true
}

config_dump() {
    for k in auto_frequency keep_versions last_auto_run; do
        printf '%s=%s\n' "$k" "$(config_get "$k")"
    done
}

# Recharge KEEP_VERSIONS depuis la config (appele avant prune)
config_reload_keep_versions() {
    local v
    v="$(config_get keep_versions)"
    if [[ "$v" =~ ^[1-5]$ ]]; then
        KEEP_VERSIONS="$v"
    fi
}

# ------------------------------------------------------------------------------
#  Publication des fichiers META (LICENSE / README) dans le dir public
# ------------------------------------------------------------------------------
publish_meta_files() {
    ensure_dirs
    if [[ -f "${SCRIPT_DIR}/export_map_LICENSE.txt" ]]; then
        cp -f "${SCRIPT_DIR}/export_map_LICENSE.txt" "${SURVIE_PUBLISH_DIR}/LICENSE.txt"
        chmod 644 "${SURVIE_PUBLISH_DIR}/LICENSE.txt"
    fi
    if [[ -f "${SCRIPT_DIR}/export_map_README.txt" ]]; then
        cp -f "${SCRIPT_DIR}/export_map_README.txt" "${SURVIE_PUBLISH_DIR}/README.txt"
        chmod 644 "${SURVIE_PUBLISH_DIR}/README.txt"
    fi
}

# ------------------------------------------------------------------------------
#  Coordination save-off / save-on
# ------------------------------------------------------------------------------
# Fonction de nettoyage appelee par le trap EXIT de cmd_run (erreur, signal, annulation).
# Appel idempotent : inoffensif si deja en etat terminal.
_cmd_run_cleanup() {
    rm -f "${PID_FILE}" "${CANCEL_FILE}" 2>/dev/null || true
    # Marque 'failed' uniquement si pas deja dans un etat terminal
    local cur_phase=""
    if [[ -f "${PROGRESS_FILE}" ]]; then
        cur_phase="$(grep '^phase=' "${PROGRESS_FILE}" 2>/dev/null \
            | sed 's/^phase=//' | head -1 || echo '')"
    fi
    if [[ "${cur_phase}" != "done" && "${cur_phase}" != "cancelled" ]]; then
        started_at="${started_at:-$(date +%s)}"
        progress_write "failed" 0 "${total_files:-0}" 0 0 || true
    fi
    request_save_on
}

# On signale au Skript de demander save-off, puis on attend que le Skript
# confirme par un fichier _done. Si rien n'arrive (serveur eteint), on continue
# quand meme : le monde est sur disque, et lire les region files pendant que
# Paper ecrit n'est pas catastrophique (zip recree des copies, l'original
# reste intact); par precaution Paper utilise un journal et auto-resauvegarde.

request_save_off() {
    rm -f "${SAVE_OFF_DONE}" "${SAVE_OFF_REQUEST}" "${SAVE_ON_REQUEST}"
    touch "${SAVE_OFF_REQUEST}"
    log "Demande save-off envoyee au serveur (flag: ${SAVE_OFF_REQUEST})."

    local waited=0
    while (( waited < SAVE_OFF_WAIT_SECONDS )); do
        if [[ -f "${SAVE_OFF_DONE}" ]]; then
            log "Serveur confirme save-off."
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log "Pas de confirmation save-off apres ${SAVE_OFF_WAIT_SECONDS}s (serveur eteint ?). Continuation."
}

request_save_on() {
    rm -f "${SAVE_OFF_REQUEST}" "${SAVE_OFF_DONE}"
    touch "${SAVE_ON_REQUEST}"
    log "Demande save-on envoyee au serveur."
}

# ------------------------------------------------------------------------------
#  Estimation de l'espace requis
# ------------------------------------------------------------------------------
estimate_required_bytes() {
    # Taille du monde * 0.55 (compression typique des region MCA ~40-60%)
    local world_bytes
    world_bytes="$(du -sb "${WORLD_DIR}" | awk '{ print $1 }')"
    # 70% pour marge de securite
    echo $(( world_bytes * 70 / 100 ))
}

# ------------------------------------------------------------------------------
#  Liste des versions deja publiees
# ------------------------------------------------------------------------------
list_versions() {
    find "${SURVIE_PUBLISH_DIR}" -maxdepth 1 -type f -name "${SERVER_NAME}-${MAP_NAME}_*.zip" \
        -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{ $1=""; sub(/^ /, ""); print }'
}

# ------------------------------------------------------------------------------
#  Manifest JSON pour le site
# ------------------------------------------------------------------------------
write_manifest() {
    local enabled="false"
    [[ -f "${ENABLE_FLAG}" ]] && enabled="true"

    local versions_json="[]"
    local entries=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local name="$(basename "$f")"
        local size="$(stat -c %s "$f")"
        local mtime="$(stat -c %Y "$f")"
        local sha
        if [[ -f "${f}.sha256" ]]; then
            sha="$(awk '{print $1}' "${f}.sha256")"
        else
            sha=""
        fi
        entries+=("$(printf '{"file":"%s","size":%s,"mtime":%s,"sha256":"%s"}' \
            "$name" "$size" "$mtime" "$sha")")
    done < <(list_versions)

    if (( ${#entries[@]} > 0 )); then
        local joined
        joined="$(IFS=,; echo "${entries[*]}")"
        versions_json="[${joined}]"
    fi

    local latest=""
    if [[ -L "${SURVIE_PUBLISH_DIR}/latest.zip" ]]; then
        latest="$(basename "$(readlink "${SURVIE_PUBLISH_DIR}/latest.zip")")"
    fi

    cat > "${MANIFEST_FILE}.tmp" <<EOF
{
  "enabled": ${enabled},
  "generated_at": $(date +%s),
  "latest": "${latest}",
  "license": "CC BY-NC-SA 4.0",
  "license_url": "https://creativecommons.org/licenses/by-nc-sa/4.0/",
  "versions": ${versions_json}
}
EOF
    mv -f "${MANIFEST_FILE}.tmp" "${MANIFEST_FILE}"
    log "Manifest mis a jour: ${MANIFEST_FILE}"
}

# ------------------------------------------------------------------------------
#  Prune : garde KEEP_VERSIONS + supprime jusqu'a atteindre MIN_FREE_GB
# ------------------------------------------------------------------------------
prune_versions() {
    local min_free_bytes=$(( MIN_FREE_GB * 1024 * 1024 * 1024 ))

    # Protege la version actuellement pointee par latest.zip (potentiellement
    # epinglee manuellement par un admin via le menu "Sauvegardes" et donc
    # pas forcement la plus recente).
    local pinned_latest=""
    if [[ -L "${SURVIE_PUBLISH_DIR}/latest.zip" ]]; then
        pinned_latest="${SURVIE_PUBLISH_DIR}/$(readlink "${SURVIE_PUBLISH_DIR}/latest.zip")"
    fi

    mapfile -t versions < <(list_versions)
    local n=${#versions[@]}

    # 1) Cap sur KEEP_VERSIONS
    if (( n > KEEP_VERSIONS )); then
        local remove=$(( n - KEEP_VERSIONS ))
        log "Suppression de ${remove} version(s) excedentaire(s) (cap KEEP_VERSIONS=${KEEP_VERSIONS})."
        local i removed=0
        for (( i = 0; i < n && removed < remove; i++ )); do
            local f="${versions[$i]}"
            if [[ -n "${pinned_latest}" && "${f}" == "${pinned_latest}" ]]; then
                log "  - skip ${f} (epingle comme latest)"
                continue
            fi
            log "  - rm ${f}"
            rm -f "$f" "${f}.sha256"
            removed=$(( removed + 1 ))
        done
        mapfile -t versions < <(list_versions)
        n=${#versions[@]}
    fi

    # 2) Plancher espace libre
    local free
    free="$(filesystem_free_bytes)"
    while (( free < min_free_bytes && n > 1 )); do
        local f="${versions[0]}"
        if [[ -n "${pinned_latest}" && "${f}" == "${pinned_latest}" ]]; then
            # Si le plus ancien est epingle, essaie le suivant.
            if (( n > 1 )); then
                f="${versions[1]}"
                if [[ "${f}" == "${pinned_latest}" ]]; then
                    break
                fi
            else
                break
            fi
        fi
        log "Espace libre $(human_size "$free") < $(human_size "$min_free_bytes"); suppression de ${f}"
        rm -f "$f" "${f}.sha256"
        mapfile -t versions < <(list_versions)
        n=${#versions[@]}
        free="$(filesystem_free_bytes)"
    done

    if (( free < min_free_bytes )); then
        log "Avertissement: espace libre toujours $(human_size "$free") < $(human_size "$min_free_bytes"), mais une seule version conservee."
    fi
}

# Supprime AGGRESSIVEMENT les versions les plus anciennes jusqu'a ce qu'il
# y ait au moins ${required_free_bytes} octets libres. Sert AVANT un nouveau
# zip pour s'assurer qu'on a la place de l'ecrire.
make_space_for_zip() {
    local required_free_bytes="$1"
    local free versions n f
    free="$(filesystem_free_bytes)"
    if (( free >= required_free_bytes )); then
        return 0
    fi
    # Determine la version actuellement publiee (latest.zip) : on NE
    # la supprime JAMAIS tant que le nouveau zip n'est pas valide.
    local current_latest=""
    if [[ -L "${SURVIE_PUBLISH_DIR}/latest.zip" ]]; then
        current_latest="${SURVIE_PUBLISH_DIR}/$(readlink "${SURVIE_PUBLISH_DIR}/latest.zip")"
    fi
    log "Espace insuffisant ($(human_size "$free") < $(human_size "$required_free_bytes")), suppression des plus anciennes versions..."
    mapfile -t versions < <(list_versions)
    n=${#versions[@]}
    local i=0
    while (( i < n && free < required_free_bytes )); do
        f="${versions[$i]}"
        i=$((i+1))
        # Protection : ne pas supprimer la version pointee par latest.zip
        if [[ -n "$current_latest" && "$f" == "$current_latest" ]]; then
            log "  - skip $(basename "$f") (version courante latest, protegee)"
            continue
        fi
        log "  - rm $(basename "$f") ($(human_size "$(stat -c %s "$f" 2>/dev/null || echo 0)"))"
        rm -f "$f" "${f}.sha256"
        free="$(filesystem_free_bytes)"
    done
    if (( free < required_free_bytes )); then
        # Dernier recours : on est bloque uniquement parce que la version 'latest'
        # occupe l'espace requis. L'utilisateur a explicitement declenche un
        # nouvel export, c'est qu'il accepte de remplacer le snapshot precedent.
        # Le monde source reste intact : si le nouvel export echoue, il pourra
        # relancer. Sans ce fallback, on resterait bloque indefiniment des que
        # le disque ne peut pas heberger 2 zips simultanement.
        if [[ -n "$current_latest" && -f "$current_latest" ]]; then
            log "  ! Suppression de la version courante en dernier recours : $(basename "$current_latest") ($(human_size "$(stat -c %s "$current_latest" 2>/dev/null || echo 0)"))"
            rm -f "$current_latest" "${current_latest}.sha256"
            # Le symlink latest.zip devient casse mais sera recree par publish.
            free="$(filesystem_free_bytes)"
        fi
    fi
    if (( free < required_free_bytes )); then
        err "Impossible de liberer assez d'espace ($(human_size "$free") < $(human_size "$required_free_bytes") requis). Abort."
        return 1
    fi
    log "Espace libere : $(human_size "$free") disponible."
}

# ------------------------------------------------------------------------------
#  Action principale : run
# ------------------------------------------------------------------------------
# ---------------------------------------------------------------------------
#  build_vanilla_world_layout : prepare dans ${dst} UN SEUL dossier monde
#  conforme a la procedure officielle Paper -> Vanilla 26.1+ (cf. en-tete).
#
#  Layout produit dans ${dst} (= xeinoria-survie-world/) :
#
#     level.dat
#     icon.png
#     datapacks/
#     data/minecraft/
#         game_rules.dat            <- depuis dimensions/minecraft/overworld/data/minecraft/
#         scheduled_events.dat      <- idem
#         wandering_trader.dat      <- idem
#         weather.dat               <- idem
#         world_gen_settings.dat    <- idem
#         maps/                     <- depuis sv/data/minecraft/ (vanilla)
#         custom_boss_events.dat    <- idem
#         random_sequences.dat      <- idem
#         stopwatches.dat           <- idem
#         world_clocks.dat          <- idem
#         (scoreboard.dat retire pour confidentialite)
#     dimensions/minecraft/<dim>/   pour dim in {overworld, the_nether, the_end}
#         region/   entities/   poi/
#         data/minecraft/           sans les 5 fichiers migres ci-dessus
#                                   (chunk_tickets, raids, world_border,
#                                    world_clocks, ender_dragon_fight pour end)
#
#  Exclu (confidentialite ou specifique Paper) :
#     - sv/players/ (advancements, playerdata, stats)
#     - data/paper/ partout
#     - paper-world.yml partout
#     - session.lock, uid.dat, level.dat_old
#     - scoreboard.dat
#
#  Tout est cree par symlinks => zero copie disque pendant le staging.
#  zip suit les symlinks et enregistre les fichiers sous le nom du symlink.
# ---------------------------------------------------------------------------
build_vanilla_world_layout() {
    local src="$1"      # ex. /home/debian/xeinoria/survie/sv
    local dst="$2"      # ex. ${stage_dir}/xeinoria-survie-world

    rm -rf "${dst}" 2>/dev/null || true
    mkdir -p "${dst}"

    # --- Racine du monde : meta vanilla seulement ---
    local f
    for f in level.dat icon.png; do
        [[ -f "${src}/${f}" ]] && ln -s "${src}/${f}" "${dst}/${f}"
    done
    if [[ -d "${src}/datapacks" ]]; then
        ln -s "${src}/datapacks" "${dst}/datapacks"
    fi

    # --- Racine : data/minecraft/ (vanilla 26.1+) ---
    # 1) Les 5 fichiers migres depuis l'overworld dim.
    mkdir -p "${dst}/data/minecraft"
    local migrated
    for migrated in game_rules.dat scheduled_events.dat wandering_trader.dat weather.dat world_gen_settings.dat; do
        if [[ -f "${src}/dimensions/minecraft/overworld/data/minecraft/${migrated}" ]]; then
            ln -s "${src}/dimensions/minecraft/overworld/data/minecraft/${migrated}" "${dst}/data/minecraft/${migrated}"
        fi
    done
    # 2) Fichiers globaux deja a sv/data/minecraft (vanilla-compatibles), sauf
    #    scoreboard.dat (confidentialite : pseudos / objectifs lies aux joueurs).
    if [[ -d "${src}/data/minecraft" ]]; then
        local g gname
        for g in "${src}/data/minecraft"/*; do
            [[ -e "${g}" ]] || continue
            gname="$(basename "${g}")"
            case "${gname}" in
                scoreboard.dat) continue ;;
            esac
            # Ne jamais ecraser un fichier deja place (les 5 migres priment).
            [[ -e "${dst}/data/minecraft/${gname}" ]] && continue
            ln -s "${g}" "${dst}/data/minecraft/${gname}"
        done
    fi

    # --- Dimensions : on garde l'arbo dimensions/minecraft/* ---
    local dim dpath sub df dfname
    for dim in overworld the_nether the_end; do
        dpath="${src}/dimensions/minecraft/${dim}"
        [[ -d "${dpath}" ]] || continue
        mkdir -p "${dst}/dimensions/minecraft/${dim}"
        for sub in region entities poi; do
            if [[ -d "${dpath}/${sub}" ]]; then
                ln -s "${dpath}/${sub}" "${dst}/dimensions/minecraft/${dim}/${sub}"
            fi
        done
        # data/minecraft/ par-dim, sans les 5 fichiers migres + sans data/paper/.
        if [[ -d "${dpath}/data/minecraft" ]]; then
            mkdir -p "${dst}/dimensions/minecraft/${dim}/data/minecraft"
            for df in "${dpath}/data/minecraft"/*; do
                [[ -e "${df}" ]] || continue
                dfname="$(basename "${df}")"
                case "${dfname}" in
                    game_rules.dat|scheduled_events.dat|wandering_trader.dat|weather.dat|world_gen_settings.dat)
                        continue ;;
                esac
                ln -s "${df}" "${dst}/dimensions/minecraft/${dim}/data/minecraft/${dfname}"
            done
        fi
        # paper-world.yml et data/paper/ : volontairement ignores.
    done
}

cmd_run() {
    require_cmd zip
    require_cmd sha256sum
    require_cmd find
    require_cmd numfmt

    ensure_dirs

    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        err "Un export est deja en cours (verrou ${LOCK_FILE})."
        exit 1
    fi

    if [[ ! -d "${WORLD_DIR}" ]]; then
        err "Dossier monde introuvable: ${WORLD_DIR}"
        exit 1
    fi

    # Initialisation de la progression
    started_at="$(date +%s)"
    total_files=0
    EXPORT_PLAYER="${1:-}"
    echo "$$" > "${PID_FILE}"
    rm -f "${CANCEL_FILE}"
    progress_write "starting" 0 0 0 0
    # Trap pose AVANT toute operation pouvant 'exit 1' : sans cela un abort
    # precoce (espace insuffisant, save-off impossible, etc.) laisserait
    # .export_progress fige sur 'starting', bloquant le menu Skript.
    trap '_cmd_run_cleanup' EXIT
    log "Export demarre (PID=$$${EXPORT_PLAYER:+, joueur=${EXPORT_PLAYER}})."

    # Garde-fou espace
    config_reload_keep_versions
    local need free
    need="$(estimate_required_bytes)"
    free="$(filesystem_free_bytes)"
    log "Monde: $(human_size "$(du -sb "${WORLD_DIR}" | awk '{print $1}')") | Estimation zip: $(human_size "$need") | Libre: $(human_size "$free") | keep_versions=${KEEP_VERSIONS}"

    # 1) Prune normal (cap KEEP_VERSIONS)
    prune_versions
    # 2) Prune agressif jusqu'a avoir need + 2 GB de marge
    if ! make_space_for_zip $(( need + 2 * 1024 * 1024 * 1024 )); then
        exit 1
    fi

    # Coordination Paper
    progress_write "save_off" 0 0 0 0
    request_save_off

    local stamp
    stamp="$(date +%Y-%m-%d_%H%M)"
    local zip_name="${SERVER_NAME}-${MAP_NAME}_${stamp}.zip"
    local zip_tmp="${TMP_DIR}/${zip_name}"
    local zip_final="${SURVIE_PUBLISH_DIR}/${zip_name}"

    log "Construction de ${zip_name}..."

    # Staging des fichiers META dans un dossier dedie pour pouvoir les preserver
    local meta_dir="${TMP_DIR}/_meta_${stamp}"
    rm -rf "${meta_dir}"
    mkdir -p "${meta_dir}"
    cp "${SCRIPT_DIR}/export_map_LICENSE.txt" "${meta_dir}/LICENSE.txt"
    cp "${SCRIPT_DIR}/export_map_README.txt"  "${meta_dir}/README.txt"

    # VERSION.txt : version Minecraft / Paper
    local mc_version=""
    if [[ -f "${SERVER_DIR}/version_history.json" ]]; then
        # Note: pas de pipefail-friendly 'head' ici car grep avec head provoque
        # un SIGPIPE qui fait echouer la commande sous 'set -o pipefail'.
        # On lit tout, puis on extrait la premiere valeur via sed/awk.
        mc_version="$(grep -oE '"currentVersion"[[:space:]]*:[[:space:]]*"[^"]+"' \
            "${SERVER_DIR}/version_history.json" \
            | sed -n '1{s/.*"\([^"]\+\)"$/\1/;p;}')" || mc_version=""
    fi
    local world_size_h
    world_size_h="$(du -sh "${WORLD_DIR}" 2>/dev/null | awk '{print $1}')"
    local now_utc now_local now_epoch
    now_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    now_local="$(date +"%Y-%m-%d %H:%M:%S %Z")"
    now_epoch="$(date +%s)"
    cat > "${meta_dir}/VERSION.txt" <<EOF
XEINORIA - Survival Map
=======================

Snapshot ID         : ${stamp}
Archive file        : ${zip_name}
World folder        : ${WORLD_FOLDER_IN_ZIP}
Approx. world size  : ${world_size_h:-unknown} (before zip compression)

Generated at (UTC)  : ${now_utc}
Generated at (local): ${now_local}
Generated at (epoch): ${now_epoch}

Server              : Paper (Minecraft Java Edition)
Server build        : ${mc_version:-unknown}
Layout              : Vanilla 26.1+ (Paper -> Vanilla migration applied,
                      see https://docs.papermc.io/paper/migration/#to-vanilla)

Original work       : https://norath.fr/download
License             : CC BY-NC-SA 4.0
EOF

    cat > "${meta_dir}/AUTHORS.txt" <<EOF
XEINORIA - Survival Map
Authors / Contributors:
  - The XEINORIA Minecraft community and staff (https://norath.fr)
  - Builders, redstoners and explorers credited collectively as "XEINORIA team"

This is a collective work. Attribution is to be given to "the XEINORIA team"
unless individual contributors are explicitly listed for a specific build.
EOF

    # Strategie de zip:
    #  - On veut le contenu du monde SOUS un sous-dossier WORLD_FOLDER_IN_ZIP
    #  - zip -r ne permet pas trivialement de renommer le prefixe.
    #  - Solution : on cd dans le dossier parent et on archive en utilisant
    #    un lien symbolique temporaire vers le monde, en activant -y (preserve
    #    les liens) -> non ! -y empecherait de descendre. On utilise plutot
    #    une astuce : on cree le zip avec un cd dans SERVER_DIR puis on
    #    archive "sv" ; puis on renomme l'entree dans le zip via 'zip -j'
    #    impossible non plus. Mieux : on cree un dossier temporaire avec
    #    un symlink "WORLD_FOLDER_IN_ZIP -> sv" et on zippe avec --symlinks
    #    desactive (par defaut, zip suit les symlinks ET les enregistre
    #    sous le nom symlink). C'est exactement ce qu'on veut.

    local stage_dir="${TMP_DIR}/_stage_${stamp}"
    rm -rf "${stage_dir}"
    mkdir -p "${stage_dir}"
    # Cree UN dossier monde unique conforme a la migration officielle
    # Paper -> Vanilla 26.1+. Voir le commentaire de build_vanilla_world_layout.
    build_vanilla_world_layout "${WORLD_DIR}" "${stage_dir}/${WORLD_FOLDER_IN_ZIP}"
    # Meta files au meme niveau (root du zip)
    cp "${meta_dir}/LICENSE.txt" "${stage_dir}/LICENSE.txt"
    cp "${meta_dir}/README.txt"  "${stage_dir}/README.txt"
    cp "${meta_dir}/VERSION.txt" "${stage_dir}/VERSION.txt"
    cp "${meta_dir}/AUTHORS.txt" "${stage_dir}/AUTHORS.txt"

    # Filtrage par symlinks dans build_vanilla_world_layout :
    # session.lock, uid.dat, level.dat_old, players/, data/paper/,
    # paper-world.yml, scoreboard.dat ne sont JAMAIS introduits dans le
    # staging. Pas d'excludes a passer a zip.

    # Comptage des fichiers pour la barre de progression. On reflete les
    # exclusions reelles du staging (players/, data/paper/, paper-world.yml,
    # scoreboard.dat, lock files) pour ne pas surestimer le total.
    log "Comptage des fichiers pour la progression..."
    total_files="$(find "${WORLD_DIR}" -type f \
        ! -name 'session.lock' \
        ! -name 'uid.dat' \
        ! -name 'level.dat_old' \
        ! -name 'paper-world.yml' \
        ! -name 'scoreboard.dat' \
        ! -path "${WORLD_DIR}/players/*" \
        ! -path "*/data/paper/*" \
        2>/dev/null | wc -l || echo 1)"
    total_files=$(( total_files + 4 ))
    log "Fichiers a zipper : ${total_files}"
    # Garde-fou : Paper peut ecrire level.dat en mode 600 (root) => non lisible
    # par l'utilisateur debian. On corrige silencieusement si possible.
    for _f in "${WORLD_DIR}/level.dat" "${WORLD_DIR}/level.dat_old"; do
        if [[ -f "${_f}" ]] && ! [ -r "${_f}" ]; then
            chmod o+r "${_f}" 2>/dev/null \
                && log "Droits corriges sur $(basename "${_f}") (o+r)." \
                || log "ATTENTION: $(basename "${_f}") non lisible et chmod impossible. Le zip peut l'omettre."
        fi
    done
    progress_write "zipping" 0 "${total_files}" 0 0

    # zip peut retourner:
    #   0  = ok
    #   12 = rien a faire
    #   18 = certains fichiers ont change/n'ont pas pu etre lus (warning)
    # On tolere 18. Zip est lance en arriere-plan ; un sous-shell moniteur
    # compte les lignes '  adding:' et met a jour le fichier de progression.
    local zip_rc=0
    local zip_outlog="${TMP_DIR}/.zip_out_${stamp}"

    # Lancement zip en arriere-plan (stdout -> zip_outlog)
    (
        cd "${stage_dir}"
        # zip suit les symlinks par defaut et stocke sous le nom du symlink.
        # -r recursif, -${COMPRESSION_LEVEL} niveau, -X sans attributs etendus.
        zip -r -"${COMPRESSION_LEVEL}" -X "${zip_tmp}" \
            "LICENSE.txt" "README.txt" "VERSION.txt" "AUTHORS.txt" \
            "${WORLD_FOLDER_IN_ZIP}"
    ) > "${zip_outlog}" 2>&1 &
    local zip_bg_pid=$!
    log "zip PID=${zip_bg_pid}, progression console toutes les ~10%%."

    # Moniteur de progression (sous-shell background : pas de 'local' possible)
    (
        count=0; last_count=-1; last_pct=-1
        while kill -0 "${zip_bg_pid}" 2>/dev/null; do
            # Annulation demandee ?
            if [[ -f "${CANCEL_FILE}" ]]; then
                log "Annulation demandee. Arret du zip (PID=${zip_bg_pid})."
                kill -TERM "${zip_bg_pid}" 2>/dev/null || true
                break
            fi
            if [[ -f "${zip_outlog}" ]]; then
                count=$(grep -c '^  adding:' "${zip_outlog}" 2>/dev/null || true)
                # S'assurer que count est un entier propre (grep peut retourner 0 + newline)
                count="${count//[^0-9]/}"
                [[ -z "${count}" ]] && count=0
            fi
            if (( count != last_count )); then
                elapsed=$(( $(date +%s) - started_at ))
                (( elapsed <= 0 )) && elapsed=1
                pct=0; eta=0
                if (( total_files > 0 )); then
                    pct=$(( count * 100 / total_files ))
                    (( pct > 99 )) && pct=99
                fi
                if (( count > 0 && total_files > count )); then
                    eta=$(( elapsed * (total_files - count) / count ))
                fi
                progress_write "zipping" "${count}" "${total_files}" "${pct}" "${eta}"
                if (( pct >= last_pct + 10 )); then
                    log "[zip] ${pct}%% (${count}/${total_files}) - ETA ~$(eta_format "${eta}")"
                    last_pct="${pct}"
                fi
                last_count="${count}"
            fi
            sleep 3
        done
    ) &
    local monitor_pid=$!

    wait "${zip_bg_pid}" || zip_rc=$?
    kill "${monitor_pid}" 2>/dev/null || true
    wait "${monitor_pid}" 2>/dev/null || true
    rm -f "${zip_outlog}"

    # Annulation demandee ?
    if [[ -f "${CANCEL_FILE}" ]]; then
        log "Export annule par l'utilisateur."
        rm -f "${zip_tmp}" "${CANCEL_FILE}"
        progress_write "cancelled" 0 "${total_files}" 0 0
        exit 0
    fi

    if [[ "${zip_rc}" -eq 18 ]]; then
        log "zip warning: certains fichiers ont change pendant la lecture (code 18, ignore)."
    elif [[ "${zip_rc}" -ne 0 ]]; then
        err "zip a echoue (code ${zip_rc}). Abort."
        rm -f "${zip_tmp}"
        exit 1
    fi

    progress_write "verifying" "${total_files}" "${total_files}" 99 0
    log "[zip] 100%% (${total_files}/${total_files}) - Verification de l'archive..."

    # Verifie que LICENSE.txt et le monde sont dans le zip.
    # NB: 'unzip -l' peut retourner un code non-zero sur archives avec warnings
    # (alors que le contenu listable est correct). Avec set -o pipefail,
    # 'unzip -l ... | grep -q ...' echouerait alors faussement. On capture
    # donc le listing en variable d'abord.
    local zip_listing
    zip_listing="$(unzip -l "${zip_tmp}" 2>/dev/null || true)"
    if ! grep -q "LICENSE.txt" <<<"${zip_listing}"; then
        err "LICENSE.txt manquant dans l'archive. Abort."
        rm -f "${zip_tmp}"
        exit 1
    fi
    if ! grep -q "${WORLD_FOLDER_IN_ZIP}/level.dat" <<<"${zip_listing}"; then
        err "level.dat manquant dans l'archive. Abort."
        rm -f "${zip_tmp}"
        exit 1
    fi
    # Verifie la presence des 3 dimensions sous dimensions/minecraft/.
    local _dim _dim_re
    for _dim in overworld the_nether the_end; do
        _dim_re="${WORLD_FOLDER_IN_ZIP}/dimensions/minecraft/${_dim}/region/"
        if ! grep -q "${_dim_re}" <<<"${zip_listing}"; then
            err "Dossier dimension ${_dim} manquant dans l'archive. Abort."
            rm -f "${zip_tmp}"
            exit 1
        fi
    done
    # Verifie qu'au moins 1 des 5 fichiers migres est bien a data/minecraft/.
    if ! grep -q "${WORLD_FOLDER_IN_ZIP}/data/minecraft/world_gen_settings.dat" <<<"${zip_listing}"; then
        err "data/minecraft/world_gen_settings.dat manquant (migration Vanilla incomplete). Abort."
        rm -f "${zip_tmp}"
        exit 1
    fi
    # Verifie la confidentialite : aucun fichier prive ne doit etre dans le zip.
    local _bad
    _bad="$(grep -E '(^|/)(players|playerdata|stats|advancements)/' <<<"${zip_listing}" || true)"
    if [[ -n "${_bad}" ]]; then
        err "Fichiers prives detectes dans l'archive (players/playerdata/stats/advancements). Abort."
        err "Echantillon : $(head -n 3 <<<"${_bad}")"
        rm -f "${zip_tmp}"
        exit 1
    fi
    if grep -q "paper-world.yml" <<<"${zip_listing}"; then
        err "paper-world.yml present dans l'archive (specifique Paper, doit etre retire). Abort."
        rm -f "${zip_tmp}"
        exit 1
    fi
    if grep -q "/data/paper/" <<<"${zip_listing}"; then
        err "data/paper/ present dans l'archive (specifique Paper). Abort."
        rm -f "${zip_tmp}"
        exit 1
    fi
    if grep -q "scoreboard.dat" <<<"${zip_listing}"; then
        err "scoreboard.dat present dans l'archive (confidentialite). Abort."
        rm -f "${zip_tmp}"
        exit 1
    fi

    # Hash + move atomique
    progress_write "finalizing" "${total_files}" "${total_files}" 99 5
    sha256sum "${zip_tmp}" | awk -v name="${zip_name}" '{ print $1 "  " name }' > "${zip_tmp}.sha256"
    mv -f "${zip_tmp}"        "${zip_final}"
    mv -f "${zip_tmp}.sha256" "${zip_final}.sha256"
    chmod 644 "${zip_final}" "${zip_final}.sha256"

    # Symlink "latest"
    (
        cd "${SURVIE_PUBLISH_DIR}"
        ln -sfn "${zip_name}"        "latest.zip"
        ln -sfn "${zip_name}.sha256" "latest.zip.sha256"
    )

    # Cleanup stage
    rm -rf "${stage_dir}" "${meta_dir}"

    log "Archive publiee: ${zip_final} ($(human_size "$(stat -c %s "${zip_final}")"))"

    # Progression : export termine
    progress_write "done" "${total_files}" "${total_files}" 100 0
    rm -f "${PID_FILE}"

    # Save-on
    request_save_on
    trap - EXIT

    # Prune + manifest + meta files
    prune_versions
    publish_meta_files
    write_manifest

    # Met a jour le timestamp de dernier auto-run (sert au cron_tick)
    config_set last_auto_run "$(date +%s)" || true

    log "Export termine avec succes."
}

cmd_list() {
    ensure_dirs
    log "Versions publiees dans ${SURVIE_PUBLISH_DIR} :"
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local size mtime
        size="$(stat -c %s "$f")"
        mtime="$(stat -c %y "$f" | cut -d. -f1)"
        printf '  %s  %10s  %s\n' "${mtime}" "$(human_size "$size")" "$(basename "$f")"
    done < <(list_versions)
    if [[ -L "${SURVIE_PUBLISH_DIR}/latest.zip" ]]; then
        printf '  latest -> %s\n' "$(readlink "${SURVIE_PUBLISH_DIR}/latest.zip")"
    fi
    if [[ -f "${ENABLE_FLAG}" ]]; then
        log "Etat: ACTIVE (telechargement public autorise)"
    else
        log "Etat: DESACTIVE"
    fi
}

# ------------------------------------------------------------------------------
#  Versions list (machine-readable) + set_latest (re-point symlink)
#  Format de versions_list : file|size|mtime|sha256|is_latest
#  Trie par mtime decroissant (plus recent en premier).
# ------------------------------------------------------------------------------
cmd_versions_list() {
    ensure_dirs
    local latest_name=""
    if [[ -L "${SURVIE_PUBLISH_DIR}/latest.zip" ]]; then
        latest_name="$(basename "$(readlink "${SURVIE_PUBLISH_DIR}/latest.zip")")"
    fi
    # list_versions est trie par mtime croissant ; on inverse pour avoir
    # le plus recent en tete (plus pratique pour l'UI).
    local lines=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        lines+=("$f")
    done < <(list_versions)
    local i
    for (( i = ${#lines[@]} - 1; i >= 0; i-- )); do
        local f="${lines[$i]}"
        local name size mtime sha is_latest date_fmt size_human
        name="$(basename "$f")"
        size="$(stat -c %s "$f")"
        mtime="$(stat -c %Y "$f")"
        if [[ -f "${f}.sha256" ]]; then
            sha="$(awk '{print $1}' "${f}.sha256")"
        else
            sha=""
        fi
        if [[ "${name}" == "${latest_name}" ]]; then
            is_latest="1"
        else
            is_latest="0"
        fi
        date_fmt="$(date -d "@${mtime}" '+%d/%m/%Y %H:%M' 2>/dev/null)"
        size_human="$(human_size "${size}" 2>/dev/null)"
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "${name}" "${size}" "${mtime}" "${sha}" "${is_latest}" \
            "${date_fmt}" "${size_human}"
    done
}

cmd_set_latest() {
    ensure_dirs
    local target="${1:-}"
    if [[ -z "${target}" ]]; then
        err "usage: set_latest <filename.zip>"
        exit 2
    fi
    # Securite : pas de slash, doit matcher le pattern attendu
    if [[ "${target}" == */* ]] || [[ "${target}" == .* ]]; then
        err "set_latest: nom de fichier invalide (${target})."
        exit 2
    fi
    case "${target}" in
        ${SERVER_NAME}-${MAP_NAME}_*.zip) ;;
        *)
            err "set_latest: nom de fichier inattendu (${target})."
            exit 2
            ;;
    esac
    local target_path="${SURVIE_PUBLISH_DIR}/${target}"
    if [[ ! -f "${target_path}" ]]; then
        err "set_latest: ${target} introuvable dans ${SURVIE_PUBLISH_DIR}."
        exit 1
    fi
    (
        cd "${SURVIE_PUBLISH_DIR}"
        ln -sfn "${target}" "latest.zip"
        if [[ -f "${target}.sha256" ]]; then
            ln -sfn "${target}.sha256" "latest.zip.sha256"
        else
            rm -f "latest.zip.sha256"
        fi
    )
    write_manifest
    log "set_latest: latest.zip -> ${target}"
}

# ------------------------------------------------------------------------------
#  delete_version <file> : supprime un zip publie (refus si actuellement
#  expose comme latest).
# ------------------------------------------------------------------------------
cmd_delete_version() {
    ensure_dirs
    local target="${1:-}"
    if [[ -z "${target}" ]]; then
        err "usage: delete_version <filename.zip>"
        exit 2
    fi
    if [[ "${target}" == */* ]] || [[ "${target}" == .* ]]; then
        err "delete_version: nom de fichier invalide (${target})."
        exit 2
    fi
    case "${target}" in
        ${SERVER_NAME}-${MAP_NAME}_*.zip) ;;
        *)
            err "delete_version: nom de fichier inattendu (${target})."
            exit 2
            ;;
    esac
    local target_path="${SURVIE_PUBLISH_DIR}/${target}"
    if [[ ! -f "${target_path}" ]]; then
        err "delete_version: ${target} introuvable."
        exit 1
    fi
    # Refus de supprimer la sauvegarde actuellement exposee (latest).
    if [[ -L "${SURVIE_PUBLISH_DIR}/latest.zip" ]]; then
        local current
        current="$(basename "$(readlink "${SURVIE_PUBLISH_DIR}/latest.zip")")"
        if [[ "${current}" == "${target}" ]]; then
            err "delete_version: ${target} est actuellement exposee comme latest. Expose une autre sauvegarde d'abord."
            exit 1
        fi
    fi
    rm -f "${target_path}" "${target_path}.sha256"
    write_manifest
    log "delete_version: supprime ${target}"
}

cmd_prune() {
    ensure_dirs
    prune_versions
    write_manifest
}

cmd_enable() {
    ensure_dirs
    touch "${ENABLE_FLAG}"
    publish_meta_files
    write_manifest
    log "Telechargement public ACTIVE."
}

cmd_disable() {
    ensure_dirs
    rm -f "${ENABLE_FLAG}"
    write_manifest
    log "Telechargement public DESACTIVE."
}

cmd_status() {
    ensure_dirs
    if [[ -f "${ENABLE_FLAG}" ]]; then
        echo "enabled=true"
    else
        echo "enabled=false"
    fi
    if [[ -L "${SURVIE_PUBLISH_DIR}/latest.zip" ]]; then
        local tgt="${SURVIE_PUBLISH_DIR}/$(readlink "${SURVIE_PUBLISH_DIR}/latest.zip")"
        if [[ -f "$tgt" ]]; then
            echo "latest=$(basename "$tgt")"
            echo "latest_size=$(stat -c %s "$tgt")"
            echo "latest_mtime=$(stat -c %Y "$tgt")"
        else
            # Symlink casse : nettoyer et signaler aucune version
            rm -f "${SURVIE_PUBLISH_DIR}/latest.zip" "${SURVIE_PUBLISH_DIR}/latest.zip.sha256" 2>/dev/null
            echo "latest=none"
        fi
    else
        echo "latest=none"
    fi
    echo "versions_count=$(list_versions | grep -c .)"
    echo "free_bytes=$(filesystem_free_bytes)"
    echo "auto_frequency=$(config_get auto_frequency)"
    echo "keep_versions=$(config_get keep_versions)"
    echo "last_auto_run=$(config_get last_auto_run)"
}

# ------------------------------------------------------------------------------
#  cron_tick : appele par cron quotidiennement, decide si on doit run
# ------------------------------------------------------------------------------
cmd_cron_tick() {
    local freq last now interval
    freq="$(config_get auto_frequency)"
    last="$(config_get last_auto_run)"
    now="$(date +%s)"

    case "$freq" in
        disabled)
            log "cron_tick: auto_frequency=disabled, rien a faire."
            return 0 ;;
        daily)   interval=86400 ;;
        weekly)  interval=604800 ;;
        monthly) interval=2592000 ;;
        *)
            log "cron_tick: auto_frequency invalide ($freq), rien a faire."
            return 0 ;;
    esac

    # Slack de 1h : on permet de declencher un peu en avance pour absorber
    # le decalage entre l'heure du cron et l'instant exact d'eligibilite.
    if (( now - last < interval - 3600 )); then
        log "cron_tick: pas encore l'heure (last=${last}, freq=${freq})."
        return 0
    fi

    log "cron_tick: auto-run declenche (freq=${freq}, derniere=${last})."
    cmd_run
}

# ------------------------------------------------------------------------------
#  cancel : annule proprement un export en cours
# ------------------------------------------------------------------------------
cmd_cancel() {
    if [[ ! -f "${PID_FILE}" ]]; then
        log "Aucun export en cours (fichier PID absent)."
        return 0
    fi
    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || echo '')"
    if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
        log "Processus ${pid:-?} inexistant. Nettoyage des fichiers residuels."
        rm -f "${PID_FILE}" "${CANCEL_FILE}"
        return 0
    fi
    touch "${CANCEL_FILE}"
    log "Annulation demandee (PID=${pid}). L'export s'arretera proprement dans quelques secondes."
}

# ------------------------------------------------------------------------------
#  config : sous-commandes de manipulation de .mapexport_config
# ------------------------------------------------------------------------------
cmd_config() {
    local sub="${1:-dump}"
    case "$sub" in
        get)
            local key="${2:-}"
            [[ -z "$key" ]] && { err "usage: config get <key>"; exit 2; }
            config_get "$key"
            ;;
        set)
            local key="${2:-}" val="${3:-}"
            [[ -z "$key" || -z "$val" ]] && { err "usage: config set <key> <value>"; exit 2; }
            config_set "$key" "$val" || exit 1
            # Si on touche keep_versions, applique tout de suite un prune
            if [[ "$key" == "keep_versions" ]]; then
                config_reload_keep_versions
                prune_versions
                write_manifest
            fi
            log "config: ${key}=${val}"
            ;;
        dump|"")
            config_dump
            ;;
        *)
            err "sous-commande config inconnue: $sub"
            exit 2
            ;;
    esac
}

main() {
    local action="${1:-run}"
    shift || true
    case "${action}" in
        run)            cmd_run        ;;
        list)           cmd_list       ;;
        versions_list)  cmd_versions_list ;;
        set_latest)     cmd_set_latest "$@" ;;
        delete_version) cmd_delete_version "$@" ;;
        prune)          cmd_prune      ;;
        enable)         cmd_enable     ;;
        disable)        cmd_disable    ;;
        status)         cmd_status     ;;
        cron_tick)      cmd_cron_tick  ;;
        config)         cmd_config "$@" ;;
        cancel)         cmd_cancel      ;;
        *)
            echo "Usage: $0 {run|list|versions_list|set_latest|delete_version|prune|enable|disable|status|cron_tick|config|cancel}" >&2
            exit 2
            ;;
    esac
}

main "$@"
