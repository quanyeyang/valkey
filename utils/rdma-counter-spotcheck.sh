#!/usr/bin/env bash
# Spot-check RDMA bench stats (VALKEY_RDMA_BENCH_STATS=1).
set -Eeuo pipefail
export LC_ALL=C
export VALKEY_RDMA_BENCH_STATS=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RDMA_NETDEV="${RDMA_NETDEV:-dummy0}"
RDMA_DEVICE="${RDMA_DEVICE:-rxe_dummy}"
RDMA_IP="${RDMA_IP:-10.200.0.1}"
RDMA_PREFIX="${RDMA_PREFIX:-24}"
RDMA_PORT="${RDMA_PORT:-16379}"
BENCH_KEY="rdma-rx-benchmark-key"
KEEP_RXE=1
SERVER_PID=""
SERVER_LOG=""
SERVER_INSTANCE=0
RESULTS_DIR="$REPO_ROOT/rdma-rx-results/$(date +%Y%m%d-%H%M%S)-spotcheck-v2"
DURATION=3
WARMUP=1
BENCH_TIMEOUT=90

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
stop_server() { [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; }
cleanup() { stop_server; }
trap cleanup EXIT

setup_rxe() {
    sudo modprobe dummy rdma_rxe 2>/dev/null || true
    ip link show dev "$RDMA_NETDEV" >/dev/null 2>&1 || sudo ip link add "$RDMA_NETDEV" type dummy
    ip -4 -o addr show dev "$RDMA_NETDEV" | awk -v ip="$RDMA_IP" '{split($4,a,"/"); if (a[1]==ip) found=1} END {exit !found}' \
        || sudo ip addr add "$RDMA_IP/$RDMA_PREFIX" dev "$RDMA_NETDEV" 2>/dev/null || true
    sudo ip link set "$RDMA_NETDEV" up
    rdma link show 2>/dev/null | grep -q "$RDMA_DEVICE/" \
        || sudo rdma link add "$RDMA_DEVICE" type rxe netdev "$RDMA_NETDEV"
}

get_server_rx_reannounce() {
    timeout 10 ./src/valkey-cli --rdma -h "$RDMA_IP" -p "$RDMA_PORT" INFO rdma 2>/dev/null \
        | awk -F: '/^rx_window_reannounce_count:/ { gsub(/\r/, "", $2); print $2; exit }'
}

sum_client_bench_stats() {
    awk '/^RDMA_BENCH_STATS / {
        for (i = 1; i <= NF; i++) {
            split($i, kv, "=")
            if (kv[1] == "tx_bytes") tb += kv[2]
            else if (kv[1] == "tx_wait_count") tc += kv[2]
            else if (kv[1] == "tx_wait_ns") tn += kv[2]
        }
    } END { printf "%s %s %s\n", tb + 0, tc + 0, tn + 0 }' "$1" 2>/dev/null
}

start_server() {
    local rx="$1"
    SERVER_INSTANCE=$((SERVER_INSTANCE + 1))
    mkdir -p "$RESULTS_DIR/server-logs"
    SERVER_LOG="$RESULTS_DIR/server-logs/server-rx-${rx}.log"
    stop_server
    VALKEY_RDMA_BENCH_STATS=1 ./src/valkey-server "$REPO_ROOT/valkey.conf" \
        --port 0 --protected-mode no --save "" --appendonly no --daemonize no \
        --rdma-bind "$RDMA_IP" --rdma-port "$RDMA_PORT" --rdma-rx-size "$rx" \
        >"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 1 50); do
        timeout 5 ./src/valkey-cli --rdma -h "$RDMA_IP" -p "$RDMA_PORT" PING 2>/dev/null | grep -q PONG && return 0
        sleep 0.2
    done
    return 1
}

run_case() {
    local rx="$1" value="$2" clients="$3" pipeline="$4" note="$5"
    local tag="spot-rx${rx}-d${value}-c${clients}-P${pipeline}"
    local raw_out="$RESULTS_DIR/raw/${tag}.csv"
    local raw_err="$RESULTS_DIR/raw/${tag}.err"
    mkdir -p "$RESULTS_DIR/raw"

    local before after rx_delta tx_bytes tx_wait_count tx_wait_ns
    before="$(get_server_rx_reannounce)"; before="${before:-0}"

    VALKEY_RDMA_BENCH_STATS=1 timeout -k 10 "$BENCH_TIMEOUT" ./src/valkey-benchmark \
        --rdma -h "$RDMA_IP" -p "$RDMA_PORT" -c "$clients" -P "$pipeline" -d "$value" \
        --duration "$DURATION" --warmup "$WARMUP" --threads 1 --precision 3 --csv \
        -- SET "$BENCH_KEY" __data__ >"$raw_out" 2>"$raw_err" || true

    after="$(get_server_rx_reannounce)"; after="${after:-0}"
    rx_delta=$((after - before))
    read -r tx_bytes tx_wait_count tx_wait_ns < <(sum_client_bench_stats "$raw_err")

    local rpg avg_us nwr
    rpg="$(awk -v rx="$rx_delta" -v tb="$tx_bytes" 'BEGIN { if (tb > 0) printf "%.2f", rx / (tb / (1024*1024*1024)); else print "n/a" }')"
    avg_us="$(awk -v tc="$tx_wait_count" -v tn="$tx_wait_ns" 'BEGIN { if (tc > 0) printf "%.1f", tn / tc / 1000; else print "0" }')"
    nwr="$(awk -v tn="$tx_wait_ns" -v dur="$DURATION" -v c="$clients" 'BEGIN { printf "%.6f", tn / (dur * 1e9 * c) }')"

    printf '%s\n' "$note,$rx_delta,$rpg,$tx_wait_count,$tx_wait_ns,$avg_us,$nwr" >> "$RESULTS_DIR/spotcheck.csv"
    log "  $note: rx_reannounce=$rx_delta rpg=$rpg tx_wait_count=$tx_wait_count tx_wait_ns=$tx_wait_ns stall_ratio=$nwr"
}

[[ $EUID -ne 0 ]] && sudo -v && sudo prlimit --memlock=unlimited --pid $$ 2>/dev/null || true
mkdir -p "$RESULTS_DIR/raw"
log "spot-check v2: $RESULTS_DIR"
setup_rxe
printf '%s\n' 'note,rx_reannounce_count,reannounces_per_gib,tx_wait_count,tx_wait_ns,avg_wait_us,normalized_wait_ratio' > "$RESULTS_DIR/spotcheck.csv"

CASES=(
    "65536:65536:1:1:A_value_eq_rx"
    "65536:4194304:1:1:B_value_gtgt_rx"
    "65536:4194304:4:16:C_value_gtgt_rx_heavy"
    "4194304:65536:1:1:D_rx_gtgt_value"
)
current_rx=""
for spec in "${CASES[@]}"; do
    IFS=: read -r rx value clients pipeline note <<<"$spec"
    [[ "$rx" != "$current_rx" ]] && start_server "$rx" && current_rx="$rx"
    log "case $note"
    run_case "$rx" "$value" "$clients" "$pipeline" "$note"
done
stop_server
log "server shutdown stats:"
grep '^RDMA_BENCH_STATS ' "$SERVER_LOG" 2>/dev/null | tail -3 || true
column -s, -t "$RESULTS_DIR/spotcheck.csv" 2>/dev/null || cat "$RESULTS_DIR/spotcheck.csv"
