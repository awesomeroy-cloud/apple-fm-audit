# apple-fm-audit

Unofficial reverse proxy that records HTTP traffic to Apple's on-device Foundation Model (`fm serve`) and shows it in a local web page. Request and response bodies are stored in SQLite.

This project is not affiliated with Apple.

## What it does

Clients talk to **apple-fm-audit**. The process forwards each call to `fm serve` (or another OpenAI-compatible origin), writes a row to SQLite, and serves an audit UI at `/`.

Chat Completions bodies are forwarded unchanged. `POST /v1/responses` is translated to `POST /v1/chat/completions` because `fm serve` has no Responses API. `Origin`, `Referer`, and `Sec-Fetch-*` are dropped so a browser can call `fm serve` without CSRF 403.

## Run with the script

Built natively in Swift with Hummingbird 2 and SwiftNIO. Requires macOS 14+ (Apple Silicon) and `fm serve` on the upstream port. First use of `fm` on a Mac requires agreeing to Apple's terms yourself:

```bash
sudo fm license
fm serve
./run.sh
```

`./run.sh` builds the release binary and checks `fm license --status`. It does not type `yes` for you. If terms are not agreed, it prints the notice, still starts the UI, and the page shows the same text until you finish `sudo fm license`.

Open [http://127.0.0.1:1977](http://127.0.0.1:1977). Point the client at the same origin:

API provider fields:

- Base URL: `http://127.0.0.1:1977/v1`
- API key: any non-empty string
- Model: `system`
- Wire API: Chat Completions or Responses (both work)

`model: "pcc"` uses Private Cloud Compute when `fm serve` lists it (macOS 27.2). If PCC is missing, not eligible, not ready, or the request fails because the network is down, the proxy retries with on-device `system` and sets `X-Apple-FM-Fallback`.

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:1977/v1", api_key="not-checked")
client.chat.completions.create(
    model="system",
    messages=[{"role": "user", "content": "Hello"}],
)
```

## Run at login (macOS LaunchAgent)

Installs two user agents: `fm serve` on `127.0.0.1:1976` and apple-fm-audit on `127.0.0.1:1977`. They start at login and restart if they exit. On macOS 27.2, `fm serve` is launched through `Terminal.app` in the background via `run-fm-serve.sh` to satisfy PCC `ParentProcessGate` requirements.

```bash
./install-service.sh
./install-service.sh --lan    # bind 0.0.0.0:1977 for other machines on the LAN
./uninstall-service.sh
```

`--lan` keeps `fm serve` on `127.0.0.1:1976`. Other devices use `http://<this-mac-lan-ip>:1977/v1`. There is no auth. macOS Firewall may ask to allow incoming Python.

Logs: `~/Library/Logs/org.apple-fm-audit.fm-serve.log` and `~/Library/Logs/org.apple-fm-audit.proxy.log`.

## Apple Shortcuts (快捷指令)

Pre-built and signed `.shortcut` files are provided in [`shortcuts/`](shortcuts/):
- **AFM 智能问答**: Interactive dialog prompt with clipboard copy and dialog output.
- **AFM 划词总结**: macOS Quick Action / Services menu for summarizing or polishing selected text.
- **AFM 私有云问答 (PCC)**: Routes prompts through Private Cloud Compute.
- **AFM 极速问答 (Shell)**: macOS native shell execution via `scripts/afm-ask`.

Import directly via:
```bash
open "shortcuts/AFM 智能问答.shortcut"
open "shortcuts/AFM 划词总结.shortcut"
```

Standalone CLI helper:
```bash
./scripts/afm-ask "Explain quantum computing in one sentence"
```
See [shortcuts/README.md](shortcuts/README.md) for full configuration and iOS setup.

## OpenAI-Compatible Text-to-Speech (`POST /v1/audio/speech`)

Synthesizes speech directly using macOS native `AVSpeechSynthesizer` and CoreAudio encoders with zero third-party dependencies.

```bash
curl -X POST http://127.0.0.1:1977/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "input": "Apple Foundation Models native proxy audio synthesis.",
    "voice": "shimmer",
    "speed": 1.0,
    "pitch": 1.0,
    "response_format": "wav"
  }' \
  --output speech.wav
```

### Supported TTS Parameters
- `voice`: OpenAI aliases automatically mapped to installed macOS Premium Neural voices:
  - `shimmer` -> `com.apple.voice.premium.zh-CN.Lilian` (Mandarin Female)
  - `alloy` -> `com.apple.voice.premium.en-US.Zoe` (English Female)
  - `echo` -> `com.apple.voice.premium.zh-CN.Yun` (Mandarin Male)
  - `fable` -> `com.apple.voice.premium.zh-CN.Lili` (Mandarin Female)
  - `onyx` -> `com.apple.voice.premium.zh-CN.Yue` (Mandarin Male)
  - `nova` -> `com.apple.voice.premium.zh-TW.Meijia` (Taiwanese Mandarin)
  - Also accepts system voice identifiers (e.g. `com.apple.voice.premium.zh-CN.Lilian`) or system voice names (`Lilian`, `Zoe`, `Tingting`).
- `speed`: Multiplier on standard speech rate (`0.25` - `4.0`).
- `pitch` / `pitch_multiplier`: Fundamental frequency multiplier (`0.5` - `2.0`).
- `volume`: Amplitude multiplier (`0.0` - `1.0`).
- `language`: BCP-47 language tag (e.g. `zh-CN`, `en-US`, `ja-JP`).
- `response_format`: `wav` (22.05kHz 32-bit float PCM), `aac` / `m4a`, `flac` (lossless), `opus` (CAF container), `caf`, `pcm`. (`mp3` returns HTTP 400 due to absence of native CoreAudio MP3 encoder).

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `AFM_LISTEN_HOST` | `127.0.0.1` | Bind address |
| `AFM_LISTEN_PORT` | `1977` | Port for UI and proxy |
| `AFM_UPSTREAM` | `127.0.0.1:1976` | `fm serve` (or any HTTP origin) |
| `AFM_DB` | `data/audit.sqlite` | SQLite file |
| `AFM_FM_BIN` | `fm` | Path to the `fm` binary for the license check |

## Local routes (not proxied)
 
- `GET /` audit page
- `GET /_audit/calls` list
- `GET /_audit/calls/:id` one call
- `DELETE /_audit/calls` wipe the log
- `GET /_audit/meta` listen/upstream
- `GET /_audit/license` `fm license --status` / `--show` (never auto-agrees)
- `GET /_audit/status` license plus `GET /health` model availability
- `GET /_audit/quota` PCC usage limits and reset date (`resets_at`)
- `POST /v1/audio/speech` native macOS text-to-speech synthesis (OpenAI-compatible)
 
Everything else, including `/v1/chat/completions`, `/responses`, `/v1/responses`, and `/health`, goes upstream.
 
## Tests
 
```bash
swift test
```
 
## Documentation
 
See [docs/foundation_models.md](docs/foundation_models.md) for extracted Apple Foundation Models framework technical specifications.
 
## License
 
MIT.
