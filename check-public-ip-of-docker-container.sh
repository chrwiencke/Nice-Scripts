#!/bin/bash

check_container_ip() {
    local container=$1

    # Try curl first, then fallback to wget. api.ipify.org is faster for raw IPs.
    local ip=$(sudo docker exec "$container" sh -c 'curl -s api.ipify.org || wget -qO- api.ipify.org' 2>/dev/null | grep -Eo '\b([0-9]{1,3}.){3}[0-9]{1,3}\b' | head -n 1)

    if [ -n "$ip" ]; then
        echo "$container public IP: $ip"
    else
        echo "$container public IP: FAILED"
    fi
}

if [ $# -eq 0 ]; then
    echo "Usage: $0 <container> [container...]"
    echo "Example: $0 netbird"
    echo "         $0 netbird n8n"
    exit 1
fi

for container in "$@"; do
    check_container_ip "$container"
done
