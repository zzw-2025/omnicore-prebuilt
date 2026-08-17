#!/usr/bin/env bash
set -euo pipefail

archive="${1:?usage: smoke-macos.sh <runtime.tar.gz>}"
model_url="${OMNICORE_SMOKE_MODEL_URL:-https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories15M-q4_0.gguf}"
model_sha256="${OMNICORE_SMOKE_MODEL_SHA256:-66967fbece6dbe97886593fdbb73589584927e29119ec31f08090732d1861739}"
port="${OMNICORE_SMOKE_PORT:-18081}"
work="$(mktemp -d "${TMPDIR:-/tmp}/omnicore-smoke-XXXXXX")"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ -f "$work/server.stderr.log" ]]; then
    tail -n 80 "$work/server.stderr.log" || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

tar -xzf "$archive" -C "$work"
server_count="$(find "$work" -type f -name llama-server -print | wc -l | tr -d ' ')"
if [[ "$server_count" -ne 1 ]]; then
  echo "expected exactly one llama-server, found $server_count" >&2
  exit 1
fi
server="$(find "$work" -type f -name llama-server -print -quit)"
chmod +x "$server"
"$server" --version
devices="$("$server" --list-devices 2>&1)"
printf '%s\n' "$devices"
grep -qi metal <<<"$devices"

model="$work/stories15M-q4_0.gguf"
curl --fail --location --retry 2 --connect-timeout 10 --max-time 300 \
  --output "$model" "$model_url"
actual_sha256="$(shasum -a 256 "$model" | awk '{print $1}')"
if [[ "$actual_sha256" != "$model_sha256" ]]; then
  echo "smoke model SHA-256 mismatch: expected $model_sha256, got $actual_sha256" >&2
  exit 1
fi

"$server" -m "$model" --host 127.0.0.1 --port "$port" -c 512 --no-webui -ngl 999 \
  >"$work/server.stdout.log" 2>"$work/server.stderr.log" &
server_pid=$!
for _ in {1..90}; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "packaged server exited before readiness" >&2
    exit 1
  fi
  if curl --fail --silent --max-time 2 "http://127.0.0.1:$port/health" | grep -q '"status":"ok"'; then
    break
  fi
  sleep 0.5
done
curl --fail --silent --max-time 2 "http://127.0.0.1:$port/health" | grep -q '"status":"ok"'

response="$(curl --fail --silent --max-time 60 \
  -H 'Content-Type: application/json' \
  -d '{"model":"stories15M","messages":[{"role":"user","content":"Return a short test response."}],"max_tokens":8,"temperature":0}' \
  "http://127.0.0.1:$port/v1/chat/completions")"
python3 -c 'import json,sys; value=json.loads(sys.argv[1]); assert value["choices"][0]["message"]; assert value["usage"]["completion_tokens"] > 0' "$response"
stream_response="$(curl --fail --silent --max-time 60 \
  -H 'Content-Type: application/json' \
  -d '{"model":"stories15M","messages":[{"role":"user","content":"Return a short streamed response."}],"max_tokens":4,"temperature":0,"stream":true}' \
  "http://127.0.0.1:$port/v1/chat/completions")"
python3 -c 'import sys; lines=sys.argv[1].splitlines(); assert any(line.startswith("data: {") for line in lines); assert "data: [DONE]" in lines' "$stream_response"
printf '%s\n' '{"ok":true,"backend":"omnicore-metal","stream":true}'
