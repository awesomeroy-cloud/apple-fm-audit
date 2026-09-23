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

## API Methods & Endpoints

### Inference & Audio Endpoints

| Method | Path | Upstream / Handling | Wire Protocol & Description |
|---|---|---|---|
| `POST` | `/v1/chat/completions` | Proxied to `fm serve` (`127.0.0.1:1976`) | OpenAI Chat Completions. Supports text generation, streaming SSE, tool calling, and inlined base64 images. Automatically falls back from `pcc` to on-device `system` on network or quota failure. |
| `POST` | `/responses` | Gateway Translation | OpenAI Responses API. Translates incoming Responses requests to upstream Chat Completions, and translates streaming completions back into Responses SSE events (`response.created`, `response.output_text.delta`, `response.output_item.done`, `response.completed`). |
| `POST` | `/v1/responses` | Gateway Translation | Alias for `/responses` with `/v1` prefix. |
| `POST` | `/v1/audio/speech` | Local Native Engine | OpenAI-compatible text-to-speech. Synthesizes speech via macOS `AVSpeechSynthesizer` with automatic mapping to installed macOS Premium neural voices. Encodes via CoreAudio (`afconvert`). |
| `GET` | `/v1/models` | Proxied to `fm serve` | Lists active models (`system`, `pcc`). |
| `GET` | `/health` | Proxied to `fm serve` | Checks upstream process status, model availability, and quota states. |

### Audit & System Endpoints

| Method | Path | Upstream / Handling | Description |
|---|---|---|---|
| `GET` | `/` | Local Static Handler | Audit web UI dashboard. |
| `GET` | `/app.css`, `/app.js`, `/favicon.svg` | Local Static Handler | Static dashboard assets. |
| `GET` | `/_audit/status` | Local Handler | Aggregate status of license verification and upstream model availability. |
| `GET` | `/_audit/meta` | Local Handler | Returns JSON containing listener address, upstream target address, and SQLite database path. |
| `GET` | `/_audit/license` | Local Handler | Runs `fm license --status` and returns license agreement status. Never auto-agrees. |
| `GET` | `/_audit/quota` | Local Handler | Inspects Private Cloud Compute quota limits (`limit_reached`, `approaching_limit`) and reset timestamp (`resets_at`). |
| `GET` | `/_audit/calls` | Local Handler | Queries stored call records from SQLite. Supports query string filter `?q=<path_substring>`. |
| `GET` | `/_audit/calls/:id` | Local Handler | Returns full details (request headers, request body, response headers, response body, latency, status code) for a specific call ID. |
| `DELETE` | `/_audit/calls` | Local Handler | Purges all call records from SQLite. |

---

## Supported File & Data Formats

### 1. Multimodal Input Formats (Chat Completions & Responses)

| Format / Scheme | Support Status | Request Syntax | Specifications & Constraints |
|---|---|---|---|
| **Base64 Inlined Images** | Supported | `data:image/<type>;base64,<data>` | Accepted MIME types: `image/jpeg`, `image/png`, `image/webp`, `image/gif`. Supports multiple images per request (tested up to 2 images concurrently). Request body limit: 10MB. |
| **Remote Image URLs** | Rejected (HTTP 400) | `https://...` | Rejected by upstream `fm serve`: `image_url must be inlined as 'data:image/<type>;base64,<bytes>'; got 'https'`. |
| **Local File URLs** | Rejected (HTTP 400) | `file://...` | Rejected by upstream `fm serve`: `image_url must be inlined as 'data:image/<type>;base64,<bytes>'; got 'file'`. |
| **Documents (PDF / DOCX / TXT)** | Rejected (HTTP 400) | `application/pdf`, etc. | Rejected: `Invalid JSON: The data couldn't be read because it isn't in the correct format`. Upstream model does not accept raw document binary streams. |
| **Audio Input** | Rejected (HTTP 400) | `input_audio` | Rejected: `Invalid JSON: The data couldn't be read because it isn't in the correct format`. Audio input is not exposed by `fm serve`. |

### 2. Audio Output Formats (`POST /v1/audio/speech`)

| Format | Container & Codec | MIME Type | Size Ratio (vs WAV) | Latency & Performance Cost |
|---|---|---|---|---|
| `wav` | RIFF Container, 22.05kHz 32-bit Float PCM | `audio/wav` | 100% (Baseline, ~294 KB / 3s) | Direct synthesis buffer dump. Incurs 0ms conversion overhead. |
| `aac` / `m4a` | MPEG-4 Container (`.m4a`), AAC Codec | `audio/aac` | ~5.8% (94% compression, ~17 KB / 3s) | Encoded via `/usr/bin/afconvert` (`-f m4af -d aac`). Incurs 10-25ms process execution overhead. |
| `flac` | Native FLAC Container, Lossless Codec | `audio/flac` | ~27.5% (72% compression, ~81 KB / 3s) | Bit-perfect lossless compression via `/usr/bin/afconvert` (`-f flac -d flac`). Incurs 15-30ms process execution overhead. |
| `opus` | CoreAudio CAF Container (`.caf`), Opus Codec | `audio/opus` | ~5.1% (95% compression, ~15 KB / 3s) | Encoded via `/usr/bin/afconvert` (`-f caff -d opus`). Incurs 10-25ms process execution overhead. |
| `caf` | CoreAudio CAF Container (`.caf`), AAC Codec | `audio/x-caf` | ~5.8% (94% compression, ~17 KB / 3s) | Native Apple audio container format. Incurs 10-20ms process execution overhead. |
| `pcm` | Headerless 32-bit Float Linear PCM Stream | `audio/pcm` | ~98% (~290 KB / 3s) | Direct extraction from `AVAudioPCMBuffer.floatChannelData`. Incurs 0ms conversion overhead. |
| `mp3` | MPEG-1 Audio Layer III | N/A | Unsupported (HTTP 400) | Rejected: macOS native CoreAudio encoder lacks MP3 write support. |

### 3. Structured Output Formats

| Format | Support Status | Request Specification | Behavioral Outcome |
|---|---|---|---|
| `json_schema` | Supported | `response_format: {"type": "json_schema", "json_schema": {"schema": {...}}}` | Constrains model token sampling to output strictly adhering to JSON schema. |
| `json_object` | Rejected (HTTP 400) | `response_format: {"type": "json_object"}` | Rejected by upstream `fm serve`: `response_format type 'json_object' is not supported. Use 'json_schema' instead.`. |
 
## Tests
 
```bash
swift test
```
 
## Documentation
 
See [docs/foundation_models.md](docs/foundation_models.md) for extracted Apple Foundation Models framework technical specifications.
 
## License
 
MIT.
