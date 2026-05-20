# Auto-Trim Wake Word Recordings on Home Assistant

## Goal

Modify an existing Home Assistant setup so that wake-word training recordings are automatically trimmed to a 1.5-second clip centered on the loudest moment of the audio, at 16 kHz mono. These trimmed clips will feed directly into a microWakeWord trainer's `personal_samples/` folder for retraining a custom wake word model on the Home Assistant Voice Preview Edition (Voice PE).

## Current state of the system

The following is **already configured and working** on the Home Assistant OS instance. Do not re-create these — only modify where indicated.

### Existing `configuration.yaml` entries

```yaml
assist_pipeline:
  debug_recording_dir: /share/assist_pipeline

shell_command:
  capture_wake_sample: "bash -c 'mkdir -p /share/wake_samples && sleep 1 && latest=$(ls -t /share/assist_pipeline/*/*/*/01_stt*.wav 2>/dev/null | head -1) && [ -n \"$latest\" ] && cp \"$latest\" \"/share/wake_samples/wake_$(date +%Y%m%d_%H%M%S).wav\" && rm -rf /share/assist_pipeline/*'"
```

### Existing script (`scripts.yaml` / Settings → Scripts)

Name: **Record wake word sample** (entity_id: `script.record_wake_word_sample`)

```yaml
alias: Record wake word sample
sequence:
  - action: assist_satellite.ask_question
    continue_on_error: true
    data:
      entity_id: assist_satellite.home_assistant_voice_0a96dc_assist_satellite
      question: "Go"
      answers:
        - id: sample
          sentences:
            - "go"
            - "stop"
            - "yes"
            - "no"
    response_variable: answer
  - action: shell_command.capture_wake_sample
mode: single
```

### How it currently flows

1. User taps a dashboard button → runs the script
2. Voice PE plays a chime + "Go" prompt → starts listening
3. User speaks the wake phrase
4. Pipeline closes, debug recorder writes a WAV to `/share/assist_pipeline/<run_id>/<device>/<id>/01_stt-stt.home_assistant_cloud.wav`
5. `shell_command.capture_wake_sample` copies the newest file to `/share/wake_samples/wake_YYYYMMDD_HHMMSS.wav` and wipes the debug folder
6. **Currently the copied file is the raw, untrimmed audio (typically 2–4 seconds with leading/trailing silence)**

## What needs to change

Replace the simple `cp` step in the shell command with a call to a trimming script that produces a 1.5-second 16 kHz mono WAV centered on the loudest moment of the source audio. The output filename and destination folder stay the same (`/share/wake_samples/wake_YYYYMMDD_HHMMSS.wav`).

## Implementation steps

### Step 1: Install ffmpeg in the SSH add-on environment

Use the **Advanced SSH & Web Terminal** add-on (already installed on this system). Open its terminal and run:

```bash
apk add ffmpeg
```

**Verify ffmpeg persists across HA restarts.** Restart Home Assistant once (Settings → System → Restart), then SSH back in and run `which ffmpeg`. If it's gone, packages are not persisting and we need a different approach (see "Fallback" section at the bottom).

### Step 2: Create the trim script at `/config/trim_wake.sh`

```bash
#!/bin/bash
# trim_wake.sh — trims a wake-word recording to a 1.5s clip
# centered on the loudest moment, at 16 kHz mono.
#
# Usage: trim_wake.sh <input.wav> <output.wav>

set -e

INPUT="$1"
OUTPUT="$2"

if [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
  echo "Usage: $0 <input.wav> <output.wav>" >&2
  exit 1
fi

if [ ! -f "$INPUT" ]; then
  echo "Input file not found: $INPUT" >&2
  exit 1
fi

# Detect the loudest moment in the file by sampling RMS levels every 100ms.
# Use ffmpeg's astats filter with metadata output, parsed via awk.
PEAK_TIME=$(ffmpeg -hide_banner -nostats -i "$INPUT" \
  -af "astats=metadata=1:reset=1:length=0.1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-" \
  -f null - 2>/dev/null \
  | awk '
      # Handles both old form "pts_time=0.1" and new form
      # "frame:N pts:M pts_time:0.1" (ffmpeg >= 7.x).
      /pts_time[=:]/ {
        s = $0
        sub(/.*pts_time[=:]/, "", s)
        sub(/[^0-9.].*$/, "", s)
        if (s != "") t = s
      }
      /RMS_level/ {
        split($1, a, "=");
        rms = a[2];
        if (rms != "-inf" && (best == "" || rms > best)) {
          best = rms;
          best_t = t;
        }
      }
      END { print best_t }
    ')

# Fallback: if peak detection failed, use the middle of the file
if [ -z "$PEAK_TIME" ]; then
  DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT")
  PEAK_TIME=$(awk -v d="$DURATION" 'BEGIN { print d / 2 }')
fi

# Compute start time = peak - 0.75s, clamped to 0
START=$(awk -v t="$PEAK_TIME" 'BEGIN { s = t - 0.75; if (s < 0) s = 0; print s }')

# Crop to a 1.5s window starting at START, force 16 kHz mono PCM 16-bit
ffmpeg -hide_banner -loglevel error -y \
  -ss "$START" -t 1.5 \
  -i "$INPUT" \
  -ar 16000 -ac 1 -sample_fmt s16 \
  "$OUTPUT"

# Verify output was created and is non-empty
if [ ! -s "$OUTPUT" ]; then
  echo "Output file was not created: $OUTPUT" >&2
  exit 1
fi
```

Make it executable:

```bash
chmod +x /config/trim_wake.sh
```

### Step 3: Test the trim script in isolation

Before wiring it into Home Assistant, run a sample through it manually. Trigger one recording via the existing script in the HA UI, then SSH in and:

```bash
# Find the most recent untrimmed sample
SAMPLE=$(ls -t /share/wake_samples/wake_*.wav | head -1)
echo "Testing with: $SAMPLE"

# Run the trim script, output to /tmp for comparison
/config/trim_wake.sh "$SAMPLE" /tmp/trimmed_test.wav

# Compare durations
ffprobe -v error -show_entries format=duration -of csv=p=0 "$SAMPLE"
ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/trimmed_test.wav
```

The second duration should print `1.500000` (or very close). The first will likely be 2–4 seconds.

You can also play `/tmp/trimmed_test.wav` (download via the Samba share or `scp` it out) and confirm the wake phrase is audible and roughly centered.

### Step 4: Update the shell command in `configuration.yaml`

Replace the existing `shell_command:` block with:

```yaml
shell_command:
  capture_wake_sample: "bash -c 'mkdir -p /share/wake_samples && sleep 1 && latest=$(ls -t /share/assist_pipeline/*/*/*/01_stt*.wav 2>/dev/null | head -1) && [ -n \"$latest\" ] && /config/trim_wake.sh \"$latest\" \"/share/wake_samples/wake_$(date +%Y%m%d_%H%M%S).wav\" && rm -rf /share/assist_pipeline/*'"
```

The only difference from the current shell command is `cp "$latest" "..."` is replaced with `/config/trim_wake.sh "$latest" "..."`.

### Step 5: Validate and restart

1. **Developer Tools → YAML → Check Configuration** — confirm it's green
2. **Settings → System → Restart Home Assistant** (full restart, not Quick Reload — `shell_command` definitions only reload on full restart)
3. Wait ~30 seconds for HA to come back online

### Step 6: End-to-end verification

1. From the HA UI, tap the "Record wake word sample" button
2. Wait for the chime + "Go" prompt, say a test wake phrase, wait for the listening LED to stop
3. SSH in and check:

```bash
ls -lt /share/wake_samples/ | head -5
ffprobe -v error -show_entries format=duration -of csv=p=0 /share/wake_samples/$(ls -t /share/wake_samples/ | head -1)
```

The newest file should be ~1.5 seconds. Also verify the file is non-empty (size > 40 KB for 16 kHz mono 16-bit PCM at 1.5s).

If the file is missing or empty, check the script trace in Home Assistant (Settings → Automations & Scripts → Scripts → Record wake word sample → ⋮ → Traces → most recent run) and look at the return code of the `shell_command.capture_wake_sample` step.

## Important constraints / gotchas

- **Input filename pattern**: The debug-pipeline file is named `01_stt-stt.home_assistant_cloud.wav` on this system (the suffix reflects the STT engine). The glob `01_stt*.wav` handles this. Do not change the glob to require an exact name.
- **Directory depth**: Recordings are nested 3 levels deep under `/share/assist_pipeline/`: `<run_id>/<device_name>/<numeric_id>/01_stt*.wav`. The glob `*/*/*/01_stt*.wav` reflects this.
- **The `rm -rf /share/assist_pipeline/*`** at the end of the shell command is intentional — it ensures the next run's "latest" file is unambiguous. Do not remove this.
- **`continue_on_error: true`** on the ask_question action is intentional. STT may or may not match the answers list, but the WAV is always written to the debug folder regardless. The script must continue to the shell_command step either way.
- **Quoting**: The shell command is a single YAML string. Inner quotes must be escaped with `\"`. If you reformat the YAML, preserve the escaping.

## Fallback if `apk add ffmpeg` doesn't persist

On Home Assistant OS, packages installed via `apk` inside the SSH add-on container may be wiped on add-on restart. If `which ffmpeg` returns nothing after a HA restart:

**Option A**: Modify the SSH add-on's `init_commands` or `packages` config (Settings → Add-ons → Advanced SSH & Web Terminal → Configuration tab) to install ffmpeg at add-on start. The Advanced SSH add-on supports an `init_commands:` list — add `- apk add ffmpeg` there.

**Option B**: Skip on-device trimming entirely. The user's stated alternative is to collect raw samples now and batch-trim them on a desktop in Audacity (Effect → Truncate Silence, applied via Macro). This is the fallback the user is okay with if on-device trimming proves fragile.

## Final deliverable for the user

When complete, confirm to the user:

1. `/config/trim_wake.sh` exists and is executable
2. `configuration.yaml` has the updated `shell_command` block calling the trim script
3. A test run of the "Record wake word sample" script produces a ~1.5s WAV in `/share/wake_samples/`
4. The wake phrase is audible and roughly centered when the trimmed file is played back

The user can then collect 30–50 samples (varying distance, room position, background noise, voice level), download the contents of `/share/wake_samples/` via the Samba add-on, and drop the WAVs into the microWakeWord trainer's `personal_samples/` folder for retraining.
