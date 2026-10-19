#!/bin/bash
# run-ibs-repro.sh -- one-terminal reproducer for "ibs_op silently stops"
#
# What it does:
#
#   1. disables perf's dynamic throttle for this run (always, no option):
#      perf_cpu_time_max_percent 25 -> perf_event_max_sample_rate 100000
#      -> perf_cpu_time_max_percent 0.  The 25 in the middle is forced by
#      the kernel (it refuses to change the rate while percent is 0/100),
#      see README.md.  Both sysctls are restored on exit.
#   2. starts 'perf record -a -e ibs_op//' on top of 'stress-ng --cpu 0'.
#   3. watches the per-CPU PMI counters in /proc/interrupts once a second.
#   4. the moment a CPU goes silent, dumps MSR_AMD64_IBSOPCTL (0xc0011033)
#      on that CPU (3 reads, 0.3 s apart) __while perf is still running__,
#      plus one still-live CPU as a control.
#   5. stops perf early once every CPU has been silent for --settle seconds
#      (so a normal run takes ~4 minutes instead of 30).
#   6. writes perf.data / result.txt / per-CPU summary into a NEW directory.
#
# usage: sudo ./run-ibs-repro.sh [options]
#   --period N       ibs_op sample period                 (default 100000)
#   --duration T     max run time, e.g. 30m or 600s       (default 30m)
#   --settle S       after all CPUs are silent, keep running S more seconds
#                    to prove they do not come back    (default 120)
#   --dead-secs N    consecutive 1s with 0 PMIs => silent (default 3)
#   --outdir DIR     output directory (must not exist or be empty)
#   -h, --help

set -uo pipefail

# --- functions ---
# Definitions only; the real execution flow starts at "# --- options ---".

to_seconds() {
    local v=$1 n=${1%[smhSMH]} u=${1: -1}
    case "$u" in
        s|S) echo "$n" ;;
        m|M) echo $(( n * 60 )) ;;
        h|H) echo $(( n * 3600 )) ;;
        [0-9]) echo "$v" ;;
        *) return 1 ;;
    esac
}

usage() { sed -n '2,/^set -uo pipefail/{ /^set -uo pipefail/d; s/^# \{0,1\}//; p; }' "$0"; }

die() { echo "error: $*" >&2; exit 1; }

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/monitor.log"; }

disable_throttle() {
    # Order matters and is forced by the kernel: perf_event_max_sample_rate
    # refuses any write while perf_cpu_time_max_percent is 0 or 100
    # (kernel/events/core.c, perf_event_max_sample_rate_handler), so pass
    # the boot default 25 first, set the rate, then freeze with percent=0.
    # Flag first: an interrupt mid-sequence must still restore the saved
    # values (restore is idempotent, so this is harmless when nothing ran).
    SYSCTL_CHANGED=1
    log " disabling throttle: max_sample_rate=$MAXRATE_OLD percent=$PCT_OLD -> rate=100000, percent=0"
    echo 25    > /proc/sys/kernel/perf_cpu_time_max_percent
    echo 100000 > /proc/sys/kernel/perf_event_max_sample_rate
    echo 0     > /proc/sys/kernel/perf_cpu_time_max_percent
}

restore_sysctls() {
    [ "$SYSCTL_CHANGED" -eq 1 ] || return 0
    echo 25 > /proc/sys/kernel/perf_cpu_time_max_percent
    echo "$MAXRATE_OLD" > /proc/sys/kernel/perf_event_max_sample_rate
    echo "$PCT_OLD"     > /proc/sys/kernel/perf_cpu_time_max_percent
    SYSCTL_CHANGED=0
    log " sysctls restored: max_sample_rate=$MAXRATE_OLD percent=$PCT_OLD"
}

read_pmi() {
    local key
    for key in PMI NMI; do
        local out
        out=$(awk -v n="$CPUS" -v k="$key" '
            $1 == k":" { for (i = 2; i < 2 + n && i <= NF; i++)
                             if ($i ~ /^[0-9]+$/) printf "%s%s", $i, (++c == n ? "\n" : " ") }
        ' /proc/interrupts)
        if [ -n "$out" ]; then echo "$out"; return 0; fi
    done
    return 1
}

dump_msr() {   # dump_msr <cpu> <tag>
    local cpu=$1 tag=$2 raw v en val cur i f
    f="$OUT/msr-CPU$cpu.txt"
    {
        printf '### CPU%s (%s)  uptime=%s  %s\n' "$cpu" "$tag" "$(cut -d' ' -f1 /proc/uptime)" "$(date -Is)"
        for i in 1 2 3; do
            if ! raw=$(rdmsr -p "$cpu" 0xc0011033 2>&1); then
                printf '  read %d: rdmsr failed: %s\n' "$i" "$raw"
                sleep 0.3; continue
            fi
            v=$(( 0x$raw ))
            en=$(( (v >> 17) & 1 ))
            val=$(( (v >> 18) & 1 ))
            cur=$(( (v >> 32) & 0x7ffffff ))
            printf '  read %d: raw=0x%s  IBS_OP_ENABLE=%d IBS_OP_VAL=%d IBS_OP_CUR_CNT=%d\n' "$i" "$raw" "$en" "$val" "$cur"
            sleep 0.3
        done
        printf '  legend: IBS_OP_ENABLE=1 IBS_OP_VAL=1 + frozen IBS_OP_CUR_CNT => HW latched, no NMI\n'
        printf '          IBS_OP_ENABLE=1 IBS_OP_VAL=0 + moving IBS_OP_CUR_CNT => HW counting, no NMI\n'
        printf '          IBS_OP_ENABLE=0                                      => kernel stopped the event\n'
    } | tee -a "$OUT/msr.log" | tee -a "$f"
}

stop_perf() {
    [ "$STOPPED" -eq 1 ] && return 0
    STOPPED=1
    if [ -n "$PERF_PID" ] && kill -0 "$PERF_PID" 2>/dev/null; then
        log " stopping perf record (SIGINT) ..."
        kill -INT "$PERF_PID" 2>/dev/null
        for _ in $(seq 1 60); do kill -0 "$PERF_PID" 2>/dev/null || break; sleep 1; done
        kill -0 "$PERF_PID" 2>/dev/null && kill -TERM "$PERF_PID" 2>/dev/null
        wait "$PERF_PID" 2>/dev/null || true
    fi
    if [ -n "$STRESS_PID" ] && kill -0 "$STRESS_PID" 2>/dev/null; then
        kill -TERM "$STRESS_PID" 2>/dev/null
    fi
}

cleanup() {
    stop_perf
    restore_sysctls
}

analyze() {
    [ -s "$OUT/result.txt" ] || return 0
    awk -v cpus="$CPUS" -v start_up="$START_UP" '
    {
        gsub(/[][]/,"",$1); c=$1+0; t=$2+0;
        n[c]++
        if (!(c in first)) first[c]=t
        last[c]=t
        if (p[c] > 0) {
            d=t-p[c]
            if (d > mg[c]) mg[c]=d
        }
        if (c==0) {
            n0++
            if (p0 > 0 && t-p0 > 0.00008) {
                if (lg==0) lg=1
                h[n0-lg]++
                ph=(t*1000)-int(t*1000); pd[int(ph*10)]++
                gaps++
                lg=n0
            }
            p0=t
        }
        p[c]=t
    }
    END {
        printf "%-4s %10s %12s %12s %9s %9s %10s\n", "CPU","samples","first(s)","last(s)","active_s","rate/s","maxgap_us"
        for (c=0;c<cpus;c++) {
            if (!(c in n)) continue
            span=last[c]-first[c]
            printf "%-4d %10d %12.3f %12.3f %9.1f %9.0f %10.0f\n", c, n[c], first[c], last[c], span, (span>0?n[c]/span:0), mg[c]*1e6
        }
        best=0; bk=0
        for (k in h) if (h[k] > best) { best=h[k]; bk=k }
        bd=-1; bv=0
        for (k in pd) if (pd[k] > bv) { bv=pd[k]; bd=k }
        printf "\nCPU0 gap analysis (throttle signature)\n"
        printf "  gaps >80us                : %d\n", gaps
        printf "  samples between gaps      : mode=%d (%d times)\n", bk, best
        printf "  gap-end fractional-ms     : mode=%d.%d-%d.%d ms (%d/%d gaps)\n", bd/10, bd%10, bd/10, (bd%10)+1, bv, gaps
        if (bk >= 20 && bk <= 40 && gaps > 0 && bv/gaps > 0.5)
            printf "  => stream is being throttled every tick (perf throttle); this alone does not prove the cause\n"
        else
            printf "  => no clear per-ms stop/start pattern (free-running stream)\n"
    }' "$OUT/result.txt"
}

# --- options ---
ORIG_ARGS=("$@")
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")

PERIOD=100000
DURATION=30m
DURATION_S=1800
SETTLE=120
DEAD_SECS=3
OUTDIR=""
CPUS=$(nproc)
HELP=0

# kernel HZ (getconf CLK_TCK is the user-space value, not CONFIG_HZ)
HZ=$(zcat /proc/config.gz 2>/dev/null | sed -n 's/^CONFIG_HZ=//p' | head -1)
[ -n "${HZ:-}" ] || HZ=$(getconf CLK_TCK)

while [ $# -gt 0 ]; do
    case "$1" in
        --period)      PERIOD="$2"; shift 2 ;;
        --duration)    DURATION="$2"; DURATION_S=$(to_seconds "$2") || { echo "bad --duration: $2" >&2; exit 1; }; shift 2 ;;
        --settle)      SETTLE="$2"; shift 2 ;;
        --dead-secs)   DEAD_SECS="$2"; shift 2 ;;
        --outdir)      OUTDIR="$2"; shift 2 ;;
        -h|--help)     HELP=1; shift ;;
        *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
done
[ "$HELP" -eq 1 ] && { usage; exit 0; }

# --- root ---
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$SELF" "${ORIG_ARGS[@]}"
fi

# --- checks ---
command -v perf >/dev/null || die "perf not found"
[ -e /sys/bus/event_source/devices/ibs_op ] || die "no ibs_op PMU on this machine"
command -v stress-ng >/dev/null || die "stress-ng not found"
if pgrep -f 'perf record .*ibs_op' >/dev/null 2>&1; then
    die "another 'perf record ... ibs_op' is already running; only one IBS event per CPU is allowed. Stop it first."
fi

# MSR reads are mandatory: the whole point of the run is the IBS_OP_CTL
# state on a silent CPU.  Refuse to run without them.
command -v rdmsr >/dev/null || die "rdmsr not found (msr-tools); MSR reads are required"
if [ ! -e /dev/cpu/0/msr ]; then
    modprobe msr 2>/dev/null || true
    [ -e /dev/cpu/0/msr ] || die "/dev/cpu/0/msr missing; cannot read IBS_OP_CTL"
fi

# --- out dir ---
if [ -z "$OUTDIR" ]; then
    OUTDIR="$(pwd)/ibs-repro-$(date +%Y%m%d-%H%M%S)"
fi
if [ -e "$OUTDIR" ] && [ -n "$(ls -A "$OUTDIR" 2>/dev/null)" ]; then
    die "$OUTDIR exists and is not empty; refusing to touch it"
fi
mkdir -p "$OUTDIR" || die "cannot create $OUTDIR"
OUT="$(cd "$OUTDIR" && pwd)"

# --- sysctls ---
MAXRATE_OLD=$(cat /proc/sys/kernel/perf_event_max_sample_rate 2>/dev/null || echo 0)
PCT_OLD=$(cat /proc/sys/kernel/perf_cpu_time_max_percent 2>/dev/null || echo 0)
SYSCTL_CHANGED=0

# Everything cleanup() touches must be initialized BEFORE the traps go in,
# and the traps must go in BEFORE the first kernel-state change below:
# from disable_throttle on, any signal, die() or set -u abort has to end
# up in cleanup -> restore_sysctls, or the two sysctls stay pinned at
# rate=100000/percent=0 until someone fixes them by hand.
PERF_PID=""
STRESS_PID=""
STOPPED=0
trap 'cleanup; exit 130' INT TERM
trap 'cleanup' EXIT

# throttle must be off before perf starts; do it now so meta.txt records
# the values that were actually in effect during the run
disable_throttle

# --- meta/start ---
START_EPOCH=$(date +%s)
START_UP=$(cut -d' ' -f1 /proc/uptime)
cp "$0" "$OUT/run.sh" 2>/dev/null || true

{
    echo "date            : $(date -Is)"
    echo "kernel          : $(uname -r)"
    echo "cmdline         : $(tr '\0' ' ' </proc/cmdline)"
    echo "perf            : $(perf --version 2>&1 | head -1)"
    echo "stress-ng       : $(stress-ng --version 2>&1 | head -1)"
    echo "nproc           : $CPUS"
    echo "hz              : $HZ"
    echo "period          : $PERIOD"
    echo "duration        : $DURATION ($DURATION_S s)"
    echo "settle          : ${SETTLE}s"
    echo "dead_secs       : $DEAD_SECS"
    echo "throttle        : disabled for this run"
    echo "perf_event_max_sample_rate(now)   : $(cat /proc/sys/kernel/perf_event_max_sample_rate 2>/dev/null)"
    echo "perf_cpu_time_max_percent(now)    : $(cat /proc/sys/kernel/perf_cpu_time_max_percent 2>/dev/null)"
    echo "perf_event_max_sample_rate(orig)  : $MAXRATE_OLD"
    echo "perf_cpu_time_max_percent(orig)   : $PCT_OLD"
    echo "nmi_watchdog    : $(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null)"
    echo "perf_event_paranoid : $(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)"
    grep -m1 'model name' /proc/cpuinfo
    grep -m1 'cpu family' /proc/cpuinfo
    grep -m1 'model[[:space:]]*:' /proc/cpuinfo | tail -1
    grep -m1 microcode /proc/cpuinfo
    lscpu 2>/dev/null | grep -E 'Model name|CPU\(s\)|Thread|Core|Socket|Microcode|Vendor'
} > "$OUT/meta.txt" 2>&1
cp /proc/interrupts "$OUT/interrupts-start.txt" 2>/dev/null || true
have_journal=0
command -v journalctl >/dev/null && have_journal=1
[ "$have_journal" -eq 1 ] && journalctl -k --no-pager > "$OUT/dmesg-boot.txt" 2>/dev/null || true

# --- run ---
log " run dir : $OUT"
log " kernel  : $(uname -r)"
log " period  : $PERIOD   duration: $DURATION   settle: ${SETTLE}s"
log " throttle: disabled (rate=100000 percent=0; orig rate=$MAXRATE_OLD percent=$PCT_OLD)"

perf record -a -e "ibs_op//" -c "$PERIOD" -o "$OUT/perf.data" \
    stress-ng --cpu 0 --timeout="$DURATION" > "$OUT/stress-ng.out" 2>&1 &
PERF_PID=$!
sleep 2
STRESS_PID=$(pgrep -P "$PERF_PID" 2>/dev/null | head -1)
log " perf pid=$PERF_PID stress-ng pid=${STRESS_PID:-?}"
sleep 3
if ! kill -0 "$PERF_PID" 2>/dev/null; then
    echo "perf record exited immediately; output was:" >&2
    cat "$OUT/stress-ng.out" >&2 2>/dev/null || true
    die "perf record failed to start"
fi

declare -a prev dead silent rate
mapfile -t prev < <(read_pmi | tr ' ' '\n')
[ "${#prev[@]}" -eq "$CPUS" ] || die "got ${#prev[@]} PMI/NMI counters, expected $CPUS"
for i in $(seq 0 $((CPUS-1))); do dead[$i]=0; silent[$i]=0; rate[$i]=0; done

ALL_DEAD_SINCE=0
t=0
while kill -0 "$PERF_PID" 2>/dev/null; do
    sleep 1
    t=$((t+1))
    now_up=$(cut -d' ' -f1 /proc/uptime)
    mapfile -t now < <(read_pmi | tr ' ' '\n')
    active=0; ndead=0
    for i in $(seq 0 $((CPUS-1))); do
        d=$(( ${now[$i]:-0} - ${prev[$i]:-0} ))
        rate[$i]=$d
        if [ "$d" -le 0 ]; then
            silent[$i]=$(( ${silent[$i]:-0} + 1 ))
        else
            silent[$i]=0
            if [ "${dead[$i]:-0}" -eq 1 ]; then
                dead[$i]=0
                log " CPU$i RECOVERED (PMI rate $d/s)"
            fi
        fi
        if [ "${dead[$i]:-0}" -eq 1 ]; then
            ndead=$((ndead+1))
            continue
        fi
        if [ "$t" -gt 5 ] && [ "${silent[$i]:-0}" -ge "$DEAD_SECS" ]; then
            dead[$i]=1
            ndead=$((ndead+1))
            printf '%s cpu=%d uptime=%s delta_from_start=%.1fs\n' \
                "$(date -Is)" "$i" "$now_up" \
                "$(awk -v a="$now_up" -v b="$START_UP" 'BEGIN{print a-b}')" >> "$OUT/deaths.txt"
            cp /proc/interrupts "$OUT/interrupts-at-death-CPU$i.txt" 2>/dev/null || true
            log " CPU$i went SILENT at uptime $now_up (no PMI for ${DEAD_SECS}s)"
            dump_msr "$i" "silent"
            ctl=-1
            for k in $(seq 0 $((CPUS-1))); do
                if [ "$k" -ne "$i" ] && [ "${dead[$k]:-0}" -eq 0 ]; then ctl=$k; break; fi
            done
            [ "$ctl" -ge 0 ] && dump_msr "$ctl" "control(live)"
            continue
        fi
        active=$((active+1))
    done
    prev=("${now[@]}")

    if [ "$ndead" -eq "$CPUS" ]; then
        [ "$ALL_DEAD_SINCE" -eq 0 ] && { ALL_DEAD_SINCE=$t; log " all $CPUS CPUs silent; settling for ${SETTLE}s ..."; }
        if [ $((t - ALL_DEAD_SINCE)) -ge "$SETTLE" ]; then
            log " settle done: no recovery in ${SETTLE}s"
            break
        fi
    else
        ALL_DEAD_SINCE=0
    fi

    if [ $(( t % 5 )) -eq 0 ]; then
        printf '[%4ds] active=%-2d dead=%-2d  PMI/s:' "$t" "$active" "$ndead"
        for i in $(seq 0 $((CPUS-1))); do printf ' %d' "${rate[$i]}"; done
        printf '\n'
    fi

    if [ $(( $(date +%s) - START_EPOCH )) -ge "$DURATION_S" ]; then
        log " max duration reached"
        break
    fi
done

# --- stop ---
stop_perf
END_UP=$(cut -d' ' -f1 /proc/uptime)
cp /proc/interrupts "$OUT/interrupts-end.txt" 2>/dev/null || true
[ "$have_journal" -eq 1 ] && journalctl -k --no-pager > "$OUT/dmesg-run.txt" 2>/dev/null || true

# --- post ---
if [ -s "$OUT/perf.data" ]; then
    log " running perf script (this can take ~10-30s) ..."
    perf script -i "$OUT/perf.data" -F cpu,time --ns > "$OUT/result.txt" 2> "$OUT/perf-script.err" || true
fi
perf report --header-only -i "$OUT/perf.data" > "$OUT/perf-header.txt" 2>&1 || true
perf evlist -v -i "$OUT/perf.data" > "$OUT/perf-events.txt" 2>&1 || true

# --- summary ---
{
    echo "================ summary ================"
    echo "run dir : $OUT"
    echo "start   : $(date -d @"$START_EPOCH" -Is)   uptime $START_UP"
    echo "end     : $(date -Is)   uptime $END_UP"
    echo
    echo "---- per-CPU samples (from result.txt) ----"
    analyze
    echo
    echo "---- silent CPUs (from monitor.log) ----"
    [ -s "$OUT/deaths.txt" ] && cat "$OUT/deaths.txt" || echo "(none)"
    echo
    echo "---- MSR dumps ----"
    [ -s "$OUT/msr.log" ] && cat "$OUT/msr.log" || echo "(none)"
    echo
    echo "---- key sysctls / header ----"
    grep -E 'perf_event_max_sample_rate|perf_cpu_time_max_percent|nmi_watchdog' "$OUT/meta.txt"
    grep -E 'lost|throttle|Number of samples|number of samples' "$OUT/perf-header.txt" 2>/dev/null || true
    echo
    echo "---- kernel messages during the run ----"
    if [ -s "$OUT/dmesg-run.txt" ]; then
        grep -iE 'perf|ibs|nmi|throttl|WARNING|Uhhuh|lockup' "$OUT/dmesg-run.txt" | tail -30 || true
    else
        echo "(no journalctl)"
    fi
    echo
    echo "================ how to read this ================"
    echo "1) This run had perf throttling DISABLED (percent=0, rate=100000):"
    echo "   'samples between gaps' must NOT show the per-tick signature"
    echo "   (mode ~= max_samples_per_tick = rate/HZ, all CPUs stopping at the"
    echo "   same ms phase).  If it does, the sysctl sequence failed -- check"
    echo "   monitor.log for 'disabling throttle'."
    echo "2) MSR on a silent CPU while perf is still running:"
    echo "   IBS_OP_ENABLE=0                     -> kernel disabled it   (software)"
    echo "   IBS_OP_ENABLE=1 IBS_OP_VAL=1 frozen -> HW latched, no NMI   (NMI/hardware)"
    echo "   IBS_OP_ENABLE=1 IBS_OP_VAL=0 moving -> HW counts, no NMI    (hardware/firmware)"
    echo "3) Note: throttling disabled does NOT prevent the failure.  On"
    echo "   2026-10-18 22:18 all 12 CPUs stopped within 369s with throttling"
    echo "   disabled, then 24 min of zero samples.  So the per-tick throttle"
    echo "   is NOT required for the failure.  The MSR state on a silent CPU"
    echo "   is the key discriminator."
} > "$OUT/summary.txt" 2>&1

cat "$OUT/summary.txt"
log " done. everything is in $OUT"
