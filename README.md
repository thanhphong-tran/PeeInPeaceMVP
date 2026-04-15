# PeeInPeace — Shell Script MVP

> Sentry Mode for Your Laptop. Go pee in peace.

A shell script that monitors your laptop's camera for motion and sends photo alerts to your phone via Pushover when someone approaches your device.

---

## Prerequisites

- macOS (uses AVFoundation for camera access)
- [Homebrew](https://brew.sh) package manager

## Setup

### Step 1: Install ffmpeg

```bash
brew install ffmpeg
```

This is the only dependency. ffmpeg handles camera capture, frame comparison, and photo capture.

### Step 2: Grant Camera Permission to Terminal

The first time ffmpeg accesses the camera, macOS will prompt you to allow it. If you missed the prompt:

1. Open **System Settings**
2. Go to **Privacy & Security > Camera**
3. Enable **Terminal** (or whatever terminal app you use — iTerm2, Warp, etc.)

### Step 3: Set Up Pushover (for phone alerts)

Pushover delivers push notifications to your iPhone or Android.

1. **Install the Pushover app** on your phone
   - [iOS App Store](https://apps.apple.com/us/app/pushover-notifications/id506088175) — $4.99 one-time
   - [Google Play Store](https://play.google.com/store/apps/details?id=net.superblock.pushover) — $4.99 one-time
2. **Create a Pushover account** at https://pushover.net
3. **Copy your User Key** from the Pushover dashboard (top right after login)
4. **Create an Application:**
   - Go to https://pushover.net/apps/build
   - Name: `PeeInPeace`
   - Type: Script
   - Click **Create Application**
   - Copy the **API Token** it generates
5. **Export both keys** in your terminal:

```bash
export PUSHOVER_USER_KEY='your-user-key-here'
export PUSHOVER_API_TOKEN='your-api-token-here'
```

To make these persist across terminal sessions, add them to your shell profile:

```bash
echo "export PUSHOVER_USER_KEY='your-user-key-here'" >> ~/.zshrc
echo "export PUSHOVER_API_TOKEN='your-api-token-here'" >> ~/.zshrc
source ~/.zshrc
```

### Step 4: Verify Camera Works

Test that ffmpeg can access your camera:

```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep "AVFoundation video"
```

You should see your FaceTime camera listed (usually device `0`).

---

## Usage

### Basic (with Pushover alerts)

```bash
cd scripts/
./peeinpeace.sh
```

The script will:
1. Show your settings
2. Count down 10 seconds (walk away during this time)
3. Start monitoring — comparing camera frames every second
4. Send a Pushover notification with a photo if motion is detected
5. Show a warning dialog on screen

Press **Ctrl+C** to disarm and stop.

### Dry Run (no notifications, just test motion detection)

```bash
./peeinpeace.sh -n
```

Useful for testing sensitivity and verifying the camera works before setting up Pushover.

### With Audible Alarm

```bash
./peeinpeace.sh -a
```

Plays a loud alarm sound from your Mac speakers when motion is detected.

### All Options

```
./peeinpeace.sh [options]

  -s <1-100>    Motion sensitivity threshold (default: 10)
                Lower number = more sensitive (triggers on smaller movements)
                Higher number = less sensitive (only triggers on large movements)
  -c <seconds>  Cooldown between alerts (default: 30)
  -d <index>    Camera device index (default: 0)
  -a            Enable audible alarm when motion is detected
  -n            Dry run — detect motion but don't send notifications
  -h            Show help
```

---

## Examples

### High sensitivity, short cooldown (paranoid mode)

```bash
./peeinpeace.sh -s 5 -c 15
```

### Low sensitivity, alarm enabled (busy coffee shop)

```bash
./peeinpeace.sh -s 25 -a
```

### Use a different camera (e.g., external webcam)

List available cameras first:

```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep "AVFoundation video"
```

Then specify the device index:

```bash
./peeinpeace.sh -d 1
```

### Quick test with no notifications

```bash
./peeinpeace.sh -n -s 10
```

Walk in front of the camera after the countdown and watch for `MOTION DETECTED!` messages.

---

## How It Works

```
1. ARM        You run the script, 10-second countdown starts
2. CAPTURE    ffmpeg captures a frame from the camera every second
3. COMPARE    Each frame is compared to the previous using pixel differencing
              (ffmpeg blend=difference + blackframe filter)
4. DETECT     If the difference exceeds the sensitivity threshold → motion detected
5. ALERT      On detection:
              a. Captures a burst of 3 photos (saved to ./captures/)
              b. Sends the first photo to your phone via Pushover
              c. Plays audible alarm (if -a flag)
              d. Shows a warning dialog on screen
6. COOLDOWN   Waits before sending another alert (default: 30s)
7. POWER      Also monitors charger status — alerts if unplugged
8. DISARM     Press Ctrl+C to stop
```

## What Gets Triggered

| Event | Alert | Photo | Alarm | Screen Warning |
|-------|-------|-------|-------|----------------|
| Motion detected in camera | Yes | 3-photo burst | If `-a` flag | Yes |
| Charger unplugged | Yes | 3-photo burst | If `-a` flag | Yes |

---

## Captured Photos

Photos are saved to `scripts/captures/` with timestamped filenames:

```
captures/
  alert_2026-04-15_14-30-22_1.jpg
  alert_2026-04-15_14-30-22_2.jpg
  alert_2026-04-15_14-30-22_3.jpg
```

Each alert captures 3 photos over 3 seconds for the best chance of identifying who triggered it.

---

## Sensitivity Guide

| Value | Best For | False Positives |
|-------|----------|-----------------|
| 5 | Quiet library, still environment | Higher — may trigger on lighting changes |
| 10 | Coffee shop (default) | Moderate |
| 20 | Busy environment with background movement | Lower |
| 30+ | Very busy space, only detect close-up motion | Minimal |

Start with the default (`10`) and adjust based on your environment. Use `-n` (dry run) to test without sending notifications.

---

## Troubleshooting

### "ERROR: ffmpeg not found"

Install it:

```bash
brew install ffmpeg
```

### Camera not capturing (blank/no frames)

1. Check Terminal has camera permission: **System Settings > Privacy & Security > Camera**
2. Make sure no other app (Zoom, FaceTime, Photo Booth) is using the camera
3. Verify the camera device index: `ffmpeg -f avfoundation -list_devices true -i "" 2>&1`

### Pushover notifications not arriving

1. Verify your keys are exported: `echo $PUSHOVER_USER_KEY` and `echo $PUSHOVER_API_TOKEN`
2. Check the Pushover app is installed and logged in on your phone
3. Make sure your phone has internet connectivity
4. Test Pushover directly: visit https://pushover.net and use the "Send a Notification" form

### Too many false positives

Increase sensitivity threshold:

```bash
./peeinpeace.sh -s 20    # less sensitive
./peeinpeace.sh -s 30    # even less sensitive
```

### Not detecting motion

Decrease sensitivity threshold:

```bash
./peeinpeace.sh -s 5     # more sensitive
./peeinpeace.sh -s 3     # very sensitive
```

---

## Limitations

This is the MVP shell script. It works, but has limitations the real app will solve:

- **No fullscreen lock screen** — anyone can close the terminal window
- **No PIN/biometric to disarm** — just Ctrl+C
- **macOS only** — uses AVFoundation (the real app will support Windows)
- **Terminal must stay open** — can't run headlessly yet
- **No event history UI** — photos saved to disk, no browsable log
- **Camera green LED is always on** — this is actually a feature (deterrent), but some may find it obvious
