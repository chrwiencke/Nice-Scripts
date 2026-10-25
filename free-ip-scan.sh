#!/bin/sh
#
# free-ip-scan.sh
#
# Pings every address in a /24 subnet (default 192.168.3.0/24), then
# prints all IPs that did NOT respond (i.e. free / available), with
# the next free IP in sequence highlighted.
#
# Usage:
#   ./free-ip-scan.sh              # scan 192.168.3.0/24
#   ./free-ip-scan.sh 192.168.3    # same thing
#   ./free-ip-scan.sh 10.0.0       # scan 10.0.0.0/24 instead
#
# Notes:
#   - "Free" means "did not answer a single ICMP echo request".
#     Hosts that silently block ping (common firewall default) will
#     also appear free even though they are in use.
#   - Pings run in parallel, so the whole scan takes ~1-2 seconds.
#   - Uses Linux ping syntax (-W = seconds). On macOS, change
#     PING_OPTS below to "-c 1 -W 1000" (milliseconds).

PREFIX="${1:-192.168.3}"
PING_OPTS="-c 1 -W 1"     # 1 packet, 1s timeout (Linux). macOS: -W 1000

GREEN='\033[1;32m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

TMPDIR_SCAN="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR_SCAN"' EXIT INT TERM

# --- scan: one background ping per address, all in parallel ---------
# Every host that answers creates a marker file "$TMPDIR_SCAN/<n>".

i=1
while [ "$i" -le 254 ]; do
    (
        ping $PING_OPTS "$PREFIX.$i" >/dev/null 2>&1 \
            && : > "$TMPDIR_SCAN/$i"
    ) &
    i=$((i + 1))
done
wait   # block until every ping has finished

# --- report -----------------------------------------------------------
# Walk .1 ... .254 in order (.0 = network, .255 = broadcast are skipped).
# The first address with no marker file is the next free IP.

free_count=0
next_free=""

i=1
while [ "$i" -le 254 ]; do
    if [ ! -f "$TMPDIR_SCAN/$i" ]; then
        free_count=$((free_count + 1))
        if [ -z "$next_free" ]; then
            next_free="$PREFIX.$i"
            printf "${GREEN}==> %s${RESET} ${DIM}<-- next free IP${RESET}\n" "$next_free"
        else
            printf "    %s\n" "$PREFIX.$i"
        fi
    fi
    i=$((i + 1))
done

echo ""
if [ "$free_count" -eq 0 ]; then
    printf "No free IPs found in %s.0/24.\n" "$PREFIX"
else
    printf "%d free IPs in %s.0/24 — next in line: ${BOLD}%s${RESET}\n" \
        "$free_count" "$PREFIX" "$next_free"
fi
