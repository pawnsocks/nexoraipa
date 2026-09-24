# Nexora Host

Nexora Host is a local-first mobile development environment for iPhone and iPad.

The normal development flow does **not** require a Debian server, Linux VPS, remote runtime worker, owner token, or PC connection. Projects and supported runtimes live directly on the Apple device. Network access is only used for integrations that naturally require it, such as GitHub, AI providers and webhooks.

## Included in this repository

### Local workspace
- persistent per-project storage under Application Support
- project create, rename, duplicate and delete
- hierarchical file browser
- create files/folders, rename, duplicate, move and delete paths
- recursive project search with filename/text/regex modes
- ZIP project import and export
- local backup/restore manager
- project activity/history timeline
- local storage usage screen

### Local runtimes
- JavaScript execution through JavaScriptCore
- Lua execution through LuaSwift when linked by the build
- official CPython 3.14.7 build + PythonKit adapter, embedded by the IPA workflow
- Run / Stop / Restart lifecycle
- stdout/error logging in the project console
- honest capability catalog for the extended language list
- embedded NodeMobile 24.18.0-0 for real local Node.js projects
- TypeScript execution through NodeMobile 24 type stripping
- Bun, Docker and unsupported desktop runtimes are never reported as available unless a real implementation exists

### Data and preview
- first-class per-project SQLite database
- table listing and SQL query UI
- static HTML/CSS/JS preview through WKWebView
- local REST API and log WebSocket for the app's own supported services
- API Explorer for user HTTP requests

### GitHub and source sync
- GitHub token stored in Keychain
- repository list/search
- public/private repository import through the GitHub API
- repository files copied into local Nexora project storage
- local baseline/change detection
- review changed files before GitHub sync
- create a Git commit/tree/blob set and update the remote branch through GitHub's Git Data API
- remote-head conflict detection before push

This is intentionally labelled GitHub Sync rather than pretending that a full desktop `git` executable exists on iOS. Full libgit2 branch/merge/rebase parity is still a separate implementation task.

### AI
- AI remains completely optional
- provider-independent adapter layer
- presets for NanoGPT, OpenAI, Anthropic, Gemini, OpenRouter, Groq, Mistral, xAI, DeepSeek, Together AI, Fireworks AI, Cerebras and Cohere
- custom OpenAI-compatible provider
- provider keys stored separately in iOS Keychain
- searchable model browser and favorites
- project/file-aware AI context
- Ask / Edit / Agent / Debug / Review modes
- reviewable file diffs before applying changes
- local checkpoint before significant AI edits
- Agent/Debug apply flow can run the supported local project and report the real result
- human-readable provider errors, including NanoGPT insufficient-balance responses
- keyboard-safe composer: no automatic keyboard on open, interactive dismissal, no automatic reopening after responses

### Integrations
- Discord webhooks
- Discord embed configuration and preview
- generic HTTP webhooks with POST/PUT/PATCH
- webhook variables and delivery history
- lightweight local automations for run/project events
- automation actions for backups and webhooks
- local notifications for project results where iOS permits delivery
- official support Discord stored centrally

### Device adaptation
- iPhone and iPad target support
- portrait and landscape support
- device class, memory, CPU, thermal, battery/charging and Low Power Mode sampling where exposed by Apple APIs
- Auto / Performance / Balanced / Battery Saver modes
- automatic thermal and memory protection overrides
- adaptive worker/cache/runtime-memory/indexing/preview targets
- first-launch onboarding that does not require AI or a server

### Build/distribution
- existing Nexora Host app icon asset set
- iOS 16+ target
- GitHub Actions macOS build workflow
- unsigned IPA artifact for the user's existing sideloading setup

## Important iOS limitations

Nexora does not fake Linux or desktop behavior. In particular:

- iOS may suspend the app, so permanent 24/7 bots, servers and workers are not promised.
- Node.js is provided through NodeMobile rather than the desktop Node binary. Native Bun and Docker are not available in this build.
- Python is only shown as Available when a signed `Python.framework` is actually present in the built IPA.
- Native package/binary compatibility is restricted by iOS code-signing rules.
- The current web preview is for static/local web content; it does not pretend a Node dev server exists.

## CPython

GitHub Actions builds the official CPython 3.14.7 iOS XCFramework, caches it, embeds the arm64 `Python.framework`, copies the Python standard library, and converts stdlib extension `.so` files into iOS-loadable frameworks. The runtime reports Python Available only when both the framework and stdlib are present in the installed IPA.

## Validation performed in this environment

The repository is validated with Swift parser checks, plist/project-format checks, asset JSON checks, workflow YAML checks, and Xcode source-reference checks. A real device/Xcode compile still needs the macOS GitHub Actions runner because this working environment is Linux.

See `docs/IMPLEMENTATION_STATUS.md` and `docs/FEATURE_MATRIX.md` for the exact truth-status of each area.

Support: https://discord.gg/SXZkjcBkFA


## Latest fixes

- Free AI Pool is the default when no personal provider key is configured.
- A saved NanoGPT key is preferred automatically.
- File paths are canonicalized to avoid `/private/var` alias duplication on iOS.
- AI can propose and apply multiple files, including new files, after review.
- File/folder creation uses a dedicated creation sheet.
- NodeMobile is embedded by the IPA build and Node projects can run locally; missing pure-JS npm dependencies are installed from the npm registry before launch.


Build pipeline: NodeMobile 24.18.0-0 + official CPython 3.14.7 are embedded into the unsigned IPA during GitHub Actions.

## Background Hosting

Nexora Host includes a best-effort Background Hosting mode. On iOS/iPadOS 26+ it uses Apple's `BGContinuedProcessingTask` for projects explicitly started with Run; on older iOS versions it falls back to `beginBackgroundTask`. This can keep Discord bots and other local runtimes alive longer after leaving the app, but iOS still controls background execution and may expire/suspend the task. Force-quitting Nexora stops all local hosting.
