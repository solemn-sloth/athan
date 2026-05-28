# athan

Automatic athan (Islamic call to prayer) for macOS. Plays when you're home, at prayer time, and not in a meeting.

## Features

- **Prayer times from your local masjid** — pulls from WISE Mosque (Woolwich) API, perfectly in sync
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

```bash
# 1. Clone to ~/.athan
git clone https://github.com/hisham-alam/athan ~/.athan
cd ~/.athan

# 2. Copy and edit config
cp config.example.json config.json

# 3. Find your router MAC (must be on home WiFi/network)
arp -n $(route get default | awk '/gateway/{print $2}') | awk '{print $4}'
# Paste that into config.json as "gateway_mac"

# 4. Build the pill notification binary
swift build -c release --package-path athan-pop

# 5. Grant Calendar access (will prompt on first run)
osascript -e 'tell application "Calendar" to get name of every calendar'

# 6. Install and load the launchd agent
cp com.hisham.athan.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.hisham.athan.plist
```

## Config

| Key | Default | Description |
|-----|---------|-------------|
| `gateway_mac` | — | MAC address of your home router. Get it with `arp -n $(route get default \| awk '/gateway/{print $2}') \| awk '{print $4}'` |
| `prayers_to_play` | all 5 | Array of `Fajr`, `Dhuhr`, `Asr`, `Maghrib`, `Isha` |
| `audio_urls` | 6 Aladhan CDN URLs | MP3s to rotate between. Streamed each time, no local file needed |
| `audio_volume` | `0.8` | Volume for `afplay` (0.0–1.0) |
| `skip_if_meeting` | `true` | Skip if a calendar event is active or starting within `meeting_buffer_minutes` |
| `meeting_buffer_minutes` | `1` | How many minutes ahead to check for upcoming meetings |
| `grace_period_minutes` | `2` | How many minutes after prayer time the athan can still trigger (catches late wakes) |
| `timezone` | `Europe/London` | Timezone for date calculations |

## Prayer time source

Times come from [Wise Masjid High Wycombe](https://www.wise-web.org/prayer-times/) via their WordPress REST API:

```
GET https://www.wise-web.org/wp-json/my-route/PrayerTime/{year}/{month}/{day}
```

To use a different source, replace the API call in `athan.sh` and update the `prayer_field()` function to match the response schema.

## Logs

```bash
tail -f ~/.athan/logs/athan.log
```

## Sleep mode

The launchd agent won't fire while the Mac is asleep. Increase `grace_period_minutes` if you want it to catch up when the lid opens.

## Credits

Pill notification UI forked from [claude-pop](https://github.com/esc5221/claude-pop) by esc5221.  
Audio from [Aladhan CDN](https://aladhan.com).
