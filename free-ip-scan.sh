#!/bin/sh
#
# check-ip-free.sh
#
# Pings every host address in a CIDR subnet, then prints all IPs that
# did NOT respond (i.e. free/available), highlighting the next free IP
# in sequence.
#
# Usage:
#   ./check-ip-free.sh 192.168.3.0/24     # scan 192.168.3.0/24
#   ./check-ip-free.sh 192.168.2.0/24    # scan 192.168.2.0/24
#   ./check-ip-free.sh 192.168.1.0/16    # scans 192.168.0.0/16 (normalised)
#   ./check-ip-free.sh 10.0.4.0/22       # any mask /1../32 works
#   ./check-ip-free.sh 192.168.3        # old style: bare prefix = /24
#
#   Add --all to print every free IP instead of just the first 50:
#   ./check-ip-free.sh 192.168.3.0/24 --all
#
# Notes:
#   - The network is normalised: 192.168.1.0/16 really describes
#     192.168.0.0/16, so that is what gets scanned.
#   - "Free" means "did not answer a single ICMP echo request".
#     Hosts that silently block ping (common firewall default) will
#     also appear free even though they are in use.
#   - Pings run in parallel (128 at a time, 512 for large subnets).
#     A /24 takes a couple of seconds; a /16 is ~65k pings and takes
#     several minutes.
#   - Uses Linux ping syntax (-W = seconds). On macOS, change
#     PING_OPTS below to "-c 1 -W 1000" (milliseconds).

PING_OPTS="-c 1 -W 1"     # 1 packet, 1s timeout (Linux). macOS: -W 1000
MAX_SHOW=50               # free IPs printed without --all

GREEN='\033[1;32m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# --- parse arguments ---------------------------------------------------

ALL=0
CIDR=""
for arg in "$@"; do
    case "$arg" in
        --all|-a) ALL=1 ;;
        -*) printf 'Unknown option: %s\n' "$arg" >&2; exit 1 ;;
        *)  CIDR="$arg" ;;
    esac
done
[ -z "$CIDR" ] && CIDR="192.168.3.0/24"

# Old-style bare prefix still works: "192.168.3" == "192.168.3.0/24"
case "$CIDR" in
    */*)    ;;
    *.*)    CIDR="$CIDR/24" ;;
    *)      printf 'Invalid network: %s\n' "$CIDR" >&2; exit 1 ;;
esac

# --- turn the CIDR into a host range (awk, so we stay portable) -------

parse_cidr() {
    awk -v cidr="$CIDR" 'BEGIN {
        split(cidr, a, "/")
        ip = a[1]; bits = a[2] + 0
        if (bits < 1 || bits > 32) { print "bad-mask"; exit }
        split(ip, o, ".")
        for (i = 1; i <= 4; i++) {
            if (o[i] == "") o[i] = 0      # allow "192.168.3" style input
            if (o[i] < 0 || o[i] > 255) { print "bad-ip"; exit }
        }
        val = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]
        block = 1
        for (i = 0; i < 32 - bits; i++) block *= 2
        start = int(val / block) * block          # network address
        end   = start + block - 1                 # broadcast address
        if (bits <= 30) { first = start + 1; last = end - 1 }  # skip .0/.255
        else            { first = start;     last = end }
        count = last - first + 1
        printf "%d %d %d %d %s %s %s\n", count, first, last, bits,
            ipstr(start), ipstr(first), ipstr(last)
    }
    function ipstr(n) {
        return int(n/16777216)%256 "." int(n/65536)%256 \
               "." int(n/256)%256 "." n%256
    }'
}

info="$(parse_cidr)"
case "$info" in
    bad-mask|bad-ip)
        printf 'Invalid CIDR: %s\n' "$CIDR" >&2
        exit 1
        ;;
esac

set -- $info
COUNT=$1; FIRST=$2; LAST=$3; BITS=$4; NET_IP=$5; FIRST_IP=$6; LAST_IP=$7

# --- scan: parallel pings via xargs ------------------------------------
# Every host that answers creates the marker file "$SCAN_TMP/<ip>".

SCAN_TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$SCAN_TMP"' EXIT INT TERM
IP_LIST="$SCAN_TMP/hosts"

export SCAN_TMP PING_OPTS

PAR=128                                  # concurrent pings
[ "$COUNT" -gt 4096 ] && PAR=512

printf "Scanning %s/%s (%s - %s), %s hosts...\n" \
    "$NET_IP" "$BITS" "$FIRST_IP" "$LAST_IP" "$COUNT"
if [ "$COUNT" -gt 4096 ]; then
    printf "Large subnet - this will take several minutes.\n"
fi

awk -v lo="$FIRST" -v hi="$LAST" 'BEGIN {
    for (n = lo; n <= hi; n++)
        printf "%d.%d.%d.%d\n", int(n/16777216)%256, int(n/65536)%256, \
               int(n/256)%256, n%256
}' > "$IP_LIST"

xargs -P "$PAR" -n 1 sh -c '
    ping $PING_OPTS "$1" >/dev/null 2>&1 && : > "$SCAN_TMP/$1"
' sh < "$IP_LIST"

# --- report ------------------------------------------------------------
# Walk the list in numeric order; the first address with no marker
# file is the next free IP.

free_count=0
next_free=""
shown=0

while IFS= read -r ip; do
    [ -f "$SCAN_TMP/$ip" ] && continue
    free_count=$((free_count + 1))
    if [ -z "$next_free" ]; then
        next_free="$ip"
        printf "${GREEN}==> %s${RESET} ${DIM}<-- next free IP${RESET}\n" "$next_free"
    elif [ "$ALL" -eq 1 ] || [ "$shown" -lt "$MAX_SHOW" ]; then
        printf "    %s\n" "$ip"
        shown=$((shown + 1))
    fi
done < "$IP_LIST"

echo ""
if [ "$free_count" -eq 0 ]; then
    printf "No free IPs in %s/%s.\n" "$NET_IP" "$BITS"
else
    if [ "$ALL" -eq 0 ] && [ $((shown + 1)) -lt "$free_count" ]; then
        printf "(showing first %s of %s free IPs; use --all to list them all)\n" \
            "$((shown + 1))" "$free_count"
    fi
    printf "%s of %s addresses free in %s/%s — next in line: ${BOLD}%s${RESET}\n" \
        "$free_count" "$COUNT" "$NET_IP" "$BITS" "$next_free"
fi
