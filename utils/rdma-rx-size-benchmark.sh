#!/usr/bin/env bash
#
# utils/rdma-rx-size-benchmark.sh
#
# Reproducible RXE (Soft-RoCE) experiment: behaviour of large SET requests
# under different server-side `rdma-rx-size` values.
#
#   --smoke     quick functional matrix (RX sizes x {RX-1, RX, RX+1})
#   --full      full measurement matrix (5 RX sizes x 4 value sizes x
#               {1,4} clients x {1,16} pipeline x 3 repetitions)
#   --keep-rxe  do not tear down the dummy/RXE devices on exit (they are
#               only deleted when this script created them anyway)
#
# Environment overrides (all optional):
#   RDMA_NETDEV (dummy0)  RDMA_DEVICE (rxe_dummy)  RDMA_IP (10.200.0.1)
#   RDMA_PREFIX (24)      RDMA_PORT (16379)
#
# Safety model:
#   * runs as a normal user; only these privileged operations are performed:
#       - sudo -v / sudo prlimit --memlock=unlimited --pid $$ (this shell)
#       - modprobe dummy / modprobe rdma_rxe
#       - create/delete the dummy netdev and RXE link *created by this script*
#   * never touches system valkey services, never uses pkill/killall;
#     only kills the valkey-server PIDs it started and recorded
#   * results are owned by the invoking user (server/benchmark never sudo'd)
#
# Build: `make distclean` is run before every build (user-approved) so that
# stale artifacts from other branches cannot leak into the RDMA build, then
# `make -j$(nproc) BUILD_RDMA=yes USE_FAST_FLOAT=yes`.
#
# NOTE on scope: this experiment runs on software RDMA (rdma_rxe on a dummy
# netdev). It validates protocol mechanics, the test harness and trends.
# It must NOT be read as a statement about physical 100G RDMA performance.
# payload_gbps = rps * value_size * 8 / 1e9 is a payload-only estimate and
# excludes RESP protocol framing and RDMA protocol overhead.

set -Eeuo pipefail
export LC_ALL=C

# ----------------------------- tunables --------------------------------------

RDMA_NETDEV="${RDMA_NETDEV:-dummy0}"
RDMA_DEVICE="${RDMA_DEVICE:-rxe_dummy}"
RDMA_IP="${RDMA_IP:-10.200.0.1}"
RDMA_PREFIX="${RDMA_PREFIX:-24}"
RDMA_PORT="${RDMA_PORT:-16379}"

BENCH_KEY="rdma-rx-benchmark-key"   # fixed key: DB stays at 1 key, no growth

# smoke mode
SMOKE_RX_SIZES=(65536 1048576 4194304)     # value sizes are RX-1, RX, RX+1
SMOKE_DURATION=2
SMOKE_WARMUP=1
SMOKE_REPS=1
SMOKE_BENCH_TIMEOUT=60

# full mode
FULL_RX_SIZES=(65536 262144 1048576 4194304 16777216)
FULL_VALUE_SIZES=(65536 262144 1048576 4194304)
FULL_CLIENTS=(1 4)
FULL_PIPELINE=(1 16)
FULL_DURATION=5
FULL_WARMUP=2
FULL_REPS=3
FULL_BENCH_TIMEOUT=120

# ----------------------------- runtime state ---------------------------------

MODE=""
KEEP_RXE=0
CREATED_NETDEV=0
CREATED_RXE=0
SERVER_PID=""
SERVER_LOG=""
SERVER_INSTANCE=0
RESULTS_DIR=""
FAIL_COUNT=0
RUN_COUNT=0
TOTAL_RUNS=0

# The RDMA teardown UAF (connRdmaEventHandler keeps using a connection freed
# by a nested callHandler, rdma.c:736/743) can kill the server after a
# benchmark completes. Measurements are unaffected (crash is strictly
# post-run), so restart the server and continue instead of abandoning the
# remaining runs. The budget only guards against a genuinely broken
# environment (e.g. server cannot start at all).
MAX_SERVER_RESTARTS_PER_RX=12

RX_SIZES=()
CLIENTS_LIST=()
PIPELINE_LIST=()
VALUES=()          # value sizes for the current rx
DURATION=0
WARMUP=0
REPS=0
BENCH_TIMEOUT=0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ----------------------------- helpers ---------------------------------------

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

# Existence check based on output, not exit code: `rdma link show <name>`
# filtering semantics are unreliable across iproute2 versions.
rxe_link_exists() {
    rdma link show 2>/dev/null | grep -q "^[[:space:]]*link $RDMA_DEVICE/"
}

usage() {
    cat <<EOF
Usage: $0 --smoke | --full [--keep-rxe]

  --smoke     quick validation run (3 RX sizes x {RX-1,RX,RX+1} values,
              1 client, no pipeline, 2s duration, 1s warmup, 1 repetition)
  --full      full matrix (5 RX sizes x 4 value sizes x {1,4} clients x
              {1,16} pipeline x 3 repetitions, 5s duration, 2s warmup)
  --keep-rxe  keep the dummy/RXE devices on exit (only deleted if created)

Environment overrides:
  RDMA_NETDEV=$RDMA_NETDEV RDMA_DEVICE=$RDMA_DEVICE RDMA_IP=$RDMA_IP
  RDMA_PREFIX=$RDMA_PREFIX RDMA_PORT=$RDMA_PORT

Results are written to rdma-rx-results/<timestamp>/ inside the repo.
EOF
}

parse_args() {
    if [[ $# -lt 1 ]]; then
        usage >&2
        die "one of --smoke / --full is required"
    fi
    local saw_mode=0
    for arg in "$@"; do
        case "$arg" in
            --smoke|--full)
                [[ $saw_mode -eq 0 ]] || die "--smoke and --full are mutually exclusive"
                saw_mode=1
                MODE="${arg#--}"
                ;;
            --keep-rxe) KEEP_RXE=1 ;;
            -h|--help)  usage; exit 0 ;;
            *)          usage >&2; die "unknown argument: $arg" ;;
        esac
    done
}

check_deps() {
    local missing=() cmd
    for cmd in sudo prlimit modprobe ip rdma ibv_devices ibv_devinfo \
               timeout lscpu git make awk nproc cut tr grep seq date; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "missing required commands: ${missing[*]} (install the corresponding packages, e.g. iproute2, rdma-core; this script does not install anything)"
    fi
}

# ----------------------------- cleanup ---------------------------------------

stop_server() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            kill "$SERVER_PID" 2>/dev/null || true
            local i
            for i in $(seq 1 100); do
                kill -0 "$SERVER_PID" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 "$SERVER_PID" 2>/dev/null; then
                warn "server PID $SERVER_PID did not exit on SIGTERM, sending SIGKILL"
                kill -9 "$SERVER_PID" 2>/dev/null || true
            fi
        fi
        wait "$SERVER_PID" 2>/dev/null || true   # reap
        SERVER_PID=""
    fi
}

cleanup() {
    trap - EXIT INT TERM
    stop_server
    if (( ! KEEP_RXE )); then
        sudo -n -v 2>/dev/null || true   # refresh timestamp non-interactively, never block
        if (( CREATED_RXE )) && rxe_link_exists; then
            sudo -n rdma link delete "$RDMA_DEVICE" 2>/dev/null \
                || warn "failed to delete RDMA link $RDMA_DEVICE (remove manually)"
        fi
        if (( CREATED_NETDEV )) && ip link show dev "$RDMA_NETDEV" >/dev/null 2>&1; then
            sudo -n ip link del "$RDMA_NETDEV" 2>/dev/null \
                || warn "failed to delete netdev $RDMA_NETDEV (remove manually)"
        fi
    else
        log "cleanup: --keep-rxe given, leaving $RDMA_NETDEV/$RDMA_DEVICE in place"
    fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ----------------------------- privilege setup -------------------------------

do_privilege_setup() {
    [[ $EUID -ne 0 ]] || die "run as a normal user, not root (results must stay user-owned)"
    sudo -v || die "sudo -v failed (password prompt unavailable?)"
    # Unlimited memlock for THIS shell; server and benchmark inherit it.
    # Done once, here, so every child of this script is covered.
    sudo prlimit --memlock=unlimited --pid "$$"
    local ml
    ml="$(ulimit -l)"
    [[ "$ml" == "unlimited" ]] || die "memlock is '$ml' after prlimit, expected 'unlimited' - aborting before any benchmark"
    log "memlock: unlimited (applied to script shell PID $$, inherited by children)"
}

# ----------------------------- build -----------------------------------------

build_valkey() {
    # distclean first (user-approved): this workspace switches between branches
    # and a stale Makefile.dep/.d from another branch can reference generated
    # headers that no longer exist (observed: cluster_state.h), breaking the
    # flag-change rebuild. A clean tree also guarantees RDMA is really enabled.
    log "cleaning build tree: make distclean"
    make distclean >>"$RESULTS_DIR/raw/build.log" 2>&1 \
        || warn "make distclean returned non-zero (continuing; see raw/build.log)"

    log "building Valkey: make -j\$(nproc) BUILD_RDMA=yes USE_FAST_FLOAT=yes"
    if ! make -j"$(nproc)" BUILD_RDMA=yes USE_FAST_FLOAT=yes \
            >>"$RESULTS_DIR/raw/build.log" 2>&1; then
        tail -n 40 "$RESULTS_DIR/raw/build.log" || true
        die "build failed - see $RESULTS_DIR/raw/build.log"
    fi
    ./src/valkey-server --version >>"$RESULTS_DIR/raw/build.log" 2>&1 || die "./src/valkey-server --version failed"

    local cli_help bench_help
    cli_help="$(./src/valkey-cli --help 2>&1 || true)"
    bench_help="$(./src/valkey-benchmark --help 2>&1 || true)"
    grep -q -- '--rdma' <<<"$cli_help" \
        || die "valkey-cli has no --rdma support; refusing to fall back to TCP. The build did not pick up BUILD_RDMA=yes (see $RESULTS_DIR/raw/build.log)"
    grep -q -- '--rdma' <<<"$bench_help" \
        || die "valkey-benchmark has no --rdma support; refusing to fall back to TCP (same diagnosis as above)"
    log "build OK; valkey-cli and valkey-benchmark both expose --rdma"
}

# ----------------------------- RXE setup -------------------------------------

setup_rxe() {
    log "loading kernel modules: dummy, rdma_rxe"
    sudo modprobe dummy
    sudo modprobe rdma_rxe

    if ! ip link show dev "$RDMA_NETDEV" >/dev/null 2>&1; then
        log "creating dummy netdev $RDMA_NETDEV"
        sudo ip link add "$RDMA_NETDEV" type dummy
        CREATED_NETDEV=1
    else
        log "netdev $RDMA_NETDEV already exists, reusing it"
    fi

    # Refuse to run if the target IP already lives on another device.
    local dev addr iponly offender=""
    while read -r dev addr _; do
        iponly="${addr%%/*}"
        if [[ "$iponly" == "$RDMA_IP" && "$dev" != "$RDMA_NETDEV" ]]; then
            offender="$dev"
        fi
    done < <(ip -4 -o addr show)
    [[ -z "$offender" ]] || die "$RDMA_IP is already configured on '$offender', refusing to touch it"

    if ! ip -4 -o addr show dev "$RDMA_NETDEV" | awk -v ip="$RDMA_IP" '{split($4,a,"/"); if (a[1]==ip) found=1} END {exit !found}'; then
        log "adding $RDMA_IP/$RDMA_PREFIX to $RDMA_NETDEV"
        sudo ip addr add "$RDMA_IP/$RDMA_PREFIX" dev "$RDMA_NETDEV"
    else
        log "$RDMA_IP already present on $RDMA_NETDEV, reusing it"
    fi
    sudo ip link set "$RDMA_NETDEV" up

    if ! rxe_link_exists; then
        log "creating RXE link $RDMA_DEVICE on $RDMA_NETDEV"
        sudo rdma link add "$RDMA_DEVICE" type rxe netdev "$RDMA_NETDEV"
        CREATED_RXE=1
        local i
        for i in $(seq 1 50); do
            rxe_link_exists && break
            sleep 0.1
        done
    else
        log "RDMA link $RDMA_DEVICE already exists, reusing it"
    fi
    rxe_link_exists || die "RDMA link $RDMA_DEVICE did not come up"
    log "RXE ready: $RDMA_DEVICE on $RDMA_NETDEV ($RDMA_IP/$RDMA_PREFIX)"
}

# ----------------------------- environment capture ---------------------------

capture_environment() {
    local f="$RESULTS_DIR/environment.txt"
    {
        echo "=== captured at: $(date -Is) ==="
        echo "=== mode: $MODE ==="
        echo; echo "=== uname -a ===";                 uname -a
        echo; echo "=== git rev-parse HEAD ===";       git rev-parse HEAD
        echo; echo "=== git describe ===";             git describe --always --dirty 2>/dev/null || true
        echo; echo "=== git status --short ===";       git status --short
        echo; echo "=== lscpu ===";                    lscpu
        echo; echo "=== free -h ===";                  free -h 2>/dev/null || true
        echo; echo "=== ulimit -l ===";                ulimit -l
        echo; echo "=== id ===";                       id
        echo; echo "=== ip -details addr show $RDMA_NETDEV ==="; ip -details addr show "$RDMA_NETDEV" || true
        echo; echo "=== rdma link show ===";           rdma link show || true
        echo; echo "=== rdma res show ===";            rdma res show || true
        echo; echo "=== ibv_devices ===";              ibv_devices || true
        echo; echo "=== ibv_devinfo ===";              ibv_devinfo || true
        echo; echo "=== relevant kernel modules ===";  lsmod | grep -E '^(rdma_rxe|dummy|ib_uverbs|rdma_cm|ib_core)[[:space:]]' || true
    } > "$f" 2>&1
    log "environment snapshot: $f"
}

# ----------------------------- server management -----------------------------

wait_server_rdma() {
    # Up to 10s, verified over a real RDMA connection.
    local deadline=$((SECONDS + 10)) out
    while (( SECONDS < deadline )); do
        if out="$(timeout 5 ./src/valkey-cli --rdma -h "$RDMA_IP" -p "$RDMA_PORT" PING 2>/dev/null)" \
           && [[ "$out" == "PONG" ]]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

verify_rx_config() {
    local expect="$1" eff
    eff="$(timeout 5 ./src/valkey-cli --rdma -h "$RDMA_IP" -p "$RDMA_PORT" --raw \
           CONFIG GET rdma-rx-size 2>/dev/null | tail -n1)" || return 1
    [[ "$eff" == "$expect" ]]
}

start_server() {
    local rx="$1"
    SERVER_INSTANCE=$((SERVER_INSTANCE + 1))
    # per-instance log names: crash reports from earlier instances must not
    # be overwritten by a restarted server using the same rx size
    SERVER_LOG="$RESULTS_DIR/server-logs/server-rx-${rx}-inst${SERVER_INSTANCE}.log"
    stop_server   # never leave a stray previous instance
    log "starting valkey-server: rdma-rx-size=$rx, rdma $RDMA_IP:$RDMA_PORT, tcp disabled (--port 0)"
    ./src/valkey-server "$REPO_ROOT/valkey.conf" \
        --port 0 \
        --protected-mode no \
        --save "" \
        --appendonly no \
        --daemonize no \
        --rdma-bind "$RDMA_IP" \
        --rdma-port "$RDMA_PORT" \
        --rdma-rx-size "$rx" \
        >"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!

    if ! wait_server_rdma; then
        log "server did not become RDMA-reachable within 10s; last log lines:"
        tail -n 20 "$SERVER_LOG" 2>/dev/null || true
        stop_server
        return 1
    fi
    if ! verify_rx_config "$rx"; then
        log "effective rdma-rx-size does not match requested $rx"
        stop_server
        return 1
    fi
    # Negative proof that we are NOT on TCP: server runs with --port 0, so a
    # plain TCP connection attempt must fail.
    if timeout 5 ./src/valkey-cli -h "$RDMA_IP" -p "$RDMA_PORT" --raw PING >/dev/null 2>&1; then
        log "plain TCP connect unexpectedly SUCCEEDED on $RDMA_IP:$RDMA_PORT"
        stop_server
        return 1
    fi
    rdma res show >"$RESULTS_DIR/raw/rdma-res-rx-${rx}-server-up.txt" 2>&1 || true
    log "server up (PID $SERVER_PID), RDMA PING ok, rdma-rx-size=$rx verified, TCP correctly refused"
    return 0
}

# ----------------------------- result recording ------------------------------

csv_field() {
    local s="$1"
    s="${s//$'\n'/ }"
    if [[ "$s" == *','* || "$s" == *'"'* ]]; then
        printf '"%s"' "${s//\"/\"\"}"
    else
        printf '%s' "$s"
    fi
}

# Error signatures are taken from src/rdma.c serverLog() calls.
SERVER_ERR_RE='ASSERTION FAILED|assert|FATAL error|CQ handle error|CQ event error|notify CQ error|poll recv CQ error|post recv failed|post send failed|recv corrupted|unknown cmd|reg mr .* failed|ibv .* failed|create qp failed|WARNING: RDMA'

scan_server_errors() {
    local m
    m="$(grep -m1 -E "$SERVER_ERR_RE" "$1" 2>/dev/null || true)"
    printf '%s' "${m:-none}"
}

get_server_window_reannounce() {
    local v
    v="$(timeout 10 ./src/valkey-cli --rdma -h "$RDMA_IP" -p "$RDMA_PORT" INFO rdma 2>/dev/null \
        | awk -F: '/^window_reannounce_count:/ { gsub(/\r/, "", $2); print $2; exit }')"
    printf '%s' "${v:-0}"
}

parse_client_rdma_stats() {
    # Reads benchmark stderr (raw_err) for:
    #   RDMA_STATS window_reannounce_count=N tx_wait_for_rx_ns=N
    local err_file="$1"
    local line
    line="$(grep '^RDMA_STATS ' "$err_file" 2>/dev/null | tail -n1 || true)"
    if [[ -z "$line" ]]; then
        printf '%s\n' "" ""
        return 0
    fi
    printf '%s\n' \
        "$(sed -n 's/.*window_reannounce_count=\([0-9]*\).*/\1/p' <<<"$line")" \
        "$(sed -n 's/.*tx_wait_for_rx_ns=\([0-9]*\).*/\1/p' <<<"$line")"
}

append_row() {
    # git_commit,timestamp,mode,rx_size,value_size,clients,pipeline,threads,
    # repetition,duration,rps,payload_gbps,avg_latency_ms,p50_latency_ms,
    # p95_latency_ms,p99_latency_ms,exit_status,server_error,bench_error,
    # verify_strlen,server_window_reannounce_delta,client_window_reannounce_count,
    # client_tx_wait_for_rx_ns,raw_file
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_field "$1")"  "$(csv_field "$2")"  "$(csv_field "$3")"  \
        "$(csv_field "$4")"  "$(csv_field "$5")"  "$(csv_field "$6")"  \
        "$(csv_field "$7")"  "$(csv_field "$8")"  "$(csv_field "$9")"  \
        "$(csv_field "${10}")" "$(csv_field "${11}")" "$(csv_field "${12}")" \
        "$(csv_field "${13}")" "$(csv_field "${14}")" "$(csv_field "${15}")" \
        "$(csv_field "${16}")" "$(csv_field "${17}")" "$(csv_field "${18}")" \
        "$(csv_field "${19}")" "$(csv_field "${20}")" "$(csv_field "${21}")" \
        "$(csv_field "${22}")" "$(csv_field "${23}")" "$(csv_field "${24}")" \
        >> "$RESULTS_DIR/summary.csv"
}

# ----------------------------- benchmark -------------------------------------

run_benchmark() {
    local rx="$1" value="$2" clients="$3" pipeline="$4" rep="$5"
    RUN_COUNT=$((RUN_COUNT + 1))
    local tag="${MODE}-rx${rx}-d${value}-c${clients}-P${pipeline}-r${rep}"
    local raw_out="$RESULTS_DIR/raw/${tag}.csv"
    local raw_err="$RESULTS_DIR/raw/${tag}.err"
    log "run ${RUN_COUNT}/${TOTAL_RUNS}: rx=$rx value=$value clients=$clients pipeline=$pipeline rep=$rep"

    # Pre-run invariants: server alive, effective config as expected.
    local row_status=0
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        log "  server is dead before the run"
        append_row "$GIT_COMMIT" "$(date -Is)" "$MODE" "$rx" "$value" "$clients" "$pipeline" 1 "$rep" \
            "$DURATION" "" "" "" "" "" "" "SERVER_DEAD" "server_dead" "" "cli_fail" "" "" "" "$tag"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 2
    fi
    if ! verify_rx_config "$rx"; then
        log "  effective rdma-rx-size drifted from $rx"
        append_row "$GIT_COMMIT" "$(date -Is)" "$MODE" "$rx" "$value" "$clients" "$pipeline" 1 "$rep" \
            "$DURATION" "" "" "" "" "" "" "CONFIG_MISMATCH" "config_mismatch" "" "cli_fail" "" "" "" "$tag"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi

    local srv_reannounce_before srv_reannounce_after srv_reannounce_delta
    srv_reannounce_before="$(get_server_window_reannounce)"

    local bench_rc=0
    timeout -k 10 "$BENCH_TIMEOUT" ./src/valkey-benchmark \
        --rdma \
        -h "$RDMA_IP" \
        -p "$RDMA_PORT" \
        -c "$clients" \
        -P "$pipeline" \
        -d "$value" \
        --duration "$DURATION" \
        --warmup "$WARMUP" \
        --threads 1 \
        --precision 3 \
        --csv \
        -- SET "$BENCH_KEY" __data__ \
        >"$raw_out" 2>"$raw_err" || bench_rc=$?

    srv_reannounce_after="$(get_server_window_reannounce)"
    srv_reannounce_delta=$((srv_reannounce_after - srv_reannounce_before))

    local client_reannounce client_tx_wait
    mapfile -t _rdma_stats < <(parse_client_rdma_stats "$raw_err")
    client_reannounce="${_rdma_stats[0]:-}"
    client_tx_wait="${_rdma_stats[1]:-}"

    # Parse CSV. Verified format (src/valkey-benchmark.c):
    #   "test","rps","avg_latency_ms","min_latency_ms","p50_latency_ms",
    #   "p95_latency_ms","p99_latency_ms","max_latency_ms"
    local rps="" avg="" p50="" p95="" p99="" gbps="" line clean
    if (( bench_rc == 0 )); then
        line="$(grep '^"' "$raw_out" 2>/dev/null | tail -n1 || true)"
        if [[ -n "$line" ]]; then
            clean="${line//\"/}"
            rps="$(cut -d, -f2 <<<"$clean")"
            avg="$(cut -d, -f3 <<<"$clean")"
            p50="$(cut -d, -f5 <<<"$clean")"
            p95="$(cut -d, -f6 <<<"$clean")"
            p99="$(cut -d, -f7 <<<"$clean")"
        fi
    fi
    if [[ -n "$rps" ]]; then
        # payload-only estimate: rps * value_size * 8 / 1e9 (no RESP/RDMA overhead)
        gbps="$(awk -v r="$rps" -v v="$value" 'BEGIN { printf "%.4f", r * v * 8 / 1e9 }')"
    fi

    # Verify over RDMA that the SET really stored value_size bytes.
    local vlen verify="cli_fail"
    vlen="$(timeout 15 ./src/valkey-cli --rdma -h "$RDMA_IP" -p "$RDMA_PORT" --raw \
            STRLEN "$BENCH_KEY" 2>/dev/null || true)"
    if [[ "$vlen" == "$value" ]]; then
        verify="ok"
    elif [[ -n "$vlen" ]]; then
        verify="mismatch:${vlen}"
    fi

    local serr berr
    serr="$(scan_server_errors "$SERVER_LOG")"
    serr="${serr:0:200}"
    berr="$(grep -m1 -iE 'error|fail|refused|reset|closed|timeout' "$raw_err" 2>/dev/null || true)"
    berr="$(tr -d '\n' <<<"${berr:0:120}")"

    if (( bench_rc != 0 )); then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "  benchmark FAILED rc=$bench_rc (see ${tag}.err)"
    elif [[ "$verify" != "ok" ]]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "  verify FAILED: strlen $verify (expected $value)"
    elif [[ "$serr" != "none" ]]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "  server log shows error: $serr"
    else
        log "  ok: rps=$rps payload=${gbps}Gbps p50=${p50}ms p99=${p99}ms strlen=ok srv_reannounce_delta=${srv_reannounce_delta} client_tx_wait_ns=${client_tx_wait:-n/a}"
    fi

    append_row "$GIT_COMMIT" "$(date -Is)" "$MODE" "$rx" "$value" "$clients" "$pipeline" 1 "$rep" \
        "$DURATION" "$rps" "$gbps" "$avg" "$p50" "$p95" "$p99" \
        "$bench_rc" "$serr" "$berr" "$verify" "$srv_reannounce_delta" "$client_reannounce" "$client_tx_wait" "$tag"
    return 0
}

# ----------------------------- suite -----------------------------------------

values_for_rx() {
    local rx="$1"
    if [[ "$MODE" == "smoke" ]]; then
        VALUES=($((rx - 1)) "$rx" $((rx + 1)))
    else
        VALUES=("${FULL_VALUE_SIZES[@]}")
    fi
}

run_suite() {
    local rx value clients pipeline rep restarted
    for rx in "${RX_SIZES[@]}"; do
        if ! start_server "$rx"; then
            FAIL_COUNT=$((FAIL_COUNT + 1))
            log "server failed to start with rdma-rx-size=$rx, skipping its runs (see server-logs/)"
            continue
        fi
        values_for_rx "$rx"
        local restarts=0
        for value in "${VALUES[@]}"; do
            for clients in "${CLIENTS_LIST[@]}"; do
                for pipeline in "${PIPELINE_LIST[@]}"; do
                    for rep in $(seq 1 "$REPS"); do
                        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
                            # Server died (teardown UAF or similar). Measurements already
                            # recorded are valid; restart and keep going while budget lasts.
                            if (( restarts < MAX_SERVER_RESTARTS_PER_RX )) && start_server "$rx"; then
                                restarts=$((restarts + 1))
                                log "server died mid-suite for rx=$rx, restarted ($restarts/$MAX_SERVER_RESTARTS_PER_RX)"
                            else
                                run_benchmark "$rx" "$value" "$clients" "$pipeline" "$rep" || true
                                log "abandoning remaining runs for rx=$rx (restart budget exhausted or restart failed)"
                                break 4
                            fi
                        fi
                        run_benchmark "$rx" "$value" "$clients" "$pipeline" "$rep" || true
                    done
                done
            done
        done
        log "stopping server for rx=$rx (restarts used: $restarts)"
        stop_server
    done
}

# ----------------------------- main ------------------------------------------

main() {
    parse_args "$@"
    cd "$REPO_ROOT"
    check_deps
    do_privilege_setup

    if [[ "$MODE" == "smoke" ]]; then
        RX_SIZES=("${SMOKE_RX_SIZES[@]}"); CLIENTS_LIST=(1); PIPELINE_LIST=(1)
        DURATION=$SMOKE_DURATION; WARMUP=$SMOKE_WARMUP; REPS=$SMOKE_REPS
        BENCH_TIMEOUT=$SMOKE_BENCH_TIMEOUT
    else
        RX_SIZES=("${FULL_RX_SIZES[@]}"); CLIENTS_LIST=("${FULL_CLIENTS[@]}")
        PIPELINE_LIST=("${FULL_PIPELINE[@]}")
        DURATION=$FULL_DURATION; WARMUP=$FULL_WARMUP; REPS=$FULL_REPS
        BENCH_TIMEOUT=$FULL_BENCH_TIMEOUT
    fi

    local ts rx n
    ts="$(date +%Y%m%d-%H%M%S)"
    RESULTS_DIR="$REPO_ROOT/rdma-rx-results/$ts"
    mkdir -p "$RESULTS_DIR/raw" "$RESULTS_DIR/server-logs"
    GIT_COMMIT="$(git rev-parse HEAD)"

    TOTAL_RUNS=0
    for rx in "${RX_SIZES[@]}"; do
        values_for_rx "$rx"
        n=$(( ${#VALUES[@]} * ${#CLIENTS_LIST[@]} * ${#PIPELINE_LIST[@]} * REPS ))
        TOTAL_RUNS=$((TOTAL_RUNS + n))
    done

    cat > "$RESULTS_DIR/README.txt" <<EOF
rdma-rx-size benchmark ($MODE mode)
===================================
git commit : $GIT_COMMIT
started at : $(date -Is)
RDMA       : $RDMA_DEVICE on $RDMA_NETDEV ($RDMA_IP/$RDMA_PREFIX), port $RDMA_PORT
layout     : environment.txt, summary.csv, raw/ (per-run benchmark CSV+stderr,
             build.log, rdma-res snapshots), server-logs/ (one log per server
             instance; multiple instances per rx mean teardown crashes occurred
             and the server was restarted - measurements are unaffected)

payload_gbps = rps * value_size * 8 / 1e9
  -> PAYLOAD-ONLY estimate. It excludes RESP protocol framing, RDMA protocol
     headers and memory-registration costs, so it is NOT wire throughput.

The RDMA transport here is software RXE (rdma_rxe) on a dummy netdev.
Results validate protocol mechanics, harness behaviour and relative trends
only. They say NOTHING about physical (100G) RDMA NIC performance.
EOF

    log "mode=$MODE, $TOTAL_RUNS benchmark runs planned"
    log "results directory: $RESULTS_DIR"

    build_valkey
    setup_rxe
    capture_environment

    printf '%s\n' \
        'git_commit,timestamp,mode,rx_size,value_size,clients,pipeline,threads,repetition,duration,rps,payload_gbps,avg_latency_ms,p50_latency_ms,p95_latency_ms,p99_latency_ms,exit_status,server_error,bench_error,verify_strlen,server_window_reannounce_delta,client_window_reannounce_count,client_tx_wait_for_rx_ns,raw_file' \
        > "$RESULTS_DIR/summary.csv"

    run_suite

    log "============================================================"
    log "results:    $RESULTS_DIR"
    log "runs:       $RUN_COUNT/$TOTAL_RUNS completed, failures: $FAIL_COUNT"
    awk -F, 'NR>1 { printf "%-8s rx=%-9s value=%-8s c=%-2s P=%-3s rps=%-10s gbps=%-9s p50=%-8s p99=%-8s exit=%s strlen=%s\n", $3, $4, $5, $6, $7, $11, $12, $14, $16, $17, $20 }' \
        "$RESULTS_DIR/summary.csv"
    if (( FAIL_COUNT == 0 )); then
        log "ALL RUNS PASSED"
        exit 0
    fi
    log "$FAIL_COUNT RUN(S) FAILED - inspect summary.csv, raw/*.err and server-logs/"
    exit 1
}

GIT_COMMIT="pending"
main "$@"
