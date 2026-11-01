#!/usr/bin/env bash
# pc-loopback: run two RetroArch + Gambatte instances on one PC, linked over
# localhost TCP, to test a Game Boy link session (e.g. a Pokémon Red trade)
# before touching any handheld.
#
# Usage:
#   tests/pc-loopback.sh --rom pokered.gb --save-a red-a.sav --save-b red-b.sav
#
# Options:
#   --rom FILE        ROM for both instances (you supply it; never commit ROMs)
#   --rom-b FILE      different ROM for instance B (e.g. Blue vs Red)
#   --save-a FILE     battery save (.sav/.srm) for instance A (server); copied, never modified
#   --save-b FILE     battery save for instance B (client); copied, never modified
#   --core FILE       gambatte_libretro.so (auto-detected if omitted)
#   --retroarch CMD   RetroArch command (default: retroarch, or the Flatpak)
#   --port N          link port, 56400-56420 (default 56400)
#   --delay SEC       seconds between starting server and client (default 3)
#   --workdir DIR     session directory (default ./linkbridge-pc-test-<time>)
#   --dry-run         print the generated configs and commands, start nothing
#
# Instance A is the server, instance B the client connecting to 127.0.0.1.
# Each instance gets its own config overlay, core options file and save
# directory inside the workdir, so your normal RetroArch setup and saves are
# untouched. After the session the resulting saves are in
# <workdir>/{a,b}/saves/.
#
# Test plan for Pokémon Red: both saves stand in a Pokémon Center, saved.
# Go upstairs to the Cable Club in both windows, talk to the receptionist,
# choose Trade Center, and trade e.g. a Kadabra: if it evolves into Alakazam
# on the other side, the link works end to end.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_TOOL="$SCRIPT_DIR/../config/linkbridge-config.sh"

ROM="" ROM_B="" SAVE_A="" SAVE_B="" CORE="" RA_CMD="" PORT=56400 DELAY=3 WORKDIR="" DRY_RUN=0

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "pc-loopback: $*" >&2; exit 1; }
log() { echo "pc-loopback: $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rom) ROM="$2"; shift 2 ;;
        --rom-b) ROM_B="$2"; shift 2 ;;
        --save-a) SAVE_A="$2"; shift 2 ;;
        --save-b) SAVE_B="$2"; shift 2 ;;
        --core) CORE="$2"; shift 2 ;;
        --retroarch) RA_CMD="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --delay) DELAY="$2"; shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

[[ -n "$ROM" ]] || { usage >&2; die "--rom is required"; }
[[ -f "$ROM" ]] || die "ROM not found: $ROM"
[[ -n "$ROM_B" ]] || ROM_B="$ROM"
[[ -f "$ROM_B" ]] || die "ROM not found: $ROM_B"
for s in "$SAVE_A" "$SAVE_B"; do
    [[ -z "$s" || -f "$s" ]] || die "save file not found: $s"
done
[[ -x "$CONFIG_TOOL" || -f "$CONFIG_TOOL" ]] || die "missing $CONFIG_TOOL"

abspath() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")"); }
ROM="$(abspath "$ROM")"
ROM_B="$(abspath "$ROM_B")"

# --- RetroArch -------------------------------------------------------------
RA=()
if [[ -n "$RA_CMD" ]]; then
    read -r -a RA <<< "$RA_CMD"
elif command -v retroarch >/dev/null 2>&1; then
    RA=(retroarch)
elif command -v flatpak >/dev/null 2>&1 && flatpak info org.libretro.RetroArch >/dev/null 2>&1; then
    RA=(flatpak run org.libretro.RetroArch)
elif [[ "$DRY_RUN" = 1 ]]; then
    RA=(retroarch)
else
    die "RetroArch not found; install it or pass --retroarch CMD"
fi

# --- Gambatte core ---------------------------------------------------------
if [[ -z "$CORE" ]]; then
    for d in \
        "$HOME/.config/retroarch/cores" \
        "$HOME/.var/app/org.libretro.RetroArch/config/retroarch/cores" \
        "$HOME/snap/retroarch/current/.config/retroarch/cores" \
        "$HOME/Library/Application Support/RetroArch/cores" \
        /usr/lib/libretro /usr/lib64/libretro /usr/local/lib/libretro \
        /usr/lib/x86_64-linux-gnu/libretro /usr/lib/aarch64-linux-gnu/libretro
    do
        for f in "$d/gambatte_libretro.so" "$d/gambatte_libretro.dylib"; do
            [[ -f "$f" ]] && { CORE="$f"; break 2; }
        done
    done
fi
if [[ -z "$CORE" ]]; then
    [[ "$DRY_RUN" = 1 ]] || die "gambatte core not found; install it via Online Updater or pass --core FILE"
    CORE="/path/to/gambatte_libretro.so"
    log "core not found, using placeholder for dry run"
fi
[[ "$DRY_RUN" = 1 || -f "$CORE" ]] || die "core not found: $CORE"
[[ -f "$CORE" ]] && CORE="$(abspath "$CORE")"

if [[ -f "$CORE" ]] && ! tr -c '[:print:]' '\n' < "$CORE" | grep -q 'gambatte_gb_link_mode'; then
    die "$CORE has no network link options (built without HAVE_NETWORK); install a build with link support"
fi

# --- Session directory ------------------------------------------------------
[[ -n "$WORKDIR" ]] || WORKDIR="$PWD/linkbridge-pc-test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"

setup_instance() {
    local name="$1" role="$2" rom="$3" save="$4"
    local dir="$WORKDIR/$name"
    mkdir -p "$dir/saves" "$dir/states"

    cat > "$dir/overlay.cfg" <<EOF
config_save_on_exit = "false"
global_core_options = "true"
core_options_path = "$dir/core.opt"
game_specific_options = "false"
auto_overrides_enable = "false"
savefile_directory = "$dir/saves"
savestate_directory = "$dir/states"
savefiles_in_content_dir = "false"
savestates_in_content_dir = "false"
sort_savefiles_enable = "false"
sort_savefiles_by_content_enable = "false"
sort_savestates_enable = "false"
sort_savestates_by_content_enable = "false"
savestate_auto_load = "false"
savestate_auto_save = "false"
video_fullscreen = "false"
pause_nonactive = "false"
EOF

    local args=(--role "$role" --port "$PORT" --output "$dir/core.opt")
    [[ "$role" = client ]] && args+=(--server-ip 127.0.0.1)
    [[ -f "$CORE" ]] && args+=(--core "$CORE")
    sh "$CONFIG_TOOL" "${args[@]}"

    if [[ -n "$save" ]]; then
        local base
        base="$(basename "$rom")"
        cp "$save" "$dir/saves/${base%.*}.srm"
    fi
}

[[ -n "$SAVE_A" && -n "$SAVE_B" ]] || log "warning: without --save-a and --save-b both games start from a new file; you need two saved games to trade"

setup_instance a server "$ROM" "$SAVE_A"
setup_instance b client "$ROM_B" "$SAVE_B"

CMD_A=("${RA[@]}" --verbose --appendconfig "$WORKDIR/a/overlay.cfg" -L "$CORE" "$ROM")
CMD_B=("${RA[@]}" --verbose --appendconfig "$WORKDIR/b/overlay.cfg" -L "$CORE" "$ROM_B")

if [[ "$DRY_RUN" = 1 ]]; then
    for n in a b; do
        echo "=== $n/overlay.cfg"; cat "$WORKDIR/$n/overlay.cfg"
        echo "=== $n/core.opt"; cat "$WORKDIR/$n/core.opt"
    done
    printf '=== server command:\n'; printf ' %q' "${CMD_A[@]}"; echo
    printf '=== client command (after %ss):\n' "$DELAY"; printf ' %q' "${CMD_B[@]}"; echo
    exit 0
fi

PID_A="" PID_B=""
cleanup() {
    [[ -n "$PID_B" ]] && kill "$PID_B" 2>/dev/null || true
    [[ -n "$PID_A" ]] && kill "$PID_A" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "starting server (instance A), log: $WORKDIR/a/retroarch.log"
"${CMD_A[@]}" > "$WORKDIR/a/retroarch.log" 2>&1 &
PID_A=$!

# Give the server a head start. No port probe here: Gambatte's server accepts
# exactly one connection, so a probe would be taken for the client. The client
# also retries the connection by itself every few seconds if it is too early.
sleep "$DELAY"
kill -0 "$PID_A" 2>/dev/null || die "server exited early; see $WORKDIR/a/retroarch.log"

log "starting client (instance B), log: $WORKDIR/b/retroarch.log"
"${CMD_B[@]}" > "$WORKDIR/b/retroarch.log" 2>&1 &
PID_B=$!

log "both instances running; close both windows (or Ctrl+C) to end the session"
wait "$PID_B" || true
wait "$PID_A" || true
PID_A="" PID_B=""

log "session finished. Saves after the session:"
ls -l "$WORKDIR/a/saves" "$WORKDIR/b/saves" >&2
log "link log lines:"
grep -ihE 'link|socket|connect|gambatte' "$WORKDIR/a/retroarch.log" "$WORKDIR/b/retroarch.log" 2>/dev/null | tail -n 20 >&2 || true
