# athan

Automatic athan (Islamic call to prayer) for macOS. Plays when you're home, at prayer time, and not in a meeting.

## Features

- **Prayer times from your local masjid** — pulls from Wise Masjid High Wycombe API, perfectly in sync
- **Home detection** — checks your router's MAC address via `arp`, no permissions needed
- **Meeting-aware** — skips if you're in a calendar event (or one starts within 1 minute)
- **Floating pill notification** — glass-style macOS overlay showing the prayer name with a Skip button
- **Audio pause/resume** — pauses any playing audio, resumes after the athan
- **Random muezzin rotation** — picks from 6 recordings on the Aladhan CDN each time (no local file needed)
- **Runs automatically** — launchd agent fires every 60 seconds

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)
- `jq` (`brew install jq`)
- Google Calendar synced to macOS Calendar.app (System Settings → Internet Accounts)

## Install

> **Important:** Clone into a path that is NOT inside `~/Documents`, `~/Desktop`, or `~/Downloads`. macOS restricts background agents from accessing those folders. A good default is `~/.local/share/athan` or `~/athan`.

```bash
git clone https://github.com/hisham-alam/athan ~/.local/share/athan
cd ~/.local/share/athan
./install.sh
```

The script handles everything: checks your install path, detects your router MAC, builds the popup, requests Calendar access, and loads the launchd agent.

<details>
<summary>Manual steps (if you prefer)</summary>

```bash
# 1. Copy and edit config
cp config.example.json config.json

# 2. Find your router MAC (must be on home WiFi/network)
arp -n $(route get default | awk '/gateway/{print $2}') | awk '{print $4}'
# Paste that into config.json as "gateway_macs": ["<mac>"]

# 3. Build the pill notification binary
swift build -c release --package-path athan-pop

# 4. Grant Calendar access (will prompt on first run)
osascript -e 'tell application "Calendar" to get name of every calendar'

# 5. Install and load the launchd agent
sed "s|ATHAN_DIR|$PWD|g" com.hisham.athan.plist > ~/Library/LaunchAgents/com.hisham.athan.plist
launchctl load ~/Library/LaunchAgents/com.hisham.athan.plist
```
</details>

## Config

| Key | Default | Description |
|-----|---------|-------------|
| `prayer_source` | `"wise"` | `"wise"` for Wise Masjid, `"aladhan"` for Aladhan API |
| `city` | `"London"` | City for Aladhan source |
| `country` | `"UK"` | Country for Aladhan source |
| `method` | `3` | Aladhan calculation method ID |
| `school` | `1` | Asr school: `0` = Shafi, `1` = Hanafi |
| `gateway_macs` | — | Array of router MAC addresses for locations where audio plays. Use `add-athan-location` to add the current network. |
| `prayers_to_play` | all 5 | Array of `Fajr`, `Dhuhr`, `Asr`, `Maghrib`, `Isha` |
| `audio_urls` | 6 Aladhan CDN URLs | MP3s to rotate between. Streamed each time, no local file needed |
| `audio_volume` | `0.8` | Volume for `afplay` (0.0–1.0) |
| `skip_if_meeting` | `true` | Skip if a calendar event is active or starting within `meeting_buffer_minutes` |
| `meeting_buffer_minutes` | `1` | How many minutes ahead to check for upcoming meetings |
| `grace_period_minutes` | `2` | How many minutes after prayer time the athan can still trigger (catches late wakes) |
| `timezone` | `Europe/London` | Timezone for date calculations |

## Prayer time sources

Set `prayer_source` in `config.json` to choose:

### `"wise"` (default)

Times from [Wise Masjid High Wycombe](https://www.wise-web.org/prayer-times/) — exact local timetable, no further config needed.

### `"aladhan"`

Times from the [Aladhan API](https://aladhan.com/prayer-times-api) — works for any city worldwide. Requires:

| Key | Example | Description |
|-----|---------|-------------|
| `city` | `"London"` | City name |
| `country` | `"UK"` | Country code or name |
| `method` | `3` | Calculation method (3 = Muslim World League, 2 = ISNA, 4 = Umm al-Qura, 5 = Egyptian) |
| `school` | `1` | Asr calculation: `0` = Shafi, `1` = Hanafi |

`install.sh` will prompt for these interactively. To switch source later, edit `config.json` directly.

## Adding locations

To play the athan (or show the pill) at another location, connect to that network and run:

```bash
add-athan-location
```

This detects the router's MAC address and appends it to `gateway_macs` in `config.json`. Run it once per network. No permissions needed.

## Logs

```bash
tail -f ~/.local/share/athan/logs/athan.log
```

## Sleep mode

The launchd agent won't fire while the Mac is asleep. Increase `grace_period_minutes` if you want it to catch up when the lid opens.

## Credits

Pill notification UI forked from [claude-pop](https://github.com/esc5221/claude-pop) by esc5221.  
Audio from [Aladhan CDN](https://aladhan.com).
