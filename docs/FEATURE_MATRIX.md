# Master prompt feature matrix

Legend: **Yes** = underlying behavior exists, **Partial** = useful real subset exists, **Blocked** = platform/build dependency, **No** = not implemented and not faked.

| Area | Status | Current behavior |
|---|---|---|
| No required server | Yes | Local-first; no Debian/backend URL/owner token. |
| iPhone + iPad | Yes | Universal target family and adaptive SwiftUI layouts. |
| Device capability scan | Yes | Device class, cores/memory class signals, storage views, thermal/battery/Low Power state where exposed. |
| Dynamic Auto Tune | Yes | Worker/cache/memory/index/preview targets with thermal/memory overrides. |
| Projects | Yes | Local persistent create/rename/duplicate/delete. |
| File manager | Yes | Hierarchy, create, rename, move, duplicate, delete, search, ZIP import/export. |
| Code editor | Partial | Real file editing/save/run; advanced LSP/multi-tab syntax tooling is not complete. |
| Global search | Yes | Filename/text/regex project search. |
| JavaScript | Yes | Local JavaScriptCore execution. |
| Lua | Yes when linked | LuaSwift interpreter capability is detected truthfully. |
| Python | Blocked | Adapter exists; requires actual signed Python.framework in IPA before availability. |
| TypeScript | No | Editing only; no fake transpiler. |
| WASM/WASI | No | Capability path documented; runtime pack execution not complete. |
| Node.js/Bun/Docker | Blocked by chosen iOS model | Shown unavailable, never faked. |
| Run/Stop/Restart | Yes | Supported local runtimes. |
| Console/logs | Yes | Project logs and actual run results. |
| Static web preview | Yes | WKWebView renders local web content. |
| Dynamic server preview | Partial | Only where an actually supported local runtime can expose it; no fake Node server. |
| SQLite | Yes | Project DB, tables and SQL queries. |
| Package manager | No | Compatibility/install system not generalized yet. |
| GitHub authentication | Yes | Token stored in Keychain. |
| GitHub repository list/search | Yes | GitHub API. |
| GitHub clone/import | Yes | Repository tree/blobs imported locally. |
| Git diff/status | Partial | Baseline changed-file detection, not full libgit2 index semantics. |
| Git commit/push | Yes for GitHub Sync | Git Data API creates commit/tree/blobs and updates branch with conflict guard. |
| Full native Git | No | libgit2 merge/rebase/stash parity not complete. |
| AI optional | Yes | IDE remains usable without keys. |
| Multi-provider AI | Yes | Major presets + custom OpenAI-compatible. |
| Keychain AI secrets | Yes | Per-provider keys. |
| Model search | Yes | Search/favorites. |
| Project-aware AI | Yes | Active project/file context. |
| AI diff review | Yes | Review before apply. |
| AI checkpoints | Yes | Backup created before significant apply. |
| Agent/Debug modes | Partial | Bounded edit/checkpoint/run verification for supported runtimes. |
| Discord webhook | Yes | Message/embed + test/send. |
| Generic webhook | Yes | POST/PUT/PATCH with headers/body. |
| Webhook logs | Yes | Local delivery history. |
| Local automations | Yes | Project/run/manual triggers, backup/webhook actions. |
| Project history | Yes | Persistent activity timeline. |
| Backups | Yes | Create/restore/delete/export-ready local backups. |
| Local notifications | Yes | Requested/sent where iOS permits. |
| API Explorer | Yes | HTTP methods, headers, body, status and response. |
| Storage manager | Yes | Project/backups/log-related local storage information/actions. |
| Share project | Yes | Export ZIP + system ShareLink. |
| Share Extension | No | No dedicated extension target yet. |
| App Intents/Shortcuts | No | Not exposed yet. |
| Crash/background restoration | Partial | Project/editor data persists; terminated runtimes are never falsely marked running. |
| GitHub Actions IPA | Yes | macOS workflow produces unsigned IPA artifact after successful compile. |
