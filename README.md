# apple-fm-audit

Unofficial reverse proxy that records HTTP traffic to Apple's on-device Foundation Model (`fm serve`) and shows it in a local web page. Request and response bodies are stored in SQLite.

This project is not affiliated with Apple.

## What it does

Clients talk to **apple-fm-audit**. The process forwards each call to `fm serve` (or another OpenAI-compatible origin), writes a row to SQLite, and serves an audit UI at `/`.

Chat Completions bodies are forwarded unchanged. `POST /v1/responses` is translated to `POST /v1/chat/completions` because `fm serve` has no Responses API. `Origin`, `Referer`, and `Sec-Fetch-*` are dropped so a browser can call `fm serve` without CSRF 403.

## Run with the script

Needs [uv](https://docs.astral.sh/uv/), Python 3.10+ (uv installs it), and `fm serve` on the upstream port. First use of `fm` on a Mac requires agreeing to Apple's terms yourself:

```bash
sudo fm license
fm serve
./run.sh
```

`./run.sh` runs `uv sync` and `fm license --status`. It does not type `yes` for you. If terms are not agreed, it prints the notice, still starts the UI, and the page shows the same text until you finish `sudo fm license`.

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

Installs two user agents: `fm serve` on `127.0.0.1:1976` and apple-fm-audit on `127.0.0.1:1977`. They start at login and restart if they exit.

```bash
./install-service.sh
./uninstall-service.sh
```

Logs: `~/Library/Logs/com.roy.fm-serve.log` and `~/Library/Logs/com.roy.apple-fm-audit.log`.

## Run with Docker

`fm serve` stays on the host. Compose maps `host.docker.internal:1976` to that process.

```bash
fm serve
docker compose up --build
```

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `AFM_LISTEN_HOST` | `127.0.0.1` (`0.0.0.0` in Docker) | Bind address |
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

Everything else, including `/v1/chat/completions` and `/health`, goes upstream.

## Tests

```bash
uv sync --frozen
PYTHONPATH=. uv run python -m unittest discover -s tests -v
```

## License

MIT.
