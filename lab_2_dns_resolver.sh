#!/usr/bin/env bash
#
# - takes a domain
# - resolves it via three different DNS servers
#       - 8.8.8.8
#       -  1.1.1.1
#       - your local resolver
# - compares the results, and flags if they differ
#
# - Resolves domains via multiple DNS servers, checks ASNs to handle GeoDNS/CDNs,
#   and flags true mismatches.

# ==========================================
# TODO::
# ==========================================
# The one thing not yet in the TSV is TTL — dig +short strips it.
# FOR - Task C, add a get_ttl() alongside resolve_dns that calls
# dig +ttl +short and grabs the numeric field
# then emit it as column 6 in the TSV. Everything else:
#   - resolved IP - which resolver answered
#   - divergence warning) is already there.
#
#
#
# dns_check.sh — multi-resolver DNS auditing tool
#
# Resolves domains via multiple DNS servers, records TTL, checks ASNs
# to handle GeoDNS/CDNs, and flags true mismatches.
#
# Designed to be sourced by netdiag: analyze_domain() emits clean TSV
# (domain | server | ips | ttl | asn | status) for downstream consumers.

# ==========================================
# 1. HELPER: Display Help Menu
# ==========================================
_dns_check_help() {
    cat <<'EOF'
Usage:
  dns_check.sh -d example.com -d facebook.com -s 8.8.8.8 -s 1.1.1.1

Flags:
  -d, --domain   DOMAIN   Domain to resolve (repeatable).
  -s, --server   SERVER   DNS server to query (repeatable). Use 'local' for default resolver.
  -h, --help              Show this help menu.
EOF
}

# ==========================================
# 2. CORE: Resolve IPs for a Domain
# ==========================================
resolve_dns() {
    local domain="$1"
    local server="$2"
    local ip_list

    if [[ "$server" == "local" ]]; then
        ip_list=$(dig +short "$domain" | grep -E '^[a-fA-F0-9.:]+$' | sort | xargs)
    else
        ip_list=$(dig +short @"$server" "$domain" | grep -E '^[a-fA-F0-9.:]+$' | sort | xargs)
    fi

    echo "${ip_list:-NO_RECORDS}"
}

# ==========================================
# 3. CORE: Resolve TTL for a Domain
# ==========================================
# dig +ttl +short emits "<ttl> <record>" per line.
# We grab the lowest TTL present (first A/AAAA record after sort).
resolve_ttl() {
    local domain="$1"
    local server="$2"
    local ttl

    if [[ "$server" == "local" ]]; then
        ttl=$(dig +ttl +short "$domain" \
              | grep -E '^[0-9]+ [a-fA-F0-9.:]+$' \
              | awk '{print $1}' \
              | sort -n \
              | head -1)
    else
        ttl=$(dig +ttl +short @"$server" "$domain" \
              | grep -E '^[0-9]+ [a-fA-F0-9.:]+$' \
              | awk '{print $1}' \
              | sort -n \
              | head -1)
    fi

    echo "${ttl:-N/A}"
}

# ==========================================
# 4. CORE: Get ASN for an IP
# ==========================================
# LATENCY NOTE: This is the slow part — one TCP round-trip to
# whois.cymru.com per IP. With 3 servers x N domains = 3N sequential
# calls. Parallelise with & + wait + tmpfile when N grows.
get_asn() {
    local ip_list="$1"
    local first_ip
    local asn=""

    if [[ "$ip_list" == "NO_RECORDS" || -z "$ip_list" ]]; then
        echo "N/A"
        return
    fi

    first_ip=$(echo "$ip_list" | awk '{print $1}')

    # Primary: Cymru whois (fast, authoritative, no rate-limit concerns)
    if command -v whois >/dev/null 2>&1; then
        asn=$(whois -h whois.cymru.com "$first_ip" 2>/dev/null \
              | tail -n 1 \
              | awk '{print $1}')
    fi

    # Fallback: ipinfo.io REST API
    if [[ -z "$asn" || ! "$asn" =~ ^[0-9]+$ ]]; then
        asn=$(curl -s "https://ipinfo.io/${first_ip}/org" 2>/dev/null \
              | awk '{print $1}')
    fi

    echo "${asn:-UNKNOWN}"
}

# ==========================================
# 5. CORE: Analyze Domain  (TSV emitter)
# ==========================================
# TSV columns: Domain | Server | IPs | TTL | ASN | Status
#
# This is the netdiag integration point. Source this file and call
# analyze_domain() directly — the BASH_SOURCE guard keeps main() silent.
#
# netdiag needs:
#   Resolved IP  → col 3   ($3)
#   TTL          → col 4   ($4)
#   Resolver     → col 2   ($2)
#   Warning flag → col 6   ($6 == "CRITICAL")
analyze_domain() {
    local domain="$1"
    shift
    local servers=("$@")

    local baseline_ips=""
    local baseline_asn=""
    local baseline_server=""

    for server in "${servers[@]}"; do
        local ips asn="" ttl status

        ips=$(resolve_dns "$domain" "$server")
        ttl=$(resolve_ttl "$domain" "$server")
        asn=$(get_asn "$ips")

        if [[ -z "$baseline_server" ]]; then
            baseline_server="$server"
            baseline_ips="$ips"
            baseline_asn="$asn"
            status="BASELINE"
        elif [[ "$ips" == "$baseline_ips" ]]; then
            status="MATCH"
        elif [[ "$asn" == "$baseline_asn" && "$asn" != "N/A" && "$asn" != "UNKNOWN" ]]; then
            status="OK (same ASN)"
        else
            status="CRITICAL"
        fi

        printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
               "$domain" "$server" "$ips" "$ttl" "$asn" "$status"
    done
}

# ==========================================
# 6. UI: Format TSV into ASCII Table
# ==========================================
format_as_table() {
    echo "+---------------------------+-----------------+----------------------------------+-------+-----------+----------------+"
    printf "| %-25s | %-15s | %-32s | %-5s | %-9s | %-14s |\n" \
           "Domain" "DNS Server" "Resolved Records (A/AAAA)" "TTL" "ASN" "Status"
    echo "+---------------------------+-----------------+----------------------------------+-------+-----------+----------------+"

    while IFS=$'\t' read -r domain server ips ttl asn status; do
        printf "| %-25s | %-15s | %-32s | %-5s | %-9s | %-14s |\n" \
               "$domain" "$server" "$ips" "$ttl" "$asn" "$status"
    done

    echo "+---------------------------+-----------------+----------------------------------+-------+-----------+----------------+"
}

# ==========================================
# 7. MAIN
# ==========================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail

    declare -a DOMAINS=()
    declare -a SERVERS=()
    declare -a SUMMARIES=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                _dns_check_help; exit 0 ;;
            -d|--domain)
                [[ -z "${2-}" ]] && { echo "[ERROR] --domain requires a value" >&2; exit 1; }
                DOMAINS+=("$2"); shift 2 ;;
            -s|--server)
                [[ -z "${2-}" ]] && { echo "[ERROR] --server requires a value" >&2; exit 1; }
                SERVERS+=("$2"); shift 2 ;;
            *)
                echo "[ERROR] Unknown option: '$1'" >&2; exit 1 ;;
        esac
    done

    [[ ${#DOMAINS[@]} -eq 0 ]] && { echo "[ERROR] No domains provided. Use -d <domain>." >&2; exit 1; }
    [[ ${#SERVERS[@]} -eq 0 ]] && SERVERS=("8.8.8.8" "1.1.1.1" "local")

    GLOBAL_CRITICAL=0
    all_raw=""

    for dom in "${DOMAINS[@]}"; do
        raw=$(analyze_domain "$dom" "${SERVERS[@]}")
        all_raw+="$raw"$'\n'

        unique_ips=$(echo "$raw"  | awk -F'\t' '{print $3}' | sort -u | wc -l | tr -d ' ')
        unique_asns=$(echo "$raw" | awk -F'\t' '{print $5}' | grep -v '^$' | sort -u | wc -l | tr -d ' ')

        if [[ "$unique_ips" -eq 1 ]]; then
            SUMMARIES+=("-> $dom: All resolvers returned the same IP(s). Perfect consistency.")
        elif [[ "$unique_asns" -eq 1 ]]; then
            asn_val=$(echo "$raw" | awk -F'\t' 'NR==1{print $5}')
            SUMMARIES+=("-> $dom: IPs differ, but all map to ASN $asn_val — likely GeoDNS / CDN anycast.")
        else
            SUMMARIES+=("-> $dom: [CRITICAL] ASN mismatch — resolvers point to different organisations.")
            GLOBAL_CRITICAL=1
        fi
    done

    echo "$all_raw" | grep -v '^$' | format_as_table

    for s in "${SUMMARIES[@]}"; do
        echo "$s"
    done
    echo ""

    if [[ $GLOBAL_CRITICAL -eq 1 ]]; then
        echo "[CRITICAL] One or more domains show ASN mismatches — possible DNS hijacking or misconfiguration." >&2
        exit 2
    else
        exit 0
    fi
fi
