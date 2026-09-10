#!/bin/sh
# check-thread.sh - Thread radio-link diagnostics for a Home Assistant OS host.
#
# PURPOSE
#   Captures the 802.15.4 link quality around a Matter-over-Thread pairing attempt.
#   A one-shot snapshot is not much use here: the device attaches, fails, and is
#   dropped again within about five minutes. So this samples repeatedly and you run
#   the pairing attempt while it watches.
#
# WHERE TO RUN
#   The HAOS *host* shell: Proxmox console for the VM -> type `login` at the `ha >`
#   prompt. Not the Terminal & SSH add-on -- it has no docker access.
#
#   cd /mnt/data/supervisor/homeassistant
#   sh check-thread.sh
#
#   Optional label, to keep two runs apart (e.g. one far from the dongle, one close):
#     sh check-thread.sh far        -> check-thread-far.txt
#     sh check-thread.sh close      -> check-thread-close.txt
#
#   Optional timing overrides:
#     DURATION=480 INTERVAL=15 sh check-thread.sh
#
# WHERE IT LANDS
#   check-thread.txt in the Home Assistant config directory -- the folder Studio Code
#   Server shows as /config.
#
# SAFETY
#   Read-only. It changes nothing and sends nothing anywhere. It deliberately does NOT
#   run `ot-ctl dataset ...`, `networkkey` or `pskc`, all of which would print the
#   Thread network key into a file you are going to paste into a chat.

LABEL="$1"
DURATION="${DURATION:-360}"     # total sampling window, seconds
INTERVAL="${INTERVAL:-20}"      # seconds between samples

# ---------------------------------------------------------------- output file
OUTDIR=""
for d in /mnt/data/supervisor/homeassistant /config .; do
    if [ -d "$d" ] && [ -w "$d" ]; then
        OUTDIR="$d"
        break
    fi
done
[ -n "$OUTDIR" ] || OUTDIR=.
if [ -n "$LABEL" ]; then
    OUT="$OUTDIR/check-thread-$LABEL.txt"
else
    OUT="$OUTDIR/check-thread.txt"
fi

TMP="${TMPDIR:-/tmp}"
MAC_BEFORE="$TMP/.ct-mac-before.$$"
MAC_AFTER="$TMP/.ct-mac-after.$$"

# ------------------------------------------------- find the OTBR container
OTBR="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i -e openthread -e otbr | head -1)"

section() {
    printf '\n\n===== %s =====\n' "$1"
}

otctl() {
    if [ -z "$OTBR" ]; then
        printf '\n--- $ ot-ctl %s\n(skipped: no OpenThread container found)\n' "$*"
        return
    fi
    printf '\n--- $ ot-ctl %s\n' "$*"
    docker exec "$OTBR" ot-ctl "$@" 2>&1
}

otctl_raw() {
    [ -n "$OTBR" ] || return
    docker exec "$OTBR" ot-ctl "$@" 2>/dev/null
}

# ---------------------------------------------------------------------- report
report() {

section "0  META"
printf 'collected      : %s\n' "$(date 2>/dev/null)"
printf 'label          : %s\n' "${LABEL:-<none>}"
printf 'otbr container : %s\n' "${OTBR:-<none found>}"
printf 'window         : %ss total, sampling every %ss\n' "$DURATION" "$INTERVAL"
printf '\nNOTE: OpenThread core log lines are stamped with UPTIME, not wall clock.\n'
printf 'The uptime reading below is what converts them to real times.\n'
otctl uptime

section "1  RADIO / NETWORK CONFIG"
otctl channel
otctl txpower
otctl state
otctl rloc16
otctl extaddr
otctl partitionid
otctl leaderdata
otctl networkname

section "2  MAC COUNTERS (baseline)"
printf 'TxErrCca high and climbing => the channel is congested (Wi-Fi overlap).\n'
printf 'TxRetry / TxErrAbort high  => weak link to a specific peer (range).\n'
otctl counters mac
otctl_raw counters mac > "$MAC_BEFORE" 2>/dev/null

section "3  READY"
cat <<'EOF'

    ----------------------------------------------------------
     START YOUR PAIRING ATTEMPT NOW.

     Factory-reset the device first, then pair from the
     companion app. Leave this script running to the end --
     the interesting part is the drop-off, which happens
     about five minutes after the device attaches, well
     after the app has already said "Pairing failed".
    ----------------------------------------------------------

EOF

section "4  SAMPLES"
elapsed=0
n=0
while [ "$elapsed" -lt "$DURATION" ]; do
    n=$((n + 1))
    printf '\n\n---------- sample %s  (t+%ss, %s) ----------\n' \
        "$n" "$elapsed" "$(date '+%H:%M:%S' 2>/dev/null)"
    otctl neighbor table
    otctl child table
    otctl router table
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

section "5  MAC COUNTERS (final)"
otctl counters mac
otctl_raw counters mac > "$MAC_AFTER" 2>/dev/null

section "6  MAC COUNTERS (what changed over the window)"
if [ -s "$MAC_BEFORE" ] && [ -s "$MAC_AFTER" ]; then
    # HAOS's busybox has no diff, so fall back to an awk join on the counter name.
    if command -v diff >/dev/null 2>&1; then
        diff "$MAC_BEFORE" "$MAC_AFTER" 2>&1 || true
    else
        awk 'NR==FNR { a[$1] = $2; next }
             ($1 in a) && a[$1] != $2 { printf "%-30s %s -> %s\n", $1, a[$1], $2 }' \
            "$MAC_BEFORE" "$MAC_AFTER" 2>&1
    fi
else
    printf '(baseline or final capture unavailable)\n'
fi

section "7  MLE COUNTERS"
otctl counters mle

section "8  BORDER ROUTER / NETWORK DATA"
otctl br state
otctl br counters
otctl netdata show
otctl uptime

section "9  OTBR LOG (link-layer and attach events)"
if [ -n "$OTBR" ]; then
    printf '\n--- $ docker logs --tail 600 %s | grep MeshForwarder/RouterTable/Mle\n' "$OTBR"
    docker logs --tail 600 "$OTBR" 2>&1 \
        | grep -E 'MeshForwarder|RouterTable|NoAck|Mle-|AddressResolver|Joiner' \
        | tail -80
else
    printf '(no container)\n'
fi

section "END"

}

# ------------------------------------------------------------------------ go
report 2>&1 | tee "$OUT"

rm -f "$MAC_BEFORE" "$MAC_AFTER"

printf '\n\nWritten to: %s\n' "$OUT"
printf 'Open it in Studio Code Server as /config/%s\n' "$(basename "$OUT")"
