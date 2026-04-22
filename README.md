# VTT – Video to Text Transcriber

A macOS app that transcribes video files to text using [OpenAI Whisper](https://github.com/openai/whisper). Drop a video, pick a language and model, and get a clean transcript plus an `.srt` subtitle file — all processed locally, nothing sent to the cloud.

![App screenshot](docs/screenshot.png)

## Features

- Drag & drop or browse for any video format (mp4, mov, mkv, webm…)
- Outputs plain text transcript with smart paragraph breaks
- Outputs `.srt` subtitle file
- Copy transcript to clipboard in one click
- Optional context hint to improve accuracy for proper nouns / domain terms
- Optional filler word removal (um, uh, äh…)
- Live progress bar with time remaining
- First-run setup wizard installs missing dependencies automatically

## Requirements

- macOS 13 or later
- [Homebrew](https://brew.sh) (the app guides you through installing it on first launch)
- ffmpeg and openai-whisper — installed automatically by the app if missing

## Build & Run

```bash
git clone https://github.com/YOUR_USERNAME/TranscribeApp.git
cd TranscribeApp
./run.sh
```

`run.sh` builds the app, syncs the binary into the `.app` bundle, and opens it.

## Models

| Model  | Speed (CPU) | Accuracy |
|--------|-------------|----------|
| tiny   | ~1× realtime | Basic |
| base   | ~2× realtime | Good |
| small  | ~4× realtime | Better |
| medium | ~8× realtime | Best (recommended) |

`medium` is set as the default and gives the best quality without requiring a GPU.

## How It Works

1. **ffmpeg** converts the video to a 16kHz mono WAV with loudness normalisation and a 100Hz highpass filter to remove low-frequency noise
2. **Whisper** transcribes the WAV to an `.srt` file, with `--condition_on_previous_text False` to reduce hallucination loops
3. The app post-processes the SRT into clean paragraphed plain text, removing consecutive duplicate segments

## License

MIT
