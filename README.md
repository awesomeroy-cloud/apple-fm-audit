# apple-fm-audit

Unofficial reverse proxy that records HTTP traffic to Apple's on-device Foundation Model (`fm serve`) and shows it in a local web page. Request and response bodies are stored in SQLite.

This project is not affiliated with Apple.

## What it does

Clients talk to **apple-fm-audit**. The process forwards each call to `fm serve` (or another OpenAI-compatible origin), writes a row to SQLite, and serves an audit UI at `/`.

Chat Completions bodies are forwarded unchanged. `POST /v1/responses` is translated to `POST /v1/chat/completions` because `fm serve` has no Responses API. `Origin`, `Referer`, and `Sec-Fetch-*` are dropped so a browser can call `fm serve` without CSRF 403.

## Run with the script

Needs Python 3.10+ and `fm serve` on the upstream port.

```bash
fm serve
./run.sh
```

Open [http://127.0.0.1:1977](http://127.0.0.1:1977). Point the client at the same origin:

API provider fields:

- Base URL: `http://127.0.0.1:1977/v1`
- API key: any non-empty string
- Model: `system`
- Wire API: Chat Completions or Responses (both work)

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:1977/v1", api_key="not-checked")
client.chat.completions.create(
    model="system",
    messages=[{"role": "user", "content": "Hello"}],
)
```

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

## Local routes (not proxied)

- `GET /` audit page
- `GET /_audit/calls` list
- `GET /_audit/calls/:id` one call
- `DELETE /_audit/calls` wipe the log
- `GET /_audit/meta` listen/upstream

Everything else, including `/v1/chat/completions` and `/health`, goes upstream.

## Tests

```bash
PYTHONPATH=. python3 -m unittest discover -s tests -v
```

## License

MIT.
