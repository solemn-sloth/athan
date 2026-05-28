#!/bin/bash
set -euo pipefail

CONFIG_DIR="$HOME/.athan"
CONFIG="$CONFIG_DIR/config.json"
STATE="$CONFIG_DIR/state/last-played"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

[[ -f "$CONFIG" ]] || { log "ERROR: $CONFIG not found"; exit 1; }

GATEWAY_MAC=$(jq -r '.gateway_mac' "$CONFIG")
VOLUME=$(jq -r '.audio_volume // 0.8' "$CONFIG")
GRACE=$(jq -r '.grace_period_minutes // 2' "$CONFIG")
BUFFER=$(jq -r '.meeting_buffer_minutes // 1' "$CONFIG")
SKIP_MTG=$(jq -r '.skip_if_meeting // true' "$CONFIG")
TZ_NAME=$(jq -r '.timezone // "Europe/London"' "$CONFIG")

# --- Home check via router MAC ---
if [[ -n "$GATEWAY_MAC" && "$GATEWAY_MAC" != "null" ]]; then
    GWAY_IP=$(route get default 2>/dev/null | awk '/gateway/{print $2}')
    CURRENT_MAC=$(arp -n "$GWAY_IP" 2>/dev/null | awk '{print $4}')
    if [[ "$CURRENT_MAC" != "$GATEWAY_MAC" ]]; then
        log "Not home (gateway MAC: '$CURRENT_MAC')"
        exit 0
    fi
    log "Home confirmed"
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

# Pause Spotify/Music if playing, return what was paused
pause_audio() {
    PAUSED=""
    for APP in "Spotify" "Music"; do
        STATE=$(osascript -e "tell application \"$APP\" to if it is running then get player state" 2>/dev/null || true)
        if [[ "$STATE" == "playing" ]]; then
            osascript -e "tell application \"$APP\" to pause" 2>/dev/null || true
            PAUSED="$APP"
            log "Paused $APP"
            break
        fi
    done
    echo "$PAUSED"
}

resume_audio() {
    local APP="$1"
    [[ -z "$APP" ]] && return
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

    PAUSED_APP=$(pause_audio)

    URL=$(jq -r --argjson i "$((RANDOM % $(jq '.audio_urls | length' "$CONFIG")))" '.audio_urls[$i]' "$CONFIG")
    TMP="/tmp/athan-$$.mp3"
    POPUP="$CONFIG_DIR/athan-pop/.build/release/athan-pop"

    log "Playing athan: $PRAYER ($PTIME)"
    mkdir -p "$(dirname "$STATE")"
    echo "$KEY" >> "$STATE"

    (
        curl -sL --connect-timeout 15 "$URL" -o "$TMP" || { rm -f "$TMP"; exit 1; }
        afplay -v "$VOLUME" "$TMP" &
        AFPLAY_PID=$!
        if [[ -x "$POPUP" ]]; then
            "$POPUP" --prayer "$PRAYER" --pid "$AFPLAY_PID" --duration 30 &
        fi
        wait "$AFPLAY_PID" 2>/dev/null
        rm -f "$TMP"
        resume_audio "$PAUSED_APP"
    ) &

    log "Recorded $PRAYER"
    break
done < <(jq -r '.prayers_to_play[]' "$CONFIG")
