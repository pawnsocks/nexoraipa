# Nexora Host implementation status

This file separates real implementation from planned or platform-limited behavior. UI-only work is not counted as implemented.

## IMPLEMENTED

### Local IDE core
- Local-first app shell; no required Debian/backend configuration.
- Persistent local project records and per-project workspaces.
- Create, rename, duplicate and delete projects.
- Hierarchical file browsing and real filesystem reads/writes.
- Create files/folders; rename, move, duplicate and delete project paths.
- ZIP import/export.
- Recursive project search: filename, text and regex.
- Real text editor over project files with save and run entry-point actions.
- Project Run / Stop / Restart lifecycle.
- Project console/log collection.
- SQLite project database with SQL execution and table listing.
- Static HTML/CSS/JS preview using WKWebView.
- Local REST API and log WebSocket.
- HTTP API Explorer.

### Runtime system
- JavaScriptCore local JavaScript execution.
- Lua adapter through LuaSwift.
- CPython/PythonKit adapter and real framework-presence detection.
- Runtime capability catalog for the extended language list.
- Unsupported runtimes are shown as unavailable/experimental rather than Installed.

### Project safety/recovery
- Project backups and restore.
- Project activity/history timeline.
- Local storage usage manager.
- Runtime states reset safely on relaunch instead of pretending terminated work survived.

### GitHub/source sync
- GitHub credentials in Keychain.
- Repository list/search.
- Repository import from GitHub API into a local project.
- Private repository support when a token is configured.
- Local baseline metadata and changed-file detection.
- Remote commit/tree/blob creation and branch-ref update through GitHub's Git Data API.
- Remote-head conflict check before push.

### AI
- Optional AI; normal local IDE features do not require a key.
- Provider abstraction and presets for NanoGPT, OpenAI, Anthropic, Gemini, OpenRouter, Groq, Mistral, xAI, DeepSeek, Together AI, Fireworks AI, Cerebras and Cohere.
- Custom OpenAI-compatible provider.
- Per-provider API key storage in Keychain.
- Provider/model selection and searchable model browser.
- Project/file-aware context.
- Ask / Edit / Agent / Debug / Review modes.
- Reviewable proposed file replacement diff.
- Local checkpoint before applying AI edits.
- Agent/Debug apply path runs supported local project code and reports actual output.
- NanoGPT/provider error normalization including insufficient-balance handling.
- Keyboard-safe AI screen behavior.

### Webhooks/automation
- Discord webhook configuration.
- Discord embed payload builder and preview.
- Generic POST/PUT/PATCH webhooks.
- Variable substitution.
- Delivery history.
- Local automation rules for manual/project/run events.
- Backup and webhook automation actions.
- Local notifications for run results where iOS permits them.

### Device/build
- iPhone + iPad target families.
- Portrait + landscape declarations.
- Device metrics and dynamic Auto Tune.
- Thermal/memory/Low Power Mode protection.
- First-launch onboarding.
- GitHub Actions unsigned IPA workflow.
- Nexora Host app icon assets.

## TESTED HERE

- Every Swift source passes `swiftc -parse` in the current workspace.
- `PocketHost/Info.plist` passes `plutil -lint`.
- `PocketHost.xcodeproj/project.pbxproj` passes `plutil -lint`.
- AppIcon asset JSON parses successfully.
- GitHub Actions workflow YAML parses successfully.
- Every Swift file referenced by the Xcode project exists in the repository.
- ZIP archive integrity is checked after creation.

These checks do **not** equal a real Xcode/iPhone build. That requires the macOS runner/device.

## BLOCKED / PLATFORM-LIMITED

- CPython becomes Available only after a signed iOS Python framework is actually embedded and validated in the IPA.
- iOS can suspend Nexora, so permanent 24/7 local bots, servers and workers cannot be guaranteed.
- Full desktop Node.js, Bun and Docker are not implemented and are not reported as available.
- Arbitrary native packages cannot simply be downloaded and executed as unsigned desktop binaries on normal iOS.

## PARTIAL, NOT CLAIMED AS FULL DESKTOP PARITY

- GitHub Sync is real, but it is not yet full libgit2 Git parity (merge/rebase/stash and every branch operation are not implemented).
- Static web preview is real; arbitrary dynamic desktop web stacks are not.
- AI Agent mode performs a bounded local edit/checkpoint/run flow, but it is not an unrestricted autonomous shell agent.
- Automation is event-based and local; iOS suspension limits scheduled/background guarantees.

## NOT YET IMPLEMENTED

- Full on-device libgit2 Git feature parity.
- TypeScript transpilation pipeline.
- WASM/WASI runtime execution packs.
- General-purpose package installation for all runtimes.
- Full syntax-highlighting/LSP/autocomplete editor comparable to a desktop IDE.
- App Intents/Shortcuts actions.
- Dedicated Share Extension; project ZIP sharing is implemented through the system ShareLink.
- Guaranteed background schedules while iOS has fully suspended the app.

Nexora intentionally leaves these as unavailable/partial rather than presenting fake working controls.


## Final runtime packaging update
- GitHub Actions now builds and embeds official CPython 3.14.7 for iOS.
- GitHub Actions downloads, verifies and embeds NodeMobile 24.18.0-0.
- TypeScript projects execute through NodeMobile 24 type stripping.
- JavaScriptCore and Lua remain embedded.
- Other language entries remain unavailable unless a real compatible runtime is added; the UI does not fake them as installed.
- Free AI Pool is tested with a real chat request; a saved NanoGPT key takes priority.
- AI multi-file apply is transactional and creates a backup checkpoint first.
- Legacy zero-byte private/privateprivate path artifacts are cleaned safely.

## Background hosting (v0.4)
- iOS/iPadOS 26+: BGContinuedProcessingTask registered and submitted when the user starts a project.
- Live system progress is updated using elapsed hosting-session time.
- iOS 16-25: UIApplication background-time fallback.
- Background Hosting can be disabled in Settings.
- iOS remains the final scheduler: force-quit, resource pressure, thermal pressure or system policy can still suspend/terminate background execution.
