# PocketHost API Host

PocketHost is an API-first local runtime/hosting stack for iOS. The SwiftUI app is the on-device control panel; automation and external clients use the versioned local API.

## What is implemented

- REST API on `http://<iphone-ip>:8080/api/v1`
- Public health endpoint plus Bearer auth for protected operations
- Projects + versioned deployments
- Start / Stop / Restart logical runtime lifecycle
- Project workspace Files API with traversal protection
- Recent logs over REST + live logs over WebSocket (`ws://<iphone-ip>:8081`)
- Per-project SQLite database API with WAL
- JavaScript execution through JavaScriptCore
- Lua 5.4 embedded through LuaSwift
- CPython adapter through PythonKit + official iOS `Python.xcframework` integration script
- Signed runtime/data pack manager (SHA-256 + Ed25519; `data`/`wasm` only)
- NanoGPT AI integration with Keychain API-key storage, model discovery/selection and chat
- Existing global KV store, metrics and Auto-Tune engine

## Authentication

PocketHost creates a random local API token on first launch and stores it in the iOS Keychain. The dashboard shows the token so your own LAN clients can connect.

```text
Authorization: Bearer <POCKETHOST_TOKEN>
```

`GET /health` and `GET /api/v1/health` are public. Other `/api/v1/*` endpoints require the token.

## Projects and deployments

Create a JavaScript project:

```sh
curl -X POST http://IPHONE_IP:8080/api/v1/projects \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"demo","runtime":"javascript","entrypoint":"index.js"}'
```

Deploy a release (replace `PROJECT_ID`):

```sh
curl -X POST http://IPHONE_IP:8080/api/v1/projects/PROJECT_ID/deployments \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"files":[{"path":"index.js","content":"console.log(\"PocketHost online\")","encoding":"utf8"}]}'
```

Start / stop / restart:

```sh
curl -X POST -H "Authorization: Bearer TOKEN" http://IPHONE_IP:8080/api/v1/projects/PROJECT_ID/start
curl -X POST -H "Authorization: Bearer TOKEN" http://IPHONE_IP:8080/api/v1/projects/PROJECT_ID/stop
curl -X POST -H "Authorization: Bearer TOKEN" http://IPHONE_IP:8080/api/v1/projects/PROJECT_ID/restart
```

On iOS these are **logical runtime contexts**, not Linux child processes: Start loads the active entrypoint into the embedded runtime; Stop releases that context.

## Files API

```sh
# list
curl -H "Authorization: Bearer TOKEN" \
  'http://IPHONE_IP:8080/api/v1/projects/PROJECT_ID/files?path='

# read
curl -H "Authorization: Bearer TOKEN" \
  'http://IPHONE_IP:8080/api/v1/projects/PROJECT_ID/file?path=index.js'

# write
curl -X PUT -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json" \
  -d '{"content":"console.log(123)","encoding":"utf8"}' \
  'http://IPHONE_IP:8080/api/v1/projects/PROJECT_ID/file?path=index.js'
```

Paths are confined to the project's workspace; `..` traversal outside the project is rejected.

## Logs

Recent logs:

```sh
curl -H "Authorization: Bearer TOKEN" \
  'http://IPHONE_IP:8080/api/v1/projects/PROJECT_ID/logs?limit=200'
```

Live logs use WebSocket port `8081`. Authenticate in the first text frame:

```js
const ws = new WebSocket("ws://IPHONE_IP:8081");
ws.onopen = () => ws.send(JSON.stringify({
  token: "TOKEN",
  projectID: "PROJECT_ID"
}));
ws.onmessage = e => console.log(e.data);
```

The server first replays recent entries and then pushes new log events.

## Project database

Every project receives its own SQLite database.

```sh
curl -X POST \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sql":"CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, text TEXT);"}' \
  http://IPHONE_IP:8080/api/v1/projects/PROJECT_ID/db/query
```

```sh
curl -X POST \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sql":"SELECT * FROM notes LIMIT 50;"}' \
  http://IPHONE_IP:8080/api/v1/projects/PROJECT_ID/db/query
```

## NanoGPT AI

Default upstream base URL:

```text
https://nano-gpt.com/api/v1
```

You can enter/change the NanoGPT API key in the **AI** tab. The secret is stored in Keychain. The selected model and base URL are preferences; the API never returns the raw NanoGPT key.

You can also configure it through PocketHost's API:

```sh
curl -X PUT http://IPHONE_IP:8080/api/v1/ai/config \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"apiKey":"YOUR_NANOGPT_KEY"}'
```

Load available models:

```sh
curl -H "Authorization: Bearer TOKEN" \
  http://IPHONE_IP:8080/api/v1/ai/models
```

Select a model:

```sh
curl -X PUT http://IPHONE_IP:8080/api/v1/ai/config \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"selectedModel":"MODEL_ID"}'
```

Chat / coding request:

```sh
curl -X POST http://IPHONE_IP:8080/api/v1/ai/chat \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Write a small JavaScript HTTP handler"}],"temperature":0.3}'
```

`model` can also be supplied on each `/ai/chat` request to override the selected default.

## Runtimes

### JavaScript

Already embedded with `JavaScriptCore`.

```sh
curl -X POST http://IPHONE_IP:8080/api/v1/runtimes/javascript/execute \
  -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json" \
  -d '{"code":"console.log(2 + 2)"}'
```

### Lua

The Xcode project includes LuaSwift 1.12.3. PocketHost creates a sandboxed Lua engine (Lua 5.4 default) for execution and project contexts.

```sh
curl -X POST http://IPHONE_IP:8080/api/v1/runtimes/lua/execute \
  -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json" \
  -d '{"code":"return 6 * 7"}'
```

### CPython

The Swift adapter is implemented. The binary framework still has to be produced on macOS/Xcode because this repository was generated outside a macOS build host.

```sh
./Scripts/build-cpython-ios.sh
```

Then follow `Vendor/CPYTHON_IOS.md`. Once `Python.xcframework` is embedded, the already-existing Python endpoint becomes live without changing clients:

```text
POST /api/v1/runtimes/python/execute
```

## Runtime packs

```text
GET  /api/v1/runtime-packs
POST /api/v1/runtime-packs/install
```

Installable runtime packs are restricted to signed **data/WASM** payloads. Native runtime code must be bundled and signed with the IPA. See `Vendor/RUNTIME_PACKS.md`.

## API contract

See `OpenAPI.yaml` for the complete REST contract.

Main groups:

```text
/api/v1/status
/api/v1/metrics
/api/v1/runtimes/*
/api/v1/projects/*
/api/v1/runtime-packs/*
/api/v1/ai/*
/api/v1/kv/*
/api/v1/autotune/*
```

## Build

Requirements:

- macOS + full Xcode for an actual iOS build/IPA
- Swift 6 compatible Xcode
- iOS 16+ deployment target
- physical iPhone recommended for LAN testing
- Apple signing identity/profile

Open:

```text
PocketHost.xcodeproj
```

Swift packages configured in the project:

- `apple/swift-nio` 2.87.0
- `apple/swift-nio-transport-services` 1.26.0
- `ChrisGVE/LuaSwift` 1.12.3
- `pvieito/PythonKit` main

## IPA export

```sh
./Scripts/archive.sh
./Scripts/export-ipa.sh
```

## iOS reality

PocketHost is not a Linux VM. It does not use `fork()`, root access or unrestricted JIT. iOS may suspend the app in the background, so a normal sideloaded build cannot promise an always-on 24/7 daemon. Runtime lifecycle therefore uses in-process contexts and sandboxes.

## GitHub Actions IPA build

PocketHost now includes an automatic GitHub Actions build at:

```text
.github/workflows/build-ipa.yml
```

It builds an unsigned device IPA (`PocketHost-unsigned.ipa`) on a macOS runner and uploads it as the `PocketHost-iPhone13-unsigned` Actions artifact. This is intended for local re-signing during sideload installation and therefore does not require storing Apple signing certificates in GitHub.

Full instructions: `GITHUB_IPA_BUILD.md`.
