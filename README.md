# Local TTS

A native macOS text-to-speech reader prototype for Apple Silicon, targeting macOS 15.7.5 and newer.

## Current State

- SwiftUI macOS app with a menu bar extra.
- Global shortcut capture, defaulting to Option-Space.
- Selected text capture through macOS Accessibility APIs, with clipboard fallback.
- Long-text normalization, paragraph-aware chunking, and background synthesis queue.
- Engine abstraction for Kokoro ONNX now and MLX/Qwen later.
- Kokoro model asset layout under `~/Library/Application Support/LocalTTS/Models`.
- In-app Kokoro asset download from `onnx-community/Kokoro-82M-v1.0-ONNX`.
- Kokoro ONNX synthesis with the vendored MisakiSwift Kokoro English G2P frontend.

When Kokoro assets are installed, synthesis uses the local ONNX model. If assets are missing, the app falls back to the local macOS speech renderer so the UI remains usable before download.

## Run

```sh
swift run LocalTTS
```

On first use, grant Accessibility permission so the app can read selected text from the focused app. If selected text is unavailable, the app reads the clipboard.

Use the main window to download Kokoro assets, change the global shortcut, enable or disable the shortcut, select voice/speed, and adjust idle unload behavior.

`Scripts/build-app.sh` builds the SwiftPM executable and packages the app resources, including the MisakiSwift G2P resources.

## Build App Bundle

```sh
bash Scripts/build-app.sh
```

The bundle is written to `.build/release/LocalTTS.app`.

## Test

```sh
swift run LocalTTSTestRunner
```

This repository uses a lightweight executable test runner because the current Command Line Tools installation in this workspace does not expose `XCTest` or Swift `Testing`.

The Kokoro frontend tests compare Swift output against checked-in goldens generated from the reference Python `misaki` package. Python is not used by the app or by normal test runs. To refresh those goldens during development:

```sh
python3.12 -m venv /tmp/local-tts-misaki-venv
/tmp/local-tts-misaki-venv/bin/python -m pip install "misaki[en]==0.9.4"
/tmp/local-tts-misaki-venv/bin/python Scripts/generate-kokoro-frontend-goldens.py
```

## Expected Kokoro Asset Layout

```text
~/Library/Application Support/LocalTTS/Models/Kokoro-82M-v1.0-ONNX/
  config.json
  tokenizer.json
  onnx/
    model_q8f16.onnx
  voices/
    af_heart.bin
    af_bella.bin
    am_adam.bin
```
