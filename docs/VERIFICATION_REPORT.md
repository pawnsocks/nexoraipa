# Nexora Host verification report

This repository was checked before packaging the ZIP.

## Passed locally
- All 36 Swift source files pass `swiftc -parse`.
- Core project/file models + `ProjectManager` pass Swift type-checking on the available Swift toolchain.
- Project smoke test passes create/read/write, nested files, atomic multi-file AI apply primitive, path traversal rejection, and cleanup of legacy zero-byte `private*` path artifacts.
- Node bootstrap JavaScript passes `node --check` and runs a local smoke project that writes expected console output.
- `Info.plist` and `ExportOptions.plist` parse successfully.
- Asset catalog JSON parses successfully.
- GitHub Actions YAML parses successfully.
- All 36 Swift file references in the Xcode project point to real files; no Swift source is left unreferenced.
- All shell scripts pass `bash -n`.

## CI verification added
The GitHub workflow now fails unless the produced IPA contains:
- `NodeMobile.framework/NodeMobile` with the `node_start` symbol.
- `Python.framework/Python`.
- Python 3.14 standard library.
- Converted Python `.fwork` extension markers.
- `CFBundleDisplayName = Nexora Host`.

## Requires the next GitHub Actions run / real iPhone
Linux cannot run Xcode or an iOS device. The next macOS GitHub Actions build is therefore the authoritative compile/package check for the new CPython + NodeMobile bundle. After signing, a real iPhone test is still required for provider network availability, Discord gateway connectivity, background suspension behavior, and iOS framework loading.

## Runtime truth
The build is designed to make JavaScript, Lua, Node.js, TypeScript, and Python genuinely available. Nexora does not fake Bun, Docker, JVM, .NET, or other desktop runtimes as installed. Those remain editor-only/unavailable until a real iOS-compatible engine exists.

## Background hosting verification (v0.4)
- `BGContinuedProcessingTask` is guarded by `#available(iOS 26.0, *)`.
- GitHub Actions now builds with the iOS 26 SDK using Xcode 26.6 on `macos-26`.
- `app.nexorahost.continuedHosting` is present in `BGTaskSchedulerPermittedIdentifiers`.
- A user-started Run action submits continued-processing protection when Background Hosting is enabled.
- The continued task reports monotonic elapsed-session progress and updates the system title/subtitle.
- iOS 16-25 use `UIApplication.beginBackgroundTask` as a finite fallback.
- Stop/disable clears queued protection and the fallback lease.
- The Settings UI exposes a Background Hosting toggle and live status.

This is still best-effort background execution. Apple may expire continued tasks under resource pressure, and force-quitting the app ends local hosting.
