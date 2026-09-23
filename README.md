# Nexora Host

Private, single-owner remote development and hosting client designed around an iPhone 13.

The iPhone app is the controller/editor. Heavy work such as project runtimes, package installation, terminal commands, compilers, long-running processes and hosting runs on the private Debian backend. iOS builds use GitHub Actions on a macOS runner.

## Included in this repository

- iOS SwiftUI client (`PocketHost.xcodeproj` is intentionally kept as the internal Xcode project/target name for build stability)
- Nexora Host app branding and app icon
- Projects, remote file/code workflows, terminal/tasks, runtime detection, preview, Git operations, logs and project-aware NanoGPT AI
- Private Debian backend in `NexoraHostBackend/`
- GitHub Actions workflow at `.github/workflows/build-ipa.yml`
- iPhone 13 / iOS 16+ unsigned IPA build

## Build the IPA

1. Upload the **contents of this repository** to GitHub exactly as-is. Keep `.github/workflows/build-ipa.yml` in that path.
2. Open **Actions** → **Build Nexora Host IPA**.
3. Click **Run workflow**.
4. When it succeeds, download the artifact `Nexora-Host-iPhone13-unsigned`.
5. Extract `Nexora-Host-unsigned.ipa` and sign/sideload it with your existing setup.

The app shown on iPhone is named **Nexora Host**. The Xcode scheme remains `PocketHost` internally so the already proven CI build path stays stable.

## Backend

See `NexoraHostBackend/README.md`.

The backend is single-owner. Configure the owner token and HTTPS endpoint, then enter them in Nexora Host Settings on the iPhone.

## Current implementation status

See `docs/IMPLEMENTATION_STATUS.md`.

This is the Phase-1 remote-first vertical slice. Later features such as autonomous agent loops/checkpoints, full production deploy/rollback, Docker/database panels, Discord/webhook automation and push notifications should be implemented incrementally rather than represented as completed when they are not.
