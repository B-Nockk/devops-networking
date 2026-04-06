#!/bin/env bash

# Enhanced network interface table
net_table() {
    local show_all="false"
    local filter_type=""

    # Parse arguments for 'all' flag and predefined types
    for arg in "$@"; do
        case "${arg,,}" in
            all) show_all="true" ;;
            loopback|ethernet|wireless|bridge|virtual|"vpn/tunnel") filter_type="${arg^^}" ;;
        esac
    done

    ip addr show | awk -v show_all="$show_all" -v filter_type="$filter_type" '
    BEGIN {
        # Print header
        printf "\n"
        printf "\033[1;34m"  # Blue bold
        printf "+----------------------+----------+-----------------+---------------------------+-----------------------+--------------+\n"
        printf "| %-20s | %-8s | %-15s | %-25s | %-21s | %-12s |\n", "INTERFACE", "STATE", "IPV4 ADDRESS", "IPV6 ADDRESS", "SUBNET MASK", "TYPE"
        printf "+----------------------+----------+-----------------+---------------------------+-----------------------+--------------+\n"
        printf "\033[0m"  # Reset
    }

    function cidr_to_mask(cidr) {
        # Convert CIDR to dotted decimal mask
        if(cidr == "") return "-"
        split(cidr, parts, "/")
        mask_bits = parts[2]
        if(mask_bits == "") return "-"

        mask_val = 0xffffffff
        if(mask_bits < 32) {
            mask_val = xor(mask_val, (2^(32-mask_bits))-1)
        }

        return sprintf("%d.%d.%d.%d",
            rshift(and(mask_val, 0xff000000), 24),
            rshift(and(mask_val, 0x00ff0000), 16),
            rshift(and(mask_val, 0x0000ff00), 8),
            and(mask_val, 0x000000ff))
    }

    function print_iface() {
        if(iface != "") {
            # Determine interface type
            iface_type = "UNKNOWN"
            if(iface ~ /^lo$/) {
                iface_type = "LOOPBACK"
            } else if(iface ~ /^eth/ || iface ~ /^en/) {
                iface_type = "ETHERNET"
            } else if(iface ~ /^wl/ || iface ~ /^wlan/) {
                iface_type = "WIRELESS"
            } else if(iface ~ /^br-/ || iface ~ /^docker/) {
                iface_type = "BRIDGE"
            } else if(iface ~ /^veth/ || iface ~ /^vet/) {
                iface_type = "VIRTUAL"
            } else if(iface ~ /^tun/ || iface ~ /^tap/) {
                iface_type = "VPN/TUNNEL"
            }

            # Apply filters
            if(show_all == "false" && iface_type == "LOOPBACK") return
            if(filter_type != "" && iface_type != filter_type) return

            # Color state
            state_color = ""
            reset_color = "\033[0m"
            if(state == "UP") {
                state_color = "\033[0;32m"  # Green
            } else if(state == "DOWN") {
                state_color = "\033[0;31m"  # Red
            } else {
                state_color = "\033[0;33m"  # Yellow for UNKNOWN
            }

            # Extract IP and mask for IPv4
            ipv4_addr = "-"
            subnet_mask = "-"
            if(ipv4 != "") {
                split(ipv4, parts, "/")
                ipv4_addr = parts[1]
                if(parts[2] != "") {
                    subnet_mask = cidr_to_mask(ipv4) " (/" parts[2] ")"
                } else {
                    subnet_mask = cidr_to_mask(ipv4)
                }
            }

            # Extract IP and mask for IPv6
            ipv6_addr = "-"
            if(ipv6 != "") {
                split(ipv6, parts6, "/")
                ipv6_addr = parts6[1]
                # Fallback to IPv6 CIDR if no IPv4 exists
                if(subnet_mask == "-") {
                    subnet_mask = "IPv6 (/" parts6[2] ")"
                }
            }

            printf "| %-20s | %s%-8s%s | %-15s | %-25s | %-21s | %-12s |\n",
                   iface, state_color, state, reset_color, ipv4_addr, ipv6_addr, subnet_mask, iface_type
        }
    }

    /^[0-9]+:/ {
        print_iface()

        # Parse interface line
        gsub(/:/, "", $2)
        iface = $2

        # Extract state
        state = "UNKNOWN"
        for(i=3; i<=NF; i++) {
            if($i == "state") {
                state = $(i+1)
                gsub(/,/, "", state)
                break
            }
        }

        # Reset IPs
        ipv4 = ""
        ipv6 = ""
    }

    /inet / {
        if(iface != "") {
            ipv4 = $2
        }
    }

    /inet6 / {
        if(iface != "") {
            ipv6 = $2
        }
    }

    END {
        print_iface()
        printf "\033[1;34m"  # Blue bold
        printf "+----------------------+----------+-----------------+---------------------------+-----------------------+--------------+\n"
        printf "\033[0m"  # Reset
        printf "\n"
        printf "Usage:\n"
        printf "  net_table                 # Show non-loopback interfaces\n"
        printf "  net_table all             # Show all interfaces (including loopback)\n"
        printf "  net_table <type>          # Filter by type\n"
        printf "  net_table all <type>      # Show all and filter by type\n"
        printf "Types: loopback, ethernet, wireless, bridge, virtual, vpn/tunnel\n\n"
    }'
}

# --- Usage Examples ---
# TODO:: Write a standard entry point with proper idioms for this file
net_table                 # Normal usage
net_table all             # Include loopbacks
net_table bridge          # Show only bridges
net_table all ethernet    # Show all and filter ethernet
