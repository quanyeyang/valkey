#!/usr/bin/env bash
# rdma-crash-repro.sh - focused reproducer for the RDMA teardown crash
#
#     === ASSERTION FAILED ===
#     ==> networking.c:2174 'ln != NULL' is not true   (freeClient / close_asap)
#
# Observed in the rx-size benchmark (rdma-rx-results/20260826-215628) at
# clients=4 connection teardown on RDMA, never (so far) on TCP.
#
# Repeats a short c=4 benchmark against an RDMA server until it crashes
# (or --runs is exhausted). Every server start gets its own log; with --gdb
# the server runs under gdb -batch and a full backtrace is captured.
#
# Safety model mirrors utils/rdma-rx-size-benchmark.sh: only creates/removes
# its own dummy/RXE devices, never pkill, memlock applied to this shell only.
#
# Usage:
#   ./utils/rdma-crash-repro.sh [--clients 4] [--pipeline 1] [--rx-size 1048576]
#                               [--runs 40] [--gdb] [--keep-rxe]
set -Eeuo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

RDMA_NETDEV="${RDMA_NETDEV:-dummy0}"
RDMA_DEVICE="${RDMA_DEVICE:-rxe_dummy}"
RDMA_IP="${RDMA_IP:-10.200.0.1}"
RDMA_PREFIX="${RDMA_PREFIX:-24}"
RDMA_PORT="${RDMA_PORT:-16381}"
CLIENTS=4
PIPELINE=1
RX_SIZE=1048576
RUNS=40
USE_GDB=0
KEEP_RXE=0
CREATED_NETDEV=0
CREATED_RXE=0
SERVER_PID=""
OUT=""

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clients)  CLIENTS="$2"; shift 2 ;;
        --pipeline) PIPELINE="$2"; shift 2 ;;
        --rx-size)  RX_SIZE="$2"; shift 2 ;;
        --runs)     RUNS="$2"; shift 2 ;;
        --gdb)      USE_GDB=1; shift ;;
        --keep-rxe) KEEP_RXE=1; shift ;;
        *) die "unknown arg: $1" ;;
    esac
done

rxe_link_exists() { rdma link show 2>/dev/null | grep -q "^[[:space:]]*link $RDMA_DEVICE/"; }

cleanup() {
    trap - EXIT INT TERM
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        local i
        for i in $(seq 1 50); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.1; done
        kill -9 "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
    if (( ! KEEP_RXE )); then
        sudo -n -v 2>/dev/null || true
        if (( CREATED_RXE )) && rxe_link_exists; then sudo -n rdma link delete "$RDMA_DEVICE" 2>/dev/null || true; fi
        if (( CREATED_NETDEV )) && ip link show dev "$RDMA_NETDEV" >/dev/null 2>&1; then sudo -n ip link del "$RDMA_NETDEV" 2>/dev/null || true; fi
    fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

setup_rxe() {
    sudo -v
    sudo prlimit --memlock=unlimited --pid "$$"
    [[ "$(ulimit -l)" == "unlimited" ]] || die "memlock not unlimited"
    sudo modprobe dummy
    sudo modprobe rdma_rxe
    if ! ip link show dev "$RDMA_NETDEV" >/dev/null 2>&1; then
        sudo ip link add "$RDMA_NETDEV" type dummy
        CREATED_NETDEV=1
    fi
    if ! ip -4 -o addr show dev "$RDMA_NETDEV" | awk -v ip="$RDMA_IP" '{split($4,a,"/"); if (a[1]==ip) found=1} END {exit !found}'; then
        sudo ip addr add "$RDMA_IP/$RDMA_PREFIX" dev "$RDMA_NETDEV"
    fi
    sudo ip link set "$RDMA_NETDEV" up
    if ! rxe_link_exists; then
        sudo rdma link add "$RDMA_DEVICE" type rxe netdev "$RDMA_NETDEV"
        CREATED_RXE=1
        local i
        for i in $(seq 1 50); do rxe_link_exists && break; sleep 0.1; done
    fi
    rxe_link_exists || die "RXE $RDMA_DEVICE not available"
}

start_server() {
    SERVER_LOG="$OUT/server-$(printf '%03d' $((SERVER_SEQ + 1))).log"
    SERVER_SEQ=$((SERVER_SEQ + 1))
    if (( USE_GDB )); then
        cat >"$OUT/gdb.cmd" <<'EOF'
set pagination off
set debuginfod enabled off
handle SIGPIPE nostop noprint pass
handle SIGUSR2 nostop noprint pass
break _serverAssert
commands
silent
printf "\n===== ASSERT HIT =====\n"
bt 40
printf "\n===== assert args =====\n"
info args
printf "\n===== clients_to_close =====\n"
print server.clients_to_close->len
continue
end
run
EOF
        gdb -batch -x "$OUT/gdb.cmd" \
            --args ./src/valkey-server valkey.conf \
                --port 0 --protected-mode no --save "" --appendonly no --daemonize no \
                --rdma-bind "$RDMA_IP" --rdma-port "$RDMA_PORT" --rdma-rx-size "$RX_SIZE" \
            >"$SERVER_LOG" 2>&1 &
        SERVER_PID=$!
    else
        ./src/valkey-server valkey.conf \
            --port 0 --protected-mode no --save "" --appendonly no --daemonize no \
            --rdma-bind "$RDMA_IP" --rdma-port "$RDMA_PORT" --rdma-rx-size "$RX_SIZE" \
            >"$SERVER_LOG" 2>&1 &
        SERVER_PID=$!
    fi
    local i deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        if ./src/valkey-cli --rdma -h "$RDMA_IP" -p "$RDMA_PORT" PING >/dev/null 2>&1; then return 0; fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log "server exited during startup; log tail:"; tail -5 "$SERVER_LOG"; return 1
        fi
        sleep 0.2
    done
    log "server not reachable in 15s"; tail -5 "$SERVER_LOG"; return 1
}

server_alive() { [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; }

OUT="rdma-rx-results/$(date +%Y%m%d-%H%M%S)-rdma-crash-repro"
mkdir -p "$OUT"
setup_rxe
SERVER_SEQ=0
start_server || die "initial server start failed"

log "reproducing: clients=$CLIENTS pipeline=$PIPELINE rx-size=$RX_SIZE value=65536, up to $RUNS runs"
crashes=0
for i in $(seq 1 "$RUNS"); do
    if ! server_alive; then
        log "run $i: server DEAD BEFORE RUN - restarting"
        crashes=$((crashes + 1))
        start_server || die "server restart failed at run $i"
        continue
    fi
    rc=0
    timeout -k 5 60 ./src/valkey-benchmark \
        --rdma -h "$RDMA_IP" -p "$RDMA_PORT" \
        -c "$CLIENTS" -P "$PIPELINE" -d 65536 \
        --duration 3 --warmup 1 --threads 1 --precision 3 --csv \
        -- SET crash-repro-key __data__ \
        >"$OUT/run-$(printf '%03d' $i).csv" 2>"$OUT/run-$(printf '%03d' $i).err" || rc=$?
    sleep 0.3
    if ! server_alive; then
        crashes=$((crashes + 1))
        log "run $i: SERVER CRASHED (bench rc=$rc) - log: $SERVER_LOG"
        if (( USE_GDB )); then
            wait "$SERVER_PID" 2>/dev/null || true
            SERVER_PID=""
            log "gdb backtrace captured in $SERVER_LOG - stopping after first crash"
            break
        fi
        start_server || die "server restart failed at run $i"
    else
        strlen="$(./src/valkey-cli --rdma -h "$RDMA_IP" -p "$RDMA_PORT" --raw STRLEN crash-repro-key 2>/dev/null || echo fail)"
        [[ "$strlen" == "65536" ]] || log "run $i: strlen=$strlen (bench rc=$rc)"
    fi
done

log "done: $crashes crash(es) in $i run(s); logs in $OUT"
grep -l 'ASSERTION FAILED' "$OUT"/server-*.log 2>/dev/null || true
exit $(( crashes > 0 ? 1 : 0 ))
