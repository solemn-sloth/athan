#!/bin/bash
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$CONFIG_DIR/config.json"
STATE="$CONFIG_DIR/state/last-played"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

[[ -f "$CONFIG" ]] || { log "ERROR: $CONFIG not found"; exit 1; }

LOCK="$CONFIG_DIR/state/lock"
mkdir -p "$CONFIG_DIR/state"
# ponytail: atomic mkdir lock — no flock on macOS. Stale only on SIGKILL; add age-check if it ever wedges.
if ! mkdir "$LOCK" 2>/dev/null; then
    log "Another athan run is active — skipping tick"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

GATEWAY_MACS=$(jq -r '.gateway_macs[]' "$CONFIG" 2>/dev/null || jq -r '.gateway_mac' "$CONFIG")
GRACE=$(jq -r '.grace_period_minutes // 2' "$CONFIG")
BUFFER=$(jq -r '.meeting_buffer_minutes // 1' "$CONFIG")
SKIP_MTG=$(jq -r '.skip_if_meeting // true' "$CONFIG")
TZ_NAME=$(jq -r '.timezone // "Europe/London"' "$CONFIG")

# --- Home check via router MAC ---
AT_HOME=false
if [[ -n "$GATEWAY_MACS" && "$GATEWAY_MACS" != "null" ]]; then
    GWAY_IP=$(route get default 2>/dev/null | awk '/gateway/{print $2}')
    CURRENT_MAC=$(arp -n "$GWAY_IP" 2>/dev/null | awk '{print $4}')
    if echo "$GATEWAY_MACS" | grep -qF "$CURRENT_MAC"; then
        AT_HOME=true
        log "Home confirmed ($CURRENT_MAC)"
    else
        log "Not home — pill only"
    fi
fi

# --- Fetch prayer times ---
YEAR=$(TZ="$TZ_NAME" date +%Y)
MONTH=$(TZ="$TZ_NAME" date +%m)
DAY=$(TZ="$TZ_NAME" date +%d)
TODAY_DATE=$(TZ="$TZ_NAME" date +%Y-%m-%d)

SOURCE=$(jq -r '.prayer_source // "wise"' "$CONFIG")

if [[ "$SOURCE" == "aladhan" ]]; then
    CITY=$(jq -r '.city' "$CONFIG")
    COUNTRY=$(jq -r '.country' "$CONFIG")
    METHOD=$(jq -r '.method // 3' "$CONFIG")
    SCHOOL=$(jq -r '.school // 0' "$CONFIG")
    RESP=$(curl -sL --connect-timeout 10 \
        "https://api.aladhan.com/v1/timingsByCity/${DAY}-${MONTH}-${YEAR}?city=${CITY}&country=${COUNTRY}&method=${METHOD}&school=${SCHOOL}" \
        2>/dev/null)
    [[ "$(echo "$RESP" | jq -r '.code')" == "200" ]] || { log "Aladhan API error"; exit 0; }
else
    RESP=$(curl -sL --connect-timeout 10 \
        "https://www.wise-web.org/wp-json/my-route/PrayerTime/${YEAR}/${MONTH}/${DAY}" \
        2>/dev/null)
    [[ "$(echo "$RESP" | jq -r '.prayer_time.d_date // empty')" == "$TODAY_DATE" ]] || { log "API error or wrong date"; exit 0; }
fi

get_prayer_time() {
    local PRAYER="$1"
    if [[ "$SOURCE" == "aladhan" ]]; then
        echo "$RESP" | jq -r ".data.timings.${PRAYER}" | cut -c1-5
    else
        local FIELD
        case "$PRAYER" in
            Fajr)    FIELD="fajr_begins" ;;
            Dhuhr)   FIELD="zuhr_begins" ;;
            Asr)     FIELD="asr_mithl_1" ;;
            Maghrib) FIELD="maghrib_begins" ;;
            Isha)    FIELD="isha_begins" ;;
            *)       echo ""; return ;;
        esac
        echo "$RESP" | jq -r ".prayer_time.${FIELD}" | cut -c1-5
    fi
}

NOW=$(TZ="$TZ_NAME" date +%H:%M)

# Check for current or imminent meeting
is_busy() {
    perl -e '
alarm 5;
$SIG{ALRM} = sub { print "false\n"; exit 0 };
my $out = `osascript -e "tell application \"Calendar\"
    set nowDate to current date
    set checkEnd to nowDate + '"$BUFFER"' * minutes
    set foundBusy to false
    repeat with c in every calendar
        repeat with e in (every event of c whose start date < checkEnd and end date > nowDate and allday event is false)
            set foundBusy to true
        end repeat
    end repeat
    return foundBusy
end tell" 2>/dev/null`;
chomp $out;
print $out eq "" ? "false" : $out, "\n";
' 2>/dev/null || echo "false"
}

# Pause all known audio sources, return the first resumable app found
pause_audio() {
    PAUSED=""

    # Native apps with play/pause AppleScript support
    for APP in "Spotify" "Music" "Podcasts" "Doppler"; do
        STATE=$(osascript -e "tell application \"$APP\" to if it is running then get player state" 2>/dev/null || true)
        if [[ "$STATE" == "playing" ]]; then
            osascript -e "tell application \"$APP\" to pause" 2>/dev/null || true
            [[ -z "$PAUSED" ]] && PAUSED="$APP"
            log "Paused $APP"
        fi
    done

    # Browsers — pause via JavaScript (can't reliably resume, so pause-only)
    for BROWSER in "Google Chrome" "Firefox" "Safari"; do
        RUNNING=$(osascript -e "tell application \"System Events\" to (name of processes) contains \"$BROWSER\"" 2>/dev/null || echo "false")
        if [[ "$RUNNING" == "true" ]]; then
            case "$BROWSER" in
                "Google Chrome")
                    osascript -e 'tell application "Google Chrome"
                        repeat with w in every window
                            repeat with t in every tab of w
                                execute t javascript "document.querySelectorAll(\"audio,video\").forEach(e => { if(!e.paused) { e.pause(); e.dataset.athanPaused=\"1\"; } })"
                            end repeat
                        end repeat
                    end tell' 2>/dev/null || true ;;
                "Firefox")
                    # Firefox doesn't support tab JS injection via AppleScript — use media key
                    osascript -e 'tell application "System Events" to key code 16' 2>/dev/null || true ;;
                "Safari")
                    osascript -e 'tell application "Safari"
                        repeat with w in every window
                            repeat with t in every tab of w
                                do JavaScript "document.querySelectorAll(\"audio,video\").forEach(e => { if(!e.paused) { e.pause(); e.dataset.athanPaused=\"1\"; } })" in t
                            end repeat
                        end repeat
                    end tell' 2>/dev/null || true ;;
            esac
            log "Paused media in $BROWSER"
        fi
    done

    echo "$PAUSED"
}

resume_audio() {
    local APP="$1"
    [[ -z "$APP" ]] && return
    # Resume native app (browsers resume when user next interacts)
    osascript -e "tell application \"$APP\" to play" 2>/dev/null || true
    log "Resumed $APP"
}

# --- Check each prayer ---
while IFS= read -r PRAYER; do
    PTIME=$(get_prayer_time "$PRAYER")
    [[ -z "$PTIME" || "$PTIME" == "null" ]] && continue

    P_MIN=$(( 10#${PTIME%%:*} * 60 + 10#${PTIME##*:} ))
    N_MIN=$(( 10#${NOW%%:*} * 60 + 10#${NOW##*:} ))
    DIFF=$(( N_MIN - P_MIN ))

    # Pre-fire: running up to 1 min early — sleep until prayer time
    if (( DIFF < 0 && DIFF >= -1 )); then
        WAIT=$(( -DIFF * 60 ))
        log "Early by ${WAIT}s for $PRAYER — sleeping"
        sleep "$WAIT"
        DIFF=0
    fi

    # Miss window: up to $GRACE min late — play if not already recorded
    (( DIFF < 0 || DIFF > GRACE )) && continue

    KEY="${TODAY_DATE}:${PRAYER}"
    grep -qF "$KEY" "$STATE" 2>/dev/null && { log "Already played $PRAYER"; continue; }

    if [[ "$SKIP_MTG" == "true" ]]; then
        BUSY=$(is_busy)
        if [[ "$BUSY" == "true" ]]; then
            log "Meeting within ${BUFFER}min — skipping $PRAYER"
            continue
        fi
    fi

    POPUP="$CONFIG_DIR/athan-pop/.build/release/athan-pop"

    log "Playing athan: $PRAYER ($PTIME) (home=$AT_HOME)"
    mkdir -p "$(dirname "$STATE")"

    if [[ "$AT_HOME" == "true" ]]; then
        # Full experience: pause audio, play athan, show pill, resume
        PAUSED_APP=$(pause_audio)
        AUDIO_URLS_LEN=$(jq '.audio_urls | length' "$CONFIG")
        URL=$(jq -r --argjson i "$((RANDOM % AUDIO_URLS_LEN))" '.audio_urls[$i]' "$CONFIG")
        TMP="/tmp/athan-$$.mp3"
        PLAYED=false
        for ATTEMPT in 1 2 3; do
            if curl -sL --connect-timeout 15 "$URL" -o "$TMP" && [[ -s "$TMP" ]]; then
                PLAYED=true
                break
            fi
            log "Audio download failed (attempt $ATTEMPT) — retrying with next URL"
            rm -f "$TMP"
            URL=$(jq -r --argjson i "$((RANDOM % AUDIO_URLS_LEN))" '.audio_urls[$i]' "$CONFIG")
        done
        if [[ "$PLAYED" == "true" ]]; then
            # ponytail: state-before-play guards re-fire; add flock only if ticks still race.
            echo "$KEY" >> "$STATE"
            log "Recorded $PRAYER"
            ORIG_VOL=$(osascript -e "output volume of (get volume settings)")
            osascript -e "set volume output volume 6"
            sleep 0.1
            afplay "$TMP" &
            AFPLAY_PID=$!
            POPUP_PID=0
            [[ -x "$POPUP" ]] && { "$POPUP" --prayer "$PRAYER" --pid "$AFPLAY_PID" --duration 3600 & POPUP_PID=$!; }
            wait "$AFPLAY_PID" 2>/dev/null || true
            (( POPUP_PID > 0 )) && kill "$POPUP_PID" 2>/dev/null || true
            osascript -e "set volume output volume $ORIG_VOL"
            rm -f "$TMP"
            resume_audio "$PAUSED_APP"
        else
            log "ERROR: audio download failed after 3 attempts — $PRAYER not recorded"
            resume_audio "$PAUSED_APP"
        fi
    else
        # Away: pill notification only, no audio
        [[ -x "$POPUP" ]] && "$POPUP" --prayer "$PRAYER" --pid 0 --duration 30 &
        echo "$KEY" >> "$STATE"
        log "Recorded $PRAYER"
    fi
    break
done < <(jq -r '.prayers_to_play[]' "$CONFIG")
