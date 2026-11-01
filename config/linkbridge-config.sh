#!/bin/sh
# linkbridge-config: write Gambatte core options for a link session.
#
# Usage:
#   linkbridge-config.sh --role server [--port 56400] [--output FILE]
#   linkbridge-config.sh --role client --server-ip 10.77.0.1 [--port 56400]
#                        [--variant auto|digits|octets] [--core gambatte_libretro.so]
#                        [--output FILE]
#
# Prints RetroArch core option lines (key = "value"). With --output the lines
# are merged into FILE: existing link keys are replaced, other keys are kept.
#
# Server IP option variants in gambatte-libretro:
#   octets: gambatte_gb_link_network_server_ip_octet1..4   (values 0-255; builds from 2016-2019)
#   digits: gambatte_gb_link_network_server_ip_1..12       (one digit each, zero padded:
#           10.77.0.1 -> 0 1 0 0 7 7 0 0 0 0 0 1)
# With --variant auto the core binary is inspected (--core); if it cannot be
# determined, both variants are written (the core ignores keys it does not know).

ROLE=""
SERVER_IP=""
PORT="56400"
VARIANT="auto"
CORE=""
OUTPUT=""

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "linkbridge-config: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --server-ip) SERVER_IP="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        --core) CORE="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

case "$ROLE" in server|client) ;; *) die "--role must be server or client" ;; esac
case "$PORT" in *[!0-9]*|"") die "invalid port: $PORT" ;; esac
# gambatte only offers ports 56400-56420 in its option list.
if [ "$PORT" -lt 56400 ] || [ "$PORT" -gt 56420 ]; then
    die "port must be between 56400 and 56420 (Gambatte option range)"
fi

detect_variant() {
    [ -n "$CORE" ] && [ -r "$CORE" ] || { echo "unknown"; return; }
    keys="$(tr -c '[:print:]' '\n' < "$CORE" | grep -oE 'gambatte_gb_link[a-z0-9_]*' | sort -u)"
    if ! printf '%s\n' "$keys" | grep -q '^gambatte_gb_link_mode$'; then
        echo "none"
    elif printf '%s\n' "$keys" | grep -q 'server_ip_octet'; then
        echo "octets"
    elif printf '%s\n' "$keys" | grep -q 'server_ip_12$'; then
        echo "digits"
    else
        echo "unknown"
    fi
}

if [ "$VARIANT" = "auto" ]; then
    VARIANT="$(detect_variant)"
    if [ "$VARIANT" = "none" ]; then
        die "core $CORE has no network link options (built without HAVE_NETWORK)"
    fi
fi
case "$VARIANT" in digits|octets|unknown) ;; *) die "--variant must be auto, digits or octets" ;; esac

if [ "$ROLE" = "client" ]; then
    [ -n "$SERVER_IP" ] || die "--server-ip is required for the client role"
fi

generate() {
    echo 'gambatte_show_gb_link_settings = "enabled"'
    if [ "$ROLE" = "server" ]; then
        echo 'gambatte_gb_link_mode = "Network Server"'
    else
        echo 'gambatte_gb_link_mode = "Network Client"'
    fi
    echo "gambatte_gb_link_network_port = \"$PORT\""
    [ "$ROLE" = "client" ] || return 0

    old_ifs="$IFS"; IFS=.
    # shellcheck disable=SC2086
    set -- $SERVER_IP
    IFS="$old_ifs"
    [ $# -eq 4 ] || die "invalid IPv4 address: $SERVER_IP"
    octets=""
    for o in "$@"; do
        case "$o" in ""|*[!0-9]*) die "invalid IPv4 address: $SERVER_IP" ;; esac
        # Strip leading zeros so sh arithmetic does not read them as octal.
        o="$(printf '%s' "$o" | sed 's/^0*//')"
        [ -n "$o" ] || o=0
        [ "${#o}" -le 3 ] && [ "$o" -le 255 ] || die "invalid IPv4 address: $SERVER_IP"
        octets="$octets $o"
    done
    # shellcheck disable=SC2086
    set -- $octets

    if [ "$VARIANT" = "octets" ] || [ "$VARIANT" = "unknown" ]; then
        i=1
        for o in "$@"; do
            echo "gambatte_gb_link_network_server_ip_octet$i = \"$o\""
            i=$((i + 1))
        done
    fi
    if [ "$VARIANT" = "digits" ] || [ "$VARIANT" = "unknown" ]; then
        digits="$(printf '%03d%03d%03d%03d' "$1" "$2" "$3" "$4")"
        i=1
        while [ $i -le 12 ]; do
            d="$(printf '%s' "$digits" | cut -c"$i")"
            echo "gambatte_gb_link_network_server_ip_$i = \"$d\""
            i=$((i + 1))
        done
    fi
}

LINES="$(generate)" || exit 1

if [ -z "$OUTPUT" ]; then
    printf '%s\n' "$LINES"
    exit 0
fi

mkdir -p "$(dirname "$OUTPUT")" || die "cannot create directory for $OUTPUT"
tmp="$OUTPUT.tmp.$$"
if [ -f "$OUTPUT" ]; then
    grep -vE '^(gambatte_gb_link|gambatte_show_gb_link_settings)' "$OUTPUT" > "$tmp"
else
    : > "$tmp"
fi
printf '%s\n' "$LINES" >> "$tmp"
mv "$tmp" "$OUTPUT"
echo "linkbridge-config: wrote $ROLE options ($VARIANT variant) to $OUTPUT" >&2
