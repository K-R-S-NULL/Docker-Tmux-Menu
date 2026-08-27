#!/usr/bin/env bash
#
# docker-shell-tmux.sh
#
# Öffnet für existierende Docker-Container jeweils ein eigenes tmux-Fenster
# mit einer interaktiven Bash IM Container (docker exec -it <container> bash).
#
#   - Fenster 0 "menu":      Dauerhaftes Steuerungsmenü zum Starten/Verwalten
#   - Fenster 1 "dashboard": Live-Übersicht aller Container (watch docker ps)
#   - Einzelner Container  -> 1 weiteres Fenster mit eigener Bash
#   - Gruppe von Containern -> je Container im gewählten Set 1 weiteres
#                              Fenster mit eigener Bash
#
# Container-Gruppen werden in einer Konfigurationsdatei definiert:
#   ~/.config/docker-tmux/groups.conf
# Format (eine Gruppe pro Zeile):
#   gruppenname: container1, container2, container3
#
# Verwendung:
#   ./docker-shell-tmux.sh              # Session erstellen/andocken
#   ./docker-shell-tmux.sh --edit-groups # Gruppen-Konfig im $EDITOR öffnen
#
# Tab-Wechsel: Alt+Links/Rechts, Alt+1..9, Alt+w (siehe configure_tmux_ux)
#
set -euo pipefail
 
SESSION_NAME="${SESSION_NAME:-docker-shells}"
CONFIG_FILE="${DOCKER_GROUPS_FILE:-$HOME/.config/docker-tmux/groups.conf}"
# Absoluter Pfad auf dieses Script, damit sich die Session im ersten
# Fenster selbst im Menü-Modus (--menu) neu aufrufen kann.
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
 
# ------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------
log()  { printf '\033[1;34m[docker-shell-tmux]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[docker-shell-tmux]\033[0m %s\n' "$*" >&2; }
 
check_deps() {
    local missing=()
    for bin in tmux docker fzf; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if ((${#missing[@]} > 0)); then
        err "Fehlende Abhängigkeiten: ${missing[*]}"
        err "Installation z.B. mit: sudo apt install ${missing[*]}"
        exit 1
    fi
}
 
ensure_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        cat > "$CONFIG_FILE" <<'EOF'
# Docker-Gruppen für docker-shell-tmux.sh
# Format: gruppenname: container1, container2, container3
# Zeilen mit '#' sind Kommentare.
#
# Beispiel:
# webstack: nginx, php-fpm, mysql
# monitoring: prometheus, grafana
EOF
        log "Beispiel-Konfig angelegt unter: $CONFIG_FILE"
    fi
}
 
# ------------------------------------------------------------------
# Container-Handling
# ------------------------------------------------------------------
 
# Prüft, ob Container existiert (egal ob laufend oder gestoppt)
container_exists() {
    docker inspect --type=container "$1" >/dev/null 2>&1
}
 
# Stellt sicher, dass der Container läuft; startet ihn bei Bedarf
ensure_running() {
    local name="$1"
    local status
    status="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")"
    if [[ "$status" != "true" ]]; then
        log "Container '$name' läuft nicht – starte..."
        docker start "$name" >/dev/null
    fi
}
 
# Öffnet ein neues tmux-Fenster mit eigener Bash im Container
open_container_window() {
    local name="$1"
    local session="$2"
 
    if ! container_exists "$name"; then
        err "Container '$name' existiert nicht, überspringe."
        return 0
    fi
 
    ensure_running "$name"
 
    # bash bevorzugt, sh als Fallback (z.B. Alpine-Images)
    local shell_cmd
    shell_cmd="docker exec -it '$name' bash || docker exec -it '$name' sh; echo; echo '--- Sitzung in $name beendet, Enter zum Schließen ---'; read -r"
 
    tmux new-window -t "$session" -n "$name" "$shell_cmd"
    log "Fenster für '$name' geöffnet."
}
 
# Öffnet mehrere Container als Paneele (Splits) in EINEM gemeinsamen
# neuen tmux-Fenster, statt jeweils ein eigenes Fenster zu erzeugen.
open_containers_as_panes() {
    local session="$1"
    shift
    local containers=("$@")
 
    if ((${#containers[@]} == 0)); then
        err "Keine Container ausgewählt."
        return 0
    fi
 
    local window_name="multi-$(date +%H%M%S)"
    local first="${containers[0]}"
    local target="${session}:${window_name}"
 
    shell_cmd_for() {
        local n="$1"
        printf "docker exec -it '%s' bash || docker exec -it '%s' sh; echo; echo '--- %s beendet ---'; read -r" \
            "$n" "$n" "$n"
    }
 
    if container_exists "$first"; then
        ensure_running "$first"
    else
        err "Container '$first' existiert nicht, überspringe."
    fi
    tmux new-window -t "$session" -n "$window_name" "$(shell_cmd_for "$first")"
    tmux select-pane -t "$target" -T "$first"
 
    local name
    for name in "${containers[@]:1}"; do
        if ! container_exists "$name"; then
            err "Container '$name' existiert nicht, überspringe."
            continue
        fi
        ensure_running "$name"
        tmux split-window -t "$target" "$(shell_cmd_for "$name")"
        tmux select-pane -t "$target" -T "$name"
        tmux select-layout -t "$target" tiled
    done
 
    # Kachel-Layout + Paneel-Titel (Containername) sichtbar machen
    tmux select-layout -t "$target" tiled
    tmux set-window-option -t "$target" pane-border-status top
    tmux set-window-option -t "$target" pane-border-format ' #{pane_title} '
 
    log "Fenster '$window_name' mit ${#containers[@]} Paneelen geöffnet."
}
 
# ------------------------------------------------------------------
# Auswahl-Menüs
# ------------------------------------------------------------------
 
list_containers() {
    docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort
}
 
pick_single_container() {
    list_containers \
        | fzf --prompt="Container wählen> " --height=50% --border \
              --header='Name / Image / Status' \
        | awk -F'\t' '{print $1}'
}
 
pick_multiple_containers() {
    list_containers \
        | fzf --multi --prompt="Container wählen (Tab=Mehrfachauswahl)> " --height=50% --border \
              --header='Name / Image / Status' \
        | awk -F'\t' '{print $1}'
}
 
# Liest Gruppen aus CONFIG_FILE, gibt "name:container1,container2" pro Zeile aus
parse_groups() {
    grep -vE '^\s*(#|$)' "$CONFIG_FILE" 2>/dev/null | while IFS=':' read -r gname members; do
        gname="$(echo "$gname" | xargs)"
        members="$(echo "$members" | tr -d ' ')"
        [[ -n "$gname" && -n "$members" ]] && printf '%s:%s\n' "$gname" "$members"
    done
}
 
pick_group() {
    parse_groups \
        | fzf --prompt="Gruppe wählen> " --height=40% --border \
              --delimiter=':' --with-nth=1 \
              --preview 'echo "Container: "; echo {2} | tr "," "\n"' \
              --preview-window=right:50%:wrap
}
 
# ------------------------------------------------------------------
# Session-Handling
# ------------------------------------------------------------------
 
session_exists() {
    tmux has-session -t "$SESSION_NAME" 2>/dev/null
}
 
# Bequeme Shortcuts zum Wechseln zwischen den Fenstern (Tabs), ohne dass
# jedes Mal die Prefix-Taste (Strg+b) nötig ist. Wirkt serverweit, stört
# also auch bei mehreren Sessions nicht.
configure_tmux_ux() {
    # Fenster per Mausklick in der Statuszeile anwählen
    tmux set-option -g mouse on
 
    # Alt+Pfeil links/rechts: vorheriges/nächstes Fenster
    tmux bind-key -n M-Left  previous-window
    tmux bind-key -n M-Right next-window
 
    # Alt+Shift+Pfeil: aktuelles Fenster in der Reihenfolge verschieben
    tmux bind-key -n M-S-Left  swap-window -t -1
    tmux bind-key -n M-S-Right swap-window -t +1
 
    # Alt+1..9: direkt zu Fenster Nummer 1..9 springen
    for i in 1 2 3 4 5 6 7 8 9; do
        tmux bind-key -n "M-$i" select-window -t ":${i}"
    done
 
    # Alt+w: interaktive Fensterliste (fuzzy) öffnen, ohne Prefix-Taste
    tmux bind-key -n M-w choose-window
 
    # Fenster werden bei Löschung neu durchnummeriert (keine Lücken)
    tmux set-option -g renumber-windows on
 
    # Statuszeile: aktuelles Fenster deutlich hervorheben
    tmux set-option -g status-style 'bg=colour235,fg=colour250'
    tmux set-option -g window-status-current-style 'bg=colour39,fg=colour232,bold'
    tmux set-option -g window-status-format ' #I:#W '
    tmux set-option -g window-status-current-format ' #I:#W '
    tmux set-option -g status-interval 5
}
 
ensure_session() {
    if ! session_exists; then
        # Fenster 0 "menu": das interaktive Steuerungsmenü selbst (Endlosschleife)
        tmux new-session -d -s "$SESSION_NAME" -n "menu" \
            "'$SCRIPT_PATH' --menu"
        # Fenster 1 "dashboard": passive Live-Übersicht aller Container
        tmux new-window -t "$SESSION_NAME" -n "dashboard" \
            "watch -n 2 'docker ps --format \"table {{.Names}}\t{{.Image}}\t{{.Status}}\"'"
        tmux select-window -t "${SESSION_NAME}:menu"
        log "Neue Session '$SESSION_NAME' erstellt (Fenster: menu, dashboard)."
    fi
    configure_tmux_ux
}
 
# ------------------------------------------------------------------
# Hauptmenü
# ------------------------------------------------------------------
main_menu() {
    local choice
    choice="$(printf '%s\n' \
        "1) Einzelnen Container starten (eigene Bash)" \
        "2) Mehrere Container frei auswählen (1 Fenster, je eigenes Paneel)" \
        "3) Vordefinierte Gruppe starten (je eigene Bash)" \
        "4) Beenden" \
        | fzf --prompt="Aktion wählen> " --height=30% --border)"
 
    case "$choice" in
        1*)
            local name
            name="$(pick_single_container)" || return 0
            [[ -z "$name" ]] && return 0
            ensure_session
            open_container_window "$name" "$SESSION_NAME"
            ;;
        2*)
            local names
            names="$(pick_multiple_containers)" || return 0
            [[ -z "$names" ]] && return 0
            local containers=()
            while IFS= read -r n; do
                [[ -n "$n" ]] && containers+=("$n")
            done <<< "$names"
            ensure_session
            open_containers_as_panes "$SESSION_NAME" "${containers[@]}"
            ;;
        3*)
            local line gname members
            line="$(pick_group)" || return 0
            [[ -z "$line" ]] && return 0
            gname="${line%%:*}"
            members="${line#*:}"
            ensure_session
            log "Starte Gruppe '$gname'..."
            IFS=',' read -ra container_list <<< "$members"
            for c in "${container_list[@]}"; do
                open_container_window "$c" "$SESSION_NAME"
            done
            ;;
        4*|"")
            return 1
            ;;
    esac
    return 0
}
 
# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
main() {
    case "${1:-}" in
        --edit-groups)
            ensure_config
            "${EDITOR:-nano}" "$CONFIG_FILE"
            exit 0
            ;;
        --menu)
            # Läuft im ersten tmux-Fenster ("menu") der Session und bleibt
            # dauerhaft geöffnet, damit man jederzeit weitere Container /
            # Gruppen starten oder laufende steuern kann.
            check_deps
            ensure_config
            while main_menu; do :; done
            log "Menü beendet – Fenster bleibt als normale Bash offen."
            log "Mit '$SCRIPT_PATH --menu' hier wieder aktivierbar."
            exec bash
            ;;
    esac
 
    # Normaler Start (ohne Argument): Session inkl. Menü-Fenster anlegen
    # bzw. an bestehende Session andocken.
    check_deps
    ensure_config
    ensure_session
    tmux attach-session -t "$SESSION_NAME"
}
 
main "$@"
 