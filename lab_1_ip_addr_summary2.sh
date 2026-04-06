#!/usr/bin/env bash

# net_table — Enhanced network interface summary
#
# Functions:
#   net_table [all] [type] [--help]   Human-readable table output
#   net_table_status [all]            Programmatic: "iface state exit_code" per line
#                                     Exit codes: 0=UP  1=DOWN  2=UNKNOWN
#
# When sourced: both functions are available to the caller
# When executed directly: runs net_table with all passed arguments

# ---------------------------------------------------------------------------
# Usage (shell function, not inside awk — never prints automatically)
# ---------------------------------------------------------------------------
_net_table_usage() {
    printf "Usage:\n"
    printf "  net_table                 # Show non-loopback interfaces\n"
    printf "  net_table all             # Show all interfaces (including loopback)\n"
    printf "  net_table <type>          # Filter by type\n"
    printf "  net_table all <type>      # Show all and filter by type\n"
    printf "  net_table --help          # Show this help\n"
    printf "Types: loopback, ethernet, wireless, bridge, virtual, vpn/tunnel\n\n"
}

# ---------------------------------------------------------------------------
# net_table — human-readable table
# ---------------------------------------------------------------------------
net_table() {
    local show_all="false"
    local filter_type=""

    for arg in "$@"; do
        case "${arg,,}" in
            --help|-h)
                _net_table_usage
                return 0
                ;;
            all)
                show_all="true"
                ;;
            loopback|ethernet|wireless|bridge|virtual|"vpn/tunnel")
                filter_type="${arg^^}"
                ;;
        esac
    done

    ip addr show | awk -v show_all="$show_all" -v filter_type="$filter_type" '
    BEGIN {
        printf "\n"
        printf "\033[1;34m"
        printf "+----------------------+----------+-----------------+---------------------------+-----------------------+--------------+-------------------+-------+\n"
        printf "| %-20s | %-8s | %-15s | %-25s | %-21s | %-12s | %-17s | %-5s |\n",
               "INTERFACE", "STATE", "IPV4 ADDRESS", "IPV6 ADDRESS", "SUBNET MASK", "TYPE", "MAC ADDRESS", "MTU"
        printf "+----------------------+----------+-----------------+---------------------------+-----------------------+--------------+-------------------+-------+\n"
        printf "\033[0m"
    }

    # Pure arithmetic — no rshift/and, works with mawk and gawk
    function cidr_to_mask(cidr,    parts, mask_bits, mask_val) {
        if (cidr == "") return "-"
        split(cidr, parts, "/")
        mask_bits = parts[2] + 0
        if (mask_bits == "")  return "-"

        if      (mask_bits == 0)  mask_val = 0
        else if (mask_bits == 32) mask_val = 4294967295
        else                      mask_val = 4294967295 - (2 ^ (32 - mask_bits) - 1)

        return sprintf("%d.%d.%d.%d",
            int(mask_val / 16777216) % 256,
            int(mask_val / 65536)    % 256,
            int(mask_val / 256)      % 256,
            mask_val                 % 256)
    }

    # Local vars declared in signature to avoid awk global leakage
    function print_iface(    iface_type, state_color, reset_color,
                             ipv4_addr, subnet_mask, ipv6_addr,
                             mac_display, mtu_display, parts, parts6) {
        if (iface == "") return

        # Classify interface type by naming convention
        iface_type = "UNKNOWN"
        if      (iface ~ /^lo$/)              iface_type = "LOOPBACK"
        else if (iface ~ /^eth/ || iface ~ /^en[opsx]/) iface_type = "ETHERNET"
        else if (iface ~ /^wl/ || iface ~ /^wlan/)      iface_type = "WIRELESS"
        else if (iface ~ /^br-/ || iface ~ /^docker/)   iface_type = "BRIDGE"
        else if (iface ~ /^veth/)             iface_type = "VIRTUAL"
        else if (iface ~ /^tun/ || iface ~ /^tap/)      iface_type = "VPN/TUNNEL"

        # Apply filters
        if (show_all == "false" && iface_type == "LOOPBACK") return
        if (filter_type != "" && iface_type != filter_type)  return

        # State colour
        reset_color = "\033[0m"
        state_color = "\033[0;33m"   # yellow = UNKNOWN
        if      (state == "UP")   state_color = "\033[0;32m"  # green
        else if (state == "DOWN") state_color = "\033[0;31m"  # red

        # IPv4 + subnet
        ipv4_addr   = "-"
        subnet_mask = "-"
        if (ipv4 != "") {
            split(ipv4, parts, "/")
            ipv4_addr   = parts[1]
            subnet_mask = cidr_to_mask(ipv4) " (/" parts[2] ")"
        }

        # IPv6 (link-local only shown; subnet falls back to IPv6 prefix if no IPv4)
        ipv6_addr = "-"
        if (ipv6 != "") {
            split(ipv6, parts6, "/")
            ipv6_addr = parts6[1]
            if (subnet_mask == "-") subnet_mask = "IPv6 (/" parts6[2] ")"
        }

        mac_display = (mac != "") ? mac : "-"
        mtu_display = (mtu != "") ? mtu : "-"

        printf "| %-20s | %s%-8s%s | %-15s | %-25s | %-21s | %-12s | %-17s | %-5s |\n",
               iface, state_color, state, reset_color,
               ipv4_addr, ipv6_addr, subnet_mask, iface_type,
               mac_display, mtu_display
    }

    # New interface block
    /^[0-9]+:/ {
        print_iface()

        gsub(/:/, "", $2)
        iface = $2
        mac   = ""
        mtu   = ""
        ipv4  = ""
        ipv6  = ""

        state = "UNKNOWN"
        for (i = 3; i <= NF; i++) {
            if ($i == "state") { state = $(i+1); gsub(/,/, "", state) }
            if ($i == "mtu")   { mtu   = $(i+1) }
        }
    }

    /link\/ether/ { if (iface != "") mac = $2 }
    /inet /       { if (iface != "") ipv4 = $2 }
    /inet6 /      { if (iface != "") ipv6 = $2 }

    END {
        print_iface()
        printf "\033[1;34m"
        printf "+----------------------+----------+-----------------+---------------------------+-----------------------+--------------+-------------------+-------+\n"
        printf "\033[0m\n"
    }'
}

# ---------------------------------------------------------------------------
# net_table_status — programmatic entry point for netdiag / report_lib
#
# Outputs one line per non-loopback interface (pass "true" to include all):
#   <iface>  <state>  <exit_code>
# Exit codes: 0=UP  1=DOWN  2=UNKNOWN
#
# Typical caller pattern:
#   while read -r iface state code; do
#       exit_codes+=("$code")
#       ...
#   done < <(net_table_status)
# ---------------------------------------------------------------------------
net_table_status() {
    local show_all="${1:-false}"

    ip addr show | awk -v show_all="$show_all" '
    function emit(    code) {
        if (iface == "") return
        if (show_all != "true" && iface == "lo") return
        code = (state == "UP") ? 0 : (state == "DOWN") ? 1 : 2
        printf "%s %s %d\n", iface, state, code
    }

    /^[0-9]+:/ {
        emit()
        gsub(/:/, "", $2)
        iface = $2
        state = "UNKNOWN"
        for (i = 3; i <= NF; i++) {
            if ($i == "state") { state = $(i+1); gsub(/,/, "", state) }
        }
    }

    END { emit() }
    '
}

# ---------------------------------------------------------------------------
# Entry point — sourcing is the primary use case; direct execution is a
# convenience wrapper so you can run the script without sourcing it
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    net_table "$@"
fi
