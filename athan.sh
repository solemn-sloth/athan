#!/bin/bash
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$CONFIG_DIR/config.json"
STATE="$CONFIG_DIR/state/last-played"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

[[ -f "$CONFIG" ]] || { log "ERROR: $CONFIG not found"; exit 1; }

GATEWAY_MACS=$(jq -r '.gateway_macs[]' "$CONFIG" 2>/dev/null || jq -r '.gateway_mac' "$CONFIG")
VOLUME=$(jq -r '.audio_volume // 0.8' "$CONFIG")
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

# --- Fetch prayer times from WISE masjid API ---
YEAR=$(TZ="$TZ_NAME" date +%Y)
MONTH=$(TZ="$TZ_NAME" date +%m)
DAY=$(TZ="$TZ_NAME" date +%d)
TODAY_DATE=$(TZ="$TZ_NAME" date +%Y-%m-%d)

RESP=$(curl -sL --connect-timeout 10 \
    "https://www.wise-web.org/wp-json/my-route/PrayerTime/${YEAR}/${MONTH}/${DAY}" \
    2>/dev/null)
[[ "$(echo "$RESP" | jq -r '.prayer_time.d_date // empty')" == "$TODAY_DATE" ]] || { log "API error or wrong date"; exit 0; }

prayer_field() {
    case "$1" in
        Fajr)    echo "fajr_begins" ;;
        Dhuhr)   echo "zuhr_begins" ;;
        Asr)     echo "asr_mithl_1" ;;
        Maghrib) echo "maghrib_begins" ;;
        Isha)    echo "isha_begins" ;;
        *)       echo "" ;;
    esac
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
    FIELD=$(prayer_field "$PRAYER")
    [[ -z "$FIELD" ]] && continue

    PTIME_FULL=$(echo "$RESP" | jq -r ".prayer_time.${FIELD}")
    [[ -z "$PTIME_FULL" || "$PTIME_FULL" == "null" ]] && continue
    PTIME="${PTIME_FULL:0:5}"  # trim seconds: "22:46:00" → "22:46"

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

    # Miss window: up to 5 min late — play if not already recorded
    (( DIFF < 0 || DIFF > 5 )) && continue

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
    echo "$KEY" >> "$STATE"

    if [[ "$AT_HOME" == "true" ]]; then
        # Full experience: pause audio, play athan, show pill, resume
        PAUSED_APP=$(pause_audio)
        URL=$(jq -r --argjson i "$((RANDOM % $(jq '.audio_urls | length' "$CONFIG")))" '.audio_urls[$i]' "$CONFIG")
        TMP="/tmp/athan-$$.mp3"
        (
            curl -sL --connect-timeout 15 "$URL" -o "$TMP" || { rm -f "$TMP"; exit 1; }
            afplay -v "$VOLUME" "$TMP" &
            AFPLAY_PID=$!
            [[ -x "$POPUP" ]] && "$POPUP" --prayer "$PRAYER" --pid "$AFPLAY_PID" --duration 30 &
            wait "$AFPLAY_PID" 2>/dev/null
            rm -f "$TMP"
            resume_audio "$PAUSED_APP"
        ) &
    else
        # Away: pill notification only, no audio
        [[ -x "$POPUP" ]] && "$POPUP" --prayer "$PRAYER" --pid 0 --duration 30 &
    fi

    log "Recorded $PRAYER"
    break
done < <(jq -r '.prayers_to_play[]' "$CONFIG")
