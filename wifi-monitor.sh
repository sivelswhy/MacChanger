#!/bin/bash
# Surveille les crédits Internet du Wi-Fi NormandieTrainConnecte et change l'adresse MAC
# quand ils sont épuisés, puis se reconnecte au réseau.
# Usage : sudo ./wifi-monitor.sh
# Réglages surchargeables par variables d'environnement (sudo VAR=... ./wifi-monitor.sh).

SSID="${SSID:-NormandieTrainConnecte}"
PORTAL="${PORTAL:-http://wifi.normandie.fr}"
IFACE="${IFACE:-en0}"
INTERVAL="${INTERVAL:-30}"         # secondes entre deux vérifications
MIN_CREDITS="${MIN_CREDITS:-0}"    # change l'adresse quand les crédits sont <= cette valeur (%)
COOLDOWN="${COOLDOWN:-120}"        # délai minimum entre deux changements d'adresse

DIR="$(cd "$(dirname "$0")" && pwd)"
DUMP_DIR="$DIR/portal-dump"
COOKIES="$DUMP_DIR/cookies.txt"
USER_NAME="${SUDO_USER:-$USER}"
last_change=0
was_online=0

log() { echo "[$(date '+%H:%M:%S')] $*"; }

notify() {
    sudo -u "$USER_NAME" osascript -e "display notification \"$1\" with title \"Wi-Fi Monitor\"" 2>/dev/null
}

current_ssid() {
    # networksetup -getairportnetwork ne renvoie plus le SSID depuis macOS 15 : ipconfig en secours.
    local s
    s=$(networksetup -getairportnetwork "$IFACE" 2>/dev/null | sed -n 's/^Current Wi-Fi Network: //p')
    [ -z "$s" ] && s=$(ipconfig getsummary "$IFACE" 2>/dev/null | awk -F' : ' '/ SSID : /{print $2; exit}')
    echo "$s"
}

# Internet fonctionne-t-il vraiment (pas intercepté par le portail) ?
online() {
    curl -s -m 8 --interface "$IFACE" http://captive.apple.com/hotspot-detect.html 2>/dev/null | grep -q Success
}

# Télécharge la page du portail et en garde une copie pour analyse.
fetch_portal() {
    mkdir -p "$DUMP_DIR"
    curl -sL -m 10 --interface "$IFACE" -c "$COOKIES" -b "$COOKIES" "$PORTAL" -o "$DUMP_DIR/portal.html" 2>/dev/null
    chown -R "$USER_NAME" "$DUMP_DIR" 2>/dev/null
    [ -s "$DUMP_DIR/portal.html" ]
}

# Pourcentage de crédits restant, ou vide s'il n'est pas trouvé dans la page.
credits() {
    fetch_portal || return
    textutil -convert txt -format html -stdin -stdout < "$DUMP_DIR/portal.html" 2>/dev/null \
        | grep -i -A3 'cr[ée]dit' | grep -oE '[0-9]{1,3}([.,][0-9]+)? ?%' | head -1 | tr -d ' %' | cut -d. -f1 | cut -d, -f1
}

random_mac() {
    local h first
    h=$(openssl rand -hex 6)
    first=$(( (0x${h:0:2} & 0xFC) | 0x02 )) # unicast, administrée localement
    printf '%02x:%s:%s:%s:%s:%s\n' "$first" "${h:2:2}" "${h:4:2}" "${h:6:2}" "${h:8:2}" "${h:10:2}"
}

# Même séquence que l'app : l'adresse ne s'applique que Wi-Fi déconnecté.
change_mac() {
    local mac
    mac=$(random_mac)
    networksetup -setairportpower "$IFACE" off
    ifconfig "$IFACE" ether "$mac" 2>/dev/null
    networksetup -setairportpower "$IFACE" on
    sleep 1
    if ! ifconfig "$IFACE" | grep -qi "ether $mac"; then
        networksetup -setairportpower "$IFACE" off
        networksetup -setairportpower "$IFACE" on
        for _ in $(seq 20); do
            ifconfig "$IFACE" ether "$mac" 2>/dev/null
            ifconfig "$IFACE" | grep -qi "ether $mac" && break
            sleep 0.2
        done
    fi
    if ifconfig "$IFACE" | grep -qi "ether $mac"; then
        log "Nouvelle adresse MAC : $mac"
    else
        log "⚠️  macOS a refusé l'adresse (désactiver « Adresse Wi-Fi privée » pour $SSID)"
    fi
}

reconnect() {
    networksetup -setairportnetwork "$IFACE" "$SSID" >/dev/null 2>&1
    for _ in $(seq 20); do
        [ "$(current_ssid)" = "$SSID" ] && break
        sleep 1
    done
    sleep 3
    fetch_portal
    log "Reconnecté à $SSID — accepte les cookies et les CGU dans la fenêtre du portail"
    notify "Nouvelle adresse MAC : accepte les conditions du portail"
    sudo -u "$USER_NAME" open "$PORTAL"
}

rotate() {
    local now
    now=$(date +%s)
    if [ $((now - last_change)) -lt "$COOLDOWN" ]; then
        log "Changement récent, on attend encore un peu"
        return
    fi
    last_change=$now
    log "Crédits épuisés → changement d'adresse MAC"
    change_mac
    reconnect
}

if [ "$(id -u)" -ne 0 ]; then
    echo "À lancer avec sudo : sudo $0" >&2
    exit 1
fi

log "Surveillance de $SSID sur $IFACE toutes les ${INTERVAL}s (Ctrl+C pour arrêter)"
while true; do
    if [ "$(current_ssid)" != "$SSID" ]; then
        log "Pas connecté à $SSID, en attente…"
    else
        c=$(credits)
        if online; then
            was_online=1
            log "En ligne — crédits : ${c:-inconnus}${c:+%}"
            [ -n "$c" ] && [ "$c" -le "$MIN_CREDITS" ] && { rotate; was_online=0; }
        elif [ -n "$c" ] && [ "$c" -le "$MIN_CREDITS" ]; then
            rotate; was_online=0
        elif [ "$was_online" = 1 ] && [ -z "$c" ]; then
            # Internet coupé après avoir marché, crédits illisibles : sûrement épuisés.
            rotate; was_online=0
        else
            log "Hors ligne : accepte les cookies et les CGU sur le portail ($PORTAL)"
        fi
    fi
    sleep "$INTERVAL"
done
