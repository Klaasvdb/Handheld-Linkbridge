#!/bin/sh
# shellcheck disable=SC1091,SC2012
# linkbridge-doctor: Phase 0 feasibility checks for Handheld LinkBridge.
#
# Read-only by default: it inspects the system and never loads kernel modules,
# changes USB roles or touches network interfaces.
#
# Usage:
#   sh linkbridge-doctor.sh                 # run all checks, print report
#   sh linkbridge-doctor.sh --peer 10.77.0.2  # also ping the other handheld
#   sh linkbridge-doctor.sh --load-modules  # actually modprobe test modules (needs root)
#   sh linkbridge-doctor.sh --core /path/to/gambatte_libretro.so
#
# The report is printed and also saved to linkbridge-doctor-<host>-<date>.txt
# in the current directory (or $HOME if that is not writable). Paste the whole
# file into the issue / chat so it can be added to docs/compatibility.md.
#
# Written in POSIX sh so it runs on ArkOS, dArkOS, ROCKNIX (busybox) and PCs.

DOCTOR_VERSION="0.1.0"

PEER=""
LOAD_MODULES=0
CORE_OVERRIDE=""
OUT_FILE=""

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --peer) PEER="$2"; shift 2 ;;
        --peer=*) PEER="${1#*=}"; shift ;;
        --load-modules) LOAD_MODULES=1; shift ;;
        --core) CORE_OVERRIDE="$2"; shift 2 ;;
        --core=*) CORE_OVERRIDE="${1#*=}"; shift ;;
        --output) OUT_FILE="$2"; shift 2 ;;
        --output=*) OUT_FILE="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Output helpers. Everything goes through `say` so it can be tee'd to a file.
# ---------------------------------------------------------------------------
section() { printf '\n## %s\n\n' "$1"; }
kv()      { printf '%-28s %s\n' "$1:" "$2"; }
say()     { printf '%s\n' "$*"; }
indent()  { sed 's/^/    /'; }

# Verdict accumulators for the summary at the end.
V_GAMBATTE="UNKNOWN"
V_GAMBATTE_VARIANT="unknown"
V_OPT_A="UNKNOWN"
V_OPT_B="UNKNOWN"
V_OPT_C="UNKNOWN"
V_OPT_D="UNKNOWN"
V_PEER="not tested"

KREL="$(uname -r 2>/dev/null)"
MODDIR="/lib/modules/$KREL"

# Kernel config, if the kernel exposes it.
KCONFIG=""
if [ -r /proc/config.gz ] && have zcat; then
    KCONFIG="$(zcat /proc/config.gz 2>/dev/null)"
elif [ -r "/boot/config-$KREL" ]; then
    KCONFIG="$(cat "/boot/config-$KREL")"
fi

kconfig_value() {
    # Prints y / m / n / ? for a CONFIG_ symbol.
    [ -z "$KCONFIG" ] && { echo "?"; return; }
    v="$(printf '%s\n' "$KCONFIG" | grep -E "^$1=" | head -n1 | cut -d= -f2)"
    [ -n "$v" ] && echo "$v" || echo "n"
}

# Module status: loaded / builtin / available / missing.
module_status() {
    m="$1"
    m_us="$(echo "$m" | tr '-' '_')"
    if [ -r /proc/modules ] && grep -q "^$m_us " /proc/modules; then
        echo "loaded"; return
    fi
    if [ -d "/sys/module/$m_us" ]; then
        # Present in sysfs but not in /proc/modules => built into the kernel.
        echo "builtin"; return
    fi
    if [ -r "$MODDIR/modules.builtin" ] && grep -qE "/$m_us\.ko|/$m\.ko" "$MODDIR/modules.builtin"; then
        echo "builtin"; return
    fi
    if have modinfo && modinfo "$m" >/dev/null 2>&1; then
        echo "available"; return
    fi
    if [ -d "$MODDIR" ] && find "$MODDIR" -name "$m.ko*" -o -name "$m_us.ko*" 2>/dev/null | grep -q .; then
        echo "available"; return
    fi
    echo "missing"
}

# Returns 0 if module is usable (loaded, builtin or loadable).
module_ok() {
    case "$(module_status "$1")" in loaded|builtin|available) return 0 ;; *) return 1 ;; esac
}

# Extract printable strings from a binary without depending on `strings`.
binary_strings() {
    if have strings; then
        strings -a "$1" 2>/dev/null
    else
        tr -c '[:print:]' '\n' < "$1" 2>/dev/null | grep -E '.{6,}'
    fi
}

# ---------------------------------------------------------------------------
check_system() {
    section "System"
    kv "Doctor version" "$DOCTOR_VERSION"
    kv "Date" "$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
    kv "Hostname" "$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null)"
    kv "User" "$(id -un 2>/dev/null) (uid $(id -u 2>/dev/null))"
    kv "uname -a" "$(uname -a 2>/dev/null)"
    kv "Architecture" "$(uname -m 2>/dev/null)"

    model=""
    [ -r /proc/device-tree/model ] && model="$(tr -d '\0' < /proc/device-tree/model)"
    [ -z "$model" ] && [ -r /sys/firmware/devicetree/base/model ] && model="$(tr -d '\0' < /sys/firmware/devicetree/base/model)"
    [ -z "$model" ] && [ -r /sys/class/dmi/id/product_name ] && model="$(cat /sys/class/dmi/id/product_name)"
    kv "Device model" "${model:-unknown}"

    if [ -r /proc/device-tree/compatible ]; then
        kv "DT compatible" "$(tr '\0' ' ' < /proc/device-tree/compatible)"
    fi

    soc="$(grep -m1 -iE '^(Hardware|model name)' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
    kv "CPU" "${soc:-unknown}"

    # Firmware identification. Order matters: specific markers first.
    fw="unknown"
    fwver=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        os_name="$(. /etc/os-release 2>/dev/null; echo "${NAME:-}")"
        os_ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION:-${VERSION_ID:-}}")"
        os_pretty="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-}")"
        kv "os-release" "${os_pretty:-$os_name $os_ver}"
    fi
    if [ -f /usr/share/plymouth/themes/text.plymouth ] && grep -qi 'arkos' /usr/share/plymouth/themes/text.plymouth 2>/dev/null; then
        fw="ArkOS"; fwver="$(grep -i 'title' /usr/share/plymouth/themes/text.plymouth | head -n1 | cut -d= -f2-)"
    fi
    if [ -d /home/ark ] && [ "$fw" = "unknown" ]; then fw="ArkOS-like (/home/ark present)"; fi
    if [ -r /etc/os-release ]; then
        case "$os_name" in
            *ROCKNIX*|*rocknix*) fw="ROCKNIX"; fwver="$os_ver" ;;
            *JELOS*) fw="JELOS"; fwver="$os_ver" ;;
            *Batocera*|*batocera*) fw="Batocera"; fwver="$os_ver" ;;
            *AmberELEC*) fw="AmberELEC"; fwver="$os_ver" ;;
        esac
    fi
    if grep -qi 'darkos' /etc/os-release /etc/issue /usr/share/plymouth/themes/text.plymouth 2>/dev/null; then
        fw="dArkOS"
    fi
    if [ -d /mnt/mmc/MUOS ] || [ -d /opt/muos ]; then fw="muOS"; fi
    kv "Firmware (guess)" "$fw${fwver:+ $fwver}"
    say ""
    say "If the firmware guess is wrong, please add the real name and version by hand."
}

# ---------------------------------------------------------------------------
find_retroarch_cores() {
    for d in \
        "$HOME/.config/retroarch/cores" \
        /home/ark/.config/retroarch/cores \
        /home/ark/.config/retroarch32/cores \
        /opt/retroarch/cores \
        /storage/.config/retroarch/cores \
        /tmp/cores \
        /usr/lib/libretro \
        /usr/lib64/libretro \
        /usr/lib/aarch64-linux-gnu/libretro \
        /usr/lib/x86_64-linux-gnu/libretro \
        /usr/local/lib/libretro \
        /usr/share/libretro/cores \
        "$HOME/.var/app/org.libretro.RetroArch/config/retroarch/cores" \
        /mnt/mmc/MUOS/core \
        /opt/muos/core \
        /usr/lib/retroarch/cores
    do
        [ -d "$d" ] || continue
        for f in "$d"/gambatte_libretro.so "$d"/gambatte_libretro.so.*; do
            [ -f "$f" ] && echo "$f"
        done
    done | sort -u
}

GAMBATTE_CORES=""

check_gambatte() {
    section "Gambatte core (link support)"
    if [ -n "$CORE_OVERRIDE" ]; then
        GAMBATTE_CORES="$CORE_OVERRIDE"
    else
        GAMBATTE_CORES="$(find_retroarch_cores)"
    fi
    if [ -z "$GAMBATTE_CORES" ]; then
        say "No gambatte_libretro.so found in the usual places."
        say "Run again with --core /path/to/gambatte_libretro.so if it lives elsewhere,"
        say "or find it with:  find / -name 'gambatte_libretro.so*' 2>/dev/null"
        V_GAMBATTE="NOT FOUND"
        return
    fi

    printf '%s\n' "$GAMBATTE_CORES" | while IFS= read -r core; do
        [ -n "$core" ] || continue
        say "Core: $core"
        kv "  Size" "$(wc -c < "$core" 2>/dev/null) bytes"
        if have md5sum; then kv "  md5" "$(md5sum "$core" | cut -d' ' -f1)"; fi

        opts="$(binary_strings "$core" | grep -oE 'gambatte_gb_link[a-z0-9_]*|gambatte_show_gb_link_settings' | sort -u)"
        if printf '%s\n' "$opts" | grep -q '^gambatte_gb_link_mode$'; then
            kv "  Network link options" "PRESENT (built with HAVE_NETWORK)"
            ipkeys="$(printf '%s\n' "$opts" | grep 'gambatte_gb_link_network_server_ip')"
            n="$(printf '%s\n' "$ipkeys" | grep -c .)"
            if printf '%s\n' "$ipkeys" | grep -q 'octet'; then
                variant="octets ($n fields)"
            elif [ "$n" -ge 12 ]; then
                variant="twelve single digits ($n fields)"
            elif [ "$n" -eq 4 ]; then
                variant="four octets ($n fields)"
            else
                variant="unrecognised ($n fields)"
            fi
            kv "  Server IP option variant" "$variant"
            say "  Link option keys found:"
            printf '%s\n' "$opts" | indent | indent
            echo "net:$variant" > "$TMPSTATE/gambatte.$$"
        else
            kv "  Network link options" "ABSENT (built without HAVE_NETWORK?)"
        fi
        say ""
    done
    if [ -f "$TMPSTATE/gambatte.$$" ]; then
        V_GAMBATTE="YES"
        V_GAMBATTE_VARIANT="$(cut -d: -f2- "$TMPSTATE/gambatte.$$" | tail -n1)"
    else
        V_GAMBATTE="NO"
    fi

    # Look for existing link settings in RetroArch option files.
    for f in \
        "$HOME/.config/retroarch/retroarch-core-options.cfg" \
        /home/ark/.config/retroarch/retroarch-core-options.cfg \
        /storage/.config/retroarch/retroarch-core-options.cfg \
        "$HOME/.config/retroarch/config/Gambatte/Gambatte.opt" \
        /home/ark/.config/retroarch/config/Gambatte/Gambatte.opt \
        /storage/.config/retroarch/config/Gambatte/Gambatte.opt
    do
        if [ -r "$f" ] && grep -q 'gambatte_gb_link' "$f" 2>/dev/null; then
            say "Existing link settings in $f:"
            grep 'gambatte_gb_link\|gambatte_show_gb_link' "$f" | indent
        fi
    done

    if have retroarch; then
        kv "RetroArch" "$(retroarch --version 2>&1 | grep -iE 'retroarch|version' | head -n1)"
    else
        for rb in /opt/retroarch/bin/retroarch /usr/bin/retroarch /usr/local/bin/retroarch; do
            [ -x "$rb" ] && kv "RetroArch" "$rb ($("$rb" --version 2>&1 | head -n1))" && break
        done
    fi
}

# ---------------------------------------------------------------------------
check_usb() {
    section "USB controller and gadget support (Option A)"

    udcs=""
    if [ -d /sys/class/udc ]; then
        udcs="$(ls /sys/class/udc 2>/dev/null)"
    fi
    kv "/sys/class/udc" "${udcs:-<empty or missing>}"
    for u in $udcs; do
        [ -r "/sys/class/udc/$u/state" ] && kv "  $u state" "$(cat "/sys/class/udc/$u/state")"
        [ -r "/sys/class/udc/$u/current_speed" ] && kv "  $u speed" "$(cat "/sys/class/udc/$u/current_speed")"
    done

    if [ -d /sys/class/usb_role ]; then
        for r in /sys/class/usb_role/*; do
            [ -r "$r/role" ] && kv "usb_role $(basename "$r")" "$(cat "$r/role")"
        done
    fi

    # Device tree dr_mode tells whether the OTG port is wired as host/peripheral/otg.
    if [ -d /proc/device-tree ]; then
        find /proc/device-tree -name dr_mode 2>/dev/null | while IFS= read -r f; do
            kv "dr_mode $(dirname "$f" | sed 's|/proc/device-tree||')" "$(tr -d '\0' < "$f")"
        done
    fi

    # Debugfs role file used by dwc2/dwc3 on Rockchip (only readable as root, if mounted).
    for f in /sys/kernel/debug/usb/*/mode /sys/kernel/debug/*.usb/mode; do
        [ -r "$f" ] && kv "debugfs $f" "$(cat "$f" 2>/dev/null)"
    done

    if [ -d /sys/kernel/config ]; then
        if grep -q ' /sys/kernel/config configfs' /proc/mounts 2>/dev/null; then
            kv "configfs" "mounted at /sys/kernel/config"
        else
            kv "configfs" "directory exists, not mounted"
        fi
        [ -d /sys/kernel/config/usb_gadget ] && kv "usb_gadget dir" "present" && \
            kv "  existing gadgets" "$(ls /sys/kernel/config/usb_gadget 2>/dev/null | tr '\n' ' ')"
    else
        kv "configfs" "missing"
    fi

    say ""
    say "Kernel config (? = kernel does not expose its config):"
    for c in CONFIG_USB_GADGET CONFIG_USB_CONFIGFS CONFIG_USB_CONFIGFS_NCM CONFIG_USB_CONFIGFS_ECM \
             CONFIG_USB_CONFIGFS_RNDIS CONFIG_USB_DWC2 CONFIG_USB_DWC2_DUAL_ROLE CONFIG_USB_DWC3 \
             CONFIG_USB_ROLE_SWITCH CONFIG_USB_OTG; do
        kv "  $c" "$(kconfig_value "$c")"
    done

    gadget_mods_ok=1
    for m in libcomposite usb_f_ncm usb_f_ecm; do
        module_ok "$m" || gadget_mods_ok=0
    done
    if [ -n "$udcs" ] && [ "$gadget_mods_ok" = 1 ]; then
        V_OPT_A="LIKELY (UDC present, gadget modules available; still needs a cable test)"
    elif [ -n "$udcs" ]; then
        V_OPT_A="MAYBE (UDC present, but NCM/ECM gadget modules missing)"
    else
        V_OPT_A="NO (no USB device controller visible)"
    fi

    if have lsusb; then
        say ""
        say "lsusb:"
        lsusb 2>/dev/null | indent
    else
        say ""
        say "lsusb not installed; USB devices from sysfs:"
        for d in /sys/bus/usb/devices/*; do
            [ -r "$d/idVendor" ] || continue
            printf '%s %s:%s %s %s\n' "$(basename "$d")" "$(cat "$d/idVendor")" "$(cat "$d/idProduct")" \
                "$(cat "$d/manufacturer" 2>/dev/null)" "$(cat "$d/product" 2>/dev/null)"
        done | indent
    fi
}

# ---------------------------------------------------------------------------
check_modules() {
    section "Kernel modules"
    kv "Module dir" "$( [ -d "$MODDIR" ] && echo "$MODDIR" || echo "$MODDIR (missing)")"
    say ""
    printf '    %-16s %-10s %-10s %s\n' "module" "status" "dry-run" "used for"
    for entry in \
        "plusb:B Prolific host-to-host bridge" \
        "usbnet:B/C USB network core" \
        "cdc_ether:A/C CDC ECM (peer side of gadget, some dongles)" \
        "cdc_ncm:A/C CDC NCM (peer side of gadget)" \
        "cdc_subset:B misc bridge cables" \
        "r8152:C Realtek USB Ethernet" \
        "ax88179_178a:C ASIX USB3 Ethernet" \
        "asix:C ASIX USB2 Ethernet" \
        "rndis_host:A RNDIS peer" \
        "libcomposite:A gadget framework" \
        "usb_f_ncm:A gadget NCM function" \
        "usb_f_ecm:A gadget ECM function" \
        "usb_f_rndis:A gadget RNDIS function" \
        "g_ether:A legacy gadget Ethernet" \
        "cfg80211:D Wi-Fi stack" \
        "mac80211:D Wi-Fi stack"
    do
        m="${entry%%:*}"
        use="${entry#*:}"
        st="$(module_status "$m")"
        dry="-"
        if have modprobe && [ "$st" != "loaded" ] && [ "$st" != "builtin" ]; then
            if modprobe -n "$m" >/dev/null 2>&1; then dry="ok"; else dry="fail"; fi
        fi
        printf '    %-16s %-10s %-10s %s\n' "$m" "$st" "$dry" "$use"
    done

    if [ "$LOAD_MODULES" = 1 ]; then
        say ""
        if [ "$(id -u)" != 0 ]; then
            say "--load-modules requested but not running as root; skipped. Re-run with sudo."
        else
            say "Loading test modules (--load-modules):"
            for m in plusb r8152 ax88179_178a cdc_ncm cdc_ether usb_f_ncm libcomposite; do
                if modprobe "$m" 2>/tmp/linkbridge-modprobe.err; then
                    say "    modprobe $m: ok"
                else
                    say "    modprobe $m: FAILED ($(head -n1 /tmp/linkbridge-modprobe.err))"
                fi
            done
            rm -f /tmp/linkbridge-modprobe.err
        fi
    fi

    if module_ok plusb; then V_OPT_B="LIKELY (plusb driver available)"; else V_OPT_B="NO (plusb driver missing)"; fi
    c_drivers=""
    for m in r8152 ax88179_178a asix cdc_ether; do module_ok "$m" && c_drivers="$c_drivers $m"; done
    if [ -n "$c_drivers" ]; then V_OPT_C="LIKELY (drivers:$c_drivers)"; else V_OPT_C="NO (no common USB Ethernet drivers)"; fi
}

# ---------------------------------------------------------------------------
check_network() {
    section "Network interfaces"
    if have ip; then
        if ip -br addr >/dev/null 2>&1; then
            ip -br addr 2>/dev/null | indent
        else
            ip addr 2>/dev/null | grep -E '^[0-9]+:|inet ' | indent
        fi
    elif have ifconfig; then
        ifconfig -a 2>/dev/null | grep -E '^[a-z]|inet ' | indent
    else
        ls /sys/class/net | indent
    fi

    say ""
    wifi=""
    for n in /sys/class/net/*; do
        name="$(basename "$n")"
        [ "$name" = "lo" ] && continue
        drv=""
        [ -L "$n/device/driver" ] && drv="$(basename "$(readlink "$n/device/driver")")"
        typ="other"
        if [ -d "$n/wireless" ] || [ -d "$n/phy80211" ]; then typ="wifi"; wifi="$wifi $name"; fi
        case "$drv" in
            plusb) typ="bridge cable (Option B)" ;;
            r8152|ax88179_178a|asix) typ="USB Ethernet (Option C)" ;;
            cdc_ncm|cdc_ether|rndis_host) typ="USB CDC (Option A peer / dongle)" ;;
        esac
        kv "  $name" "state=$(cat "$n/operstate" 2>/dev/null) driver=${drv:-none} type=$typ"
    done

    if [ -n "$wifi" ]; then
        V_OPT_D="POSSIBLE (Wi-Fi interface:$wifi)"
    elif module_ok cfg80211; then
        V_OPT_D="NEEDS DONGLE (Wi-Fi stack present, no Wi-Fi interface)"
    else
        V_OPT_D="NO (no Wi-Fi stack)"
    fi

    if ip addr 2>/dev/null | grep -q 'inet 10\.77\.0\.'; then
        say ""
        say "LinkBridge address found: $(ip addr | grep -o 'inet 10\.77\.0\.[0-9]*' | head -n1)"
    fi

    if [ -n "$PEER" ]; then
        section "Peer latency ($PEER)"
        if have ping; then
            res="$(ping -c 20 -i 0.2 "$PEER" 2>&1 || ping -c 20 "$PEER" 2>&1)"
            printf '%s\n' "$res" | tail -n 3 | indent
            if printf '%s\n' "$res" | grep -qE ' 0% packet loss| 0.0% packet loss'; then
                V_PEER="OK ($(printf '%s\n' "$res" | grep -E 'min/avg|round-trip' | sed 's/.*= //'))"
            elif printf '%s\n' "$res" | grep -q 'packet loss'; then
                V_PEER="LOSSY ($(printf '%s\n' "$res" | grep -o '[0-9.]*% packet loss'))"
            else
                V_PEER="FAILED"
            fi
        else
            say "ping not available"
            V_PEER="ping not available"
        fi
        # Is the Gambatte port reachable? (only meaningful while the server is running)
        if have nc; then
            if nc -z -w 2 "$PEER" 56400 >/dev/null 2>&1; then
                kv "TCP $PEER:56400" "open (a Gambatte server is listening)"
            else
                kv "TCP $PEER:56400" "closed (normal unless the host has started the game)"
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
summary() {
    section "Summary"
    kv "Gambatte network link" "$V_GAMBATTE"
    [ "$V_GAMBATTE" = "YES" ] && kv "  server IP variant" "$V_GAMBATTE_VARIANT"
    kv "Option A gadget Ethernet" "$V_OPT_A"
    kv "Option B bridge cable" "$V_OPT_B"
    kv "Option C USB Ethernet" "$V_OPT_C"
    kv "Option D Wi-Fi" "$V_OPT_D"
    kv "Peer ping" "$V_PEER"
    say ""
    say "Verdicts are based on software only; every transport still needs a real cable test."
}

run_all() {
    say "# linkbridge-doctor report"
    check_system
    check_gambatte
    check_usb
    check_modules
    check_network
    summary
}

# ---------------------------------------------------------------------------
TMPSTATE="$(mktemp -d 2>/dev/null || { d="/tmp/linkbridge-doctor.$$"; mkdir -p "$d"; echo "$d"; })"
trap 'rm -rf "$TMPSTATE"' EXIT INT TERM

if [ -z "$OUT_FILE" ]; then
    host="$(hostname 2>/dev/null || echo device)"
    name="linkbridge-doctor-$host-$(date +%Y%m%d-%H%M%S).txt"
    if [ -w . ]; then OUT_FILE="./$name"; else OUT_FILE="$HOME/$name"; fi
fi

run_all 2>&1 | tee "$OUT_FILE"
printf '\nReport saved to %s\n' "$OUT_FILE" >&2
