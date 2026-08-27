#!/usr/bin/env bash
# tcp-crash-repro.sh - TCP differential test for the networking.c:2174 crash
#
# The RDMA rx-size benchmark (rdma-rx-results/20260826-215628) hit this crash
# at clients=4 connection teardown:
#     === ASSERTION FAILED ===
#     ==> networking.c:2174 'ln != NULL' is not true   (freeClient/close_asap)
#
# This script repeats the same benchmark shape over plain TCP on 127.0.0.1 to
# determine whether the crash is RDMA-specific or a generic teardown race.
# Ad-hoc diagnostic tool; results archived under rdma-rx-results/.
set -Eeuo pipefail
export LC_ALL=C

cd "$(dirname "$0")/.."
PORT=16380
KEY=tcp-crash-key
OUT="rdma-rx-results/$(date +%Y%m%d-%H%M%S)-tcp-differential"
mkdir -p "$OUT"
SERVER_PID=""
LOGS=()

start_server() {
    local log="$OUT/server-tcp-$(date +%H%M%S)-$$.log"
    LOGS+=("$log")
    ./src/valkey-server valkey.conf \
        --port "$PORT" --bind 127.0.0.1 --protected-mode no \
        --save "" --appendonly no --daemonize no \
        >"$log" 2>&1 &
    SERVER_PID=$!
    local i
    for i in $(seq 1 50); do
        ./src/valkey-cli -h 127.0.0.1 -p "$PORT" PING >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    echo "FATAL: TCP server failed to start"; tail -5 "$log"; exit 1
}

server_alive() { [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; }

cleanup() { [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

run_combo() {
    local c="$1" P="$2" n="$3" label="c${1}-P${2}" crashes=0 rc i strlen benchrc
    echo "=== combo $label: $n runs (value=65536, duration 5s + warmup 2s)"
    for i in $(seq 1 "$n"); do
        server_alive || { echo "  [$label] server dead before run $i, restarting"; start_server; }
        benchrc=0
        ./src/valkey-benchmark -h 127.0.0.1 -p "$PORT" -c "$c" -P "$P" -d 65536 \
            --duration 5 --warmup 2 --threads 1 --precision 3 --csv \
            -- SET "$KEY" __data__ \
            >"$OUT/${label}-run${i}.csv" 2>"$OUT/${label}-run${i}.err" || benchrc=$?
        sleep 0.3
        if ! server_alive; then
            crashes=$((crashes + 1))
            echo "  [$label] run $i: SERVER DEAD (bench rc=$benchrc)"
            start_server
        else
            strlen="$(./src/valkey-cli -h 127.0.0.1 -p "$PORT" --raw STRLEN "$KEY" 2>/dev/null || echo fail)"
            [[ "$strlen" == "65536" ]] || echo "  [$label] run $i: strlen=$strlen (bench rc=$benchrc)"
        fi
    done
    echo "  [$label] result: $crashes/$n crashes"
    echo "$label crashes=$crashes/$n" >>"$OUT/summary.txt"
}

start_server
run_combo 4 1 20
run_combo 4 16 20
run_combo 8 16 10
run_combo 50 16 5

echo "=== assertions found in server logs:"
grep -l 'ASSERTION FAILED' "${LOGS[@]}" 2>/dev/null || echo "  (none)"
echo "results: $OUT"
