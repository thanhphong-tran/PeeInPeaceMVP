#!/bin/bash
#
# PeeInPeace MVP — Sentry Mode for Your Laptop
#
# Detects motion via your Mac's camera and sends a photo alert
# to your phone via Pushover.
#
# Dependencies: ffmpeg (brew install ffmpeg)
# Setup: Install Pushover app on your phone ($4.99), then set
#        PUSHOVER_USER_KEY and PUSHOVER_API_TOKEN below.
#
# Usage: ./peeinpeace.sh [options]
#   -s <sensitivity>  Motion sensitivity 1-100 (default: 10)
#   -c <cooldown>     Seconds between alerts (default: 30)
#   -d <device>       Camera device index (default: 0)
#   -a                Enable audible alarm on trigger
#   -n                Dry run — no Pushover notifications
#   -h                Show help

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────
# Pushover credentials — get these from https://pushover.net
PUSHOVER_USER_KEY="${PUSHOVER_USER_KEY:-}"
PUSHOVER_API_TOKEN="${PUSHOVER_API_TOKEN:-}"

# Defaults
SENSITIVITY=10          # Pixel difference threshold (1=very sensitive, 100=very insensitive)
COOLDOWN=30             # Seconds between alerts
CAMERA_DEVICE=0         # FaceTime HD Camera
ARM_DELAY=10            # Seconds before monitoring starts
DRY_RUN=false           # Skip Pushover notifications
ALARM=false             # Play audible alarm on trigger
FRAME_INTERVAL=1        # Seconds between frame captures

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="/tmp/peeinpeace"
CAPTURES_DIR="$SCRIPT_DIR/captures"

# ─── Parse Arguments ────────────────────────────────────────────
usage() {
    echo "PeeInPeace MVP — Sentry Mode for Your Laptop"
    echo ""
    echo "Usage: ./peeinpeace.sh [options]"
    echo "  -s <1-100>    Motion sensitivity threshold (default: $SENSITIVITY)"
    echo "                Lower = more sensitive, Higher = less sensitive"
    echo "  -c <seconds>  Cooldown between alerts (default: $COOLDOWN)"
    echo "  -d <index>    Camera device index (default: $CAMERA_DEVICE)"
    echo "  -a            Enable audible alarm when motion is detected"
    echo "  -n            Dry run — detect motion but don't send notifications"
    echo "  -h            Show this help"
    echo ""
    echo "Environment variables:"
    echo "  PUSHOVER_USER_KEY   Your Pushover user key"
    echo "  PUSHOVER_API_TOKEN  Your Pushover application API token"
    echo ""
    echo "Press Ctrl+C to disarm."
    exit 0
}

while getopts "s:c:d:anh" opt; do
    case $opt in
        s) SENSITIVITY="$OPTARG" ;;
        c) COOLDOWN="$OPTARG" ;;
        d) CAMERA_DEVICE="$OPTARG" ;;
        a) ALARM=true ;;
        n) DRY_RUN=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ─── Validate ───────────────────────────────────────────────────
if [[ "$DRY_RUN" == false && (-z "$PUSHOVER_USER_KEY" || -z "$PUSHOVER_API_TOKEN") ]]; then
    echo "ERROR: Pushover credentials not set."
    echo ""
    echo "Option 1: Export environment variables:"
    echo "  export PUSHOVER_USER_KEY='your-user-key'"
    echo "  export PUSHOVER_API_TOKEN='your-api-token'"
    echo ""
    echo "Option 2: Run in dry-run mode (no notifications):"
    echo "  ./peeinpeace.sh -n"
    echo ""
    echo "Get your keys at https://pushover.net"
    exit 1
fi

if ! command -v ffmpeg &>/dev/null; then
    echo "ERROR: ffmpeg not found. Install it with: brew install ffmpeg"
    exit 1
fi

# ─── Setup ──────────────────────────────────────────────────────
mkdir -p "$WORK_DIR" "$CAPTURES_DIR"

# Cleanup on exit
cleanup() {
    echo ""
    echo "[PeeInPeace] Disarmed. Cleaning up..."
    # Kill any background ffmpeg processes we started
    if [[ -n "${FFMPEG_PID:-}" ]] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        kill "$FFMPEG_PID" 2>/dev/null || true
        wait "$FFMPEG_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
    echo "[PeeInPeace] Stopped. Captured photos saved in: $CAPTURES_DIR"
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# ─── Functions ──────────────────────────────────────────────────

capture_frame() {
    local output_path="$1"
    ffmpeg -f avfoundation -framerate 30 -video_size 1280x720 \
        -i "$CAMERA_DEVICE" -frames:v 1 -y \
        -loglevel quiet "$output_path" 2>/dev/null
}

# Compare two images and return the mean pixel difference.
# Uses ffmpeg to compute PSNR — lower PSNR means bigger difference.
# We convert this to a simple 0-100 difference score.
compare_frames() {
    local frame_a="$1"
    local frame_b="$2"

    # Compute difference between frames using blend=difference, then use
    # blackframe to measure what percentage of the diff image is "black"
    # (i.e., unchanged). threshold=32 ignores minor noise (camera jitter,
    # lighting fluctuation). pblack=100 means identical, pblack=0 means
    # completely different. We invert: motion_score = 100 - pblack.
    local diff_value
    diff_value=$(ffmpeg -i "$frame_a" -i "$frame_b" \
        -filter_complex "blend=all_mode=difference,blackframe=amount=0:threshold=32" \
        -f null - 2>&1 | grep -o "pblack:[0-9]*" | tail -1 | grep -o "[0-9]*" || echo "100")

    local motion_score=$((100 - diff_value))
    echo "$motion_score"
}

send_alert() {
    local photo_path="$1"
    local timestamp="$2"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[PeeInPeace] DRY RUN — would send notification with photo: $photo_path"
        return 0
    fi

    # Send Pushover notification with photo attachment
    local response
    response=$(curl -s \
        -F "token=$PUSHOVER_API_TOKEN" \
        -F "user=$PUSHOVER_USER_KEY" \
        -F "message=Motion detected at $timestamp" \
        -F "title=PeeInPeace Alert" \
        -F "priority=1" \
        -F "sound=siren" \
        -F "attachment=@$photo_path" \
        "https://api.pushover.net/1/messages.json" 2>/dev/null)

    if echo "$response" | grep -q '"status":1'; then
        echo "[PeeInPeace] Alert sent to your phone!"
    else
        echo "[PeeInPeace] WARNING: Failed to send notification. Response: $response"
    fi
}

play_alarm() {
    if [[ "$ALARM" == true ]]; then
        # Play system alert sound repeatedly for 5 seconds
        for _ in 1 2 3 4 5; do
            afplay /System/Library/Sounds/Sosumi.aiff &
            sleep 1
        done
    fi
}

show_screen_warning() {
    # Display a full-screen warning using osascript
    osascript -e 'display dialog "⚠️ THIS DEVICE IS BEING MONITORED.\nThe owner has been notified." buttons {"OK"} default button "OK" with title "PeeInPeace Alert" with icon caution giving up after 30' &>/dev/null &
}

capture_burst() {
    local timestamp="$1"
    local safe_ts
    safe_ts=$(echo "$timestamp" | tr ' :' '_-')

    echo "[PeeInPeace] Capturing photo burst..."
    local photos=()
    for i in 1 2 3; do
        local photo_path="$CAPTURES_DIR/alert_${safe_ts}_${i}.jpg"
        capture_frame "$photo_path"
        photos+=("$photo_path")
        if [[ $i -lt 3 ]]; then
            sleep 1
        fi
    done

    # Send the first photo as the alert
    send_alert "${photos[0]}" "$timestamp"
    play_alarm
    show_screen_warning
    echo "[PeeInPeace] 3 photos saved to $CAPTURES_DIR"
}

# ─── Arm Countdown ──────────────────────────────────────────────
echo ""
echo "  PeeInPeace — Sentry Mode"
echo "  ========================"
echo ""
echo "  Sensitivity : $SENSITIVITY (lower = more sensitive)"
echo "  Cooldown    : ${COOLDOWN}s between alerts"
echo "  Camera      : Device $CAMERA_DEVICE"
echo "  Alarm       : $ALARM"
echo "  Dry run     : $DRY_RUN"
echo "  Captures    : $CAPTURES_DIR"
echo ""
echo "  Press Ctrl+C to disarm."
echo ""

# Countdown
for i in $(seq "$ARM_DELAY" -1 1); do
    printf "\r[PeeInPeace] Arming in %d seconds... Walk away now!" "$i"
    sleep 1
done
echo ""
echo "[PeeInPeace] ARMED. Monitoring started at $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ─── Power Monitoring ──────────────────────────────────────────

check_power_status() {
    # Returns "AC" if plugged in, "Battery" if on battery
    pmset -g batt | grep -q "AC Power" && echo "AC" || echo "Battery"
}

INITIAL_POWER=$(check_power_status)
echo "[PeeInPeace] Power source: $INITIAL_POWER"

# ─── Main Monitoring Loop ──────────────────────────────────────
LAST_ALERT_TIME=0

# Capture the initial reference frame
capture_frame "$WORK_DIR/frame_prev.jpg"

while true; do
    sleep "$FRAME_INTERVAL"

    # Check for power disconnect
    current_power=$(check_power_status)
    if [[ "$INITIAL_POWER" == "AC" && "$current_power" == "Battery" ]]; then
        current_time=$(date +%s)
        time_since_last=$((current_time - LAST_ALERT_TIME))
        if [[ "$time_since_last" -ge "$COOLDOWN" ]]; then
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            echo ""
            echo "[PeeInPeace] POWER DISCONNECTED! Charger was unplugged."
            capture_burst "$timestamp"
            LAST_ALERT_TIME=$current_time
        fi
        INITIAL_POWER="$current_power"
    elif [[ "$INITIAL_POWER" != "$current_power" ]]; then
        INITIAL_POWER="$current_power"
    fi

    # Capture current frame
    capture_frame "$WORK_DIR/frame_curr.jpg"

    # Compare with previous frame
    motion_score=$(compare_frames "$WORK_DIR/frame_prev.jpg" "$WORK_DIR/frame_curr.jpg")

    # Check if motion exceeds threshold
    if [[ "$motion_score" -gt "$SENSITIVITY" ]]; then
        current_time=$(date +%s)
        time_since_last=$((current_time - LAST_ALERT_TIME))

        if [[ "$time_since_last" -ge "$COOLDOWN" ]]; then
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            echo ""
            echo "[PeeInPeace] MOTION DETECTED! (score: $motion_score, threshold: $SENSITIVITY)"
            capture_burst "$timestamp"
            LAST_ALERT_TIME=$current_time
        else
            remaining=$((COOLDOWN - time_since_last))
            echo "[PeeInPeace] Motion detected (score: $motion_score) — cooldown active (${remaining}s remaining)"
        fi
    else
        printf "\r[PeeInPeace] Watching... (motion: %d, threshold: %d)  " "$motion_score" "$SENSITIVITY"
    fi

    # Current frame becomes the previous frame
    mv "$WORK_DIR/frame_curr.jpg" "$WORK_DIR/frame_prev.jpg"
done
