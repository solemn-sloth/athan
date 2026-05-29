#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'

step() { echo -e "\n${BOLD}[$1/7] $2${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
die()  { echo -e "\n${RED}Error:${RESET} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${BOLD}athan install${RESET}"
echo "Installing from: $SCRIPT_DIR"

# 1. Check install location
step 1 "Checking install path"
for PROTECTED in "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads"; do
    case "$SCRIPT_DIR" in
        "$PROTECTED"*) die "Installed inside $PROTECTED — macOS blocks background agents from this folder.\nMove the repo elsewhere (e.g. ~/.local/share/athan) and re-run." ;;
    esac
done
ok "Path is safe"

# 2. Check dependencies
step 2 "Checking dependencies"
if ! command -v jq &>/dev/null; then
    die "'jq' not found. Install it with: brew install jq"
fi
ok "jq $(jq --version)"

if ! command -v swift &>/dev/null; then
    die "'swift' not found. Install Xcode Command Line Tools: xcode-select --install"
fi
ok "swift $(swift --version 2>&1 | head -1)"

# 3. Config
step 3 "Config"
if [[ ! -f config.json ]]; then
    cp config.example.json config.json
    ok "Created config.json from config.example.json"

    # Prayer time source
    echo ""
    echo "  Prayer time source:"
    echo "    1) Wise Masjid High Wycombe (UK — exact local timetable)"
    echo "    2) Aladhan API (any city worldwide)"
    read -rp "  Choose [1-2]: " SRC_CHOICE
    case "$SRC_CHOICE" in
        2)
            read -rp "  City: " CITY
            read -rp "  Country (e.g. UK, US, SA): " COUNTRY
            echo ""
            echo "  Calculation method:"
            echo "    1) Muslim World League"
            echo "    2) ISNA (North America)"
            echo "    3) Umm al-Qura (Saudi Arabia)"
            echo "    4) Egyptian General Authority"
            read -rp "  Choose [1-4]: " METHOD_CHOICE
            case "$METHOD_CHOICE" in
                2) METHOD=2 ;;
                3) METHOD=4 ;;
                4) METHOD=5 ;;
                *) METHOD=3 ;;
            esac
            echo ""
            echo "  Asr school:"
            echo "    1) Shafi (standard)"
            echo "    2) Hanafi (later Asr)"
            read -rp "  Choose [1-2]: " SCHOOL_CHOICE
            [[ "$SCHOOL_CHOICE" == "2" ]] && SCHOOL=1 || SCHOOL=0
            tmp=$(mktemp)
            jq --arg src "aladhan" --arg city "$CITY" --arg country "$COUNTRY" \
               --argjson method "$METHOD" --argjson school "$SCHOOL" \
               '.prayer_source=$src | .city=$city | .country=$country | .method=$method | .school=$school' \
               config.json > "$tmp" && mv "$tmp" config.json
            ok "Aladhan configured: $CITY, $COUNTRY (method=$METHOD, school=$SCHOOL)"
            ;;
        *)
            tmp=$(mktemp)
            jq '.prayer_source = "wise"' config.json > "$tmp" && mv "$tmp" config.json
            ok "Using Wise Masjid High Wycombe timetable"
            ;;
    esac

    # Gateway MAC
    GATEWAY_IP=$(route get default 2>/dev/null | awk '/gateway/{print $2}')
    CURRENT_MAC=$(arp -n "$GATEWAY_IP" 2>/dev/null | awk '{print $4}')
    if [[ -n "$CURRENT_MAC" && "$CURRENT_MAC" != "incomplete" ]]; then
        tmp=$(mktemp)
        jq --arg mac "$CURRENT_MAC" '.gateway_macs = [$mac]' config.json > "$tmp" && mv "$tmp" config.json
        ok "Detected and saved gateway MAC: $CURRENT_MAC"
    else
        warn "Could not detect gateway MAC. Edit config.json and add your router's MAC to \"gateway_macs\"."
    fi
else
    ok "config.json already exists — skipping"
fi

# 4. Build pill popup
step 4 "Building athan-pop"
if [[ -x athan-pop/.build/release/athan-pop ]]; then
    ok "athan-pop already built — skipping"
else
    swift build -c release --package-path athan-pop 2>&1 | tail -3
    ok "athan-pop built"
fi

# 5. Calendar access
step 5 "Calendar access"
echo "  Requesting Calendar access (approve the popup if it appears)..."
osascript -e 'tell application "Calendar" to get name of every calendar' &>/dev/null || true
ok "Done"

# 6. Log/state dirs + generate & load plist
step 6 "Installing launchd agent"
mkdir -p logs state

PLIST="$HOME/Library/LaunchAgents/com.hisham.athan.plist"
sed "s|ATHAN_DIR|$SCRIPT_DIR|g" com.hisham.athan.plist > "$PLIST"
ok "Generated $PLIST"

# Unload first if already registered (idempotent)
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
ok "Agent loaded"

# 7. Verify
step 7 "Verifying"
echo "  Waiting up to 65 seconds for first run..."
for i in $(seq 1 65); do
    sleep 1
    EXIT_CODE=$(launchctl list | awk '/local\.athan$/{print $2}')
    if [[ "$EXIT_CODE" == "0" ]]; then
        ok "Agent running (exit 0)"
        break
    elif [[ "$EXIT_CODE" == "78" ]]; then
        warn "Exit 78 — reloading once more..."
        launchctl unload "$PLIST" 2>/dev/null || true
        launchctl load "$PLIST"
    fi
    if [[ $i -eq 65 ]]; then
        warn "Could not confirm clean run. Check: launchctl list | grep athan"
    fi
done

echo -e "\n${GREEN}${BOLD}All done.${RESET} Athan will play at prayer times when you're home."
echo "  Logs: $SCRIPT_DIR/logs/athan.log"
