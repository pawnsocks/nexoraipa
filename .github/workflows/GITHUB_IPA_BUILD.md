# PocketHost IPA via GitHub Actions

This repository includes `.github/workflows/build-ipa.yml`.

## What it produces

The workflow builds an **unsigned device IPA** for iPhone/iOS:

- `PocketHost-unsigned.ipa`
- `PocketHost-unsigned.ipa.sha256`

The build target is `iphoneos`/arm64-compatible and PocketHost itself has a minimum deployment target of iOS 16, so the app target includes iPhone 13.

The generated IPA is intentionally unsigned. It can then be signed during installation with the user's own Apple ID/certificate using a sideloading tool. This avoids storing an Apple certificate or provisioning profile in the repository.

## Run it

1. Create a GitHub repository.
2. Upload/push the entire PocketHost project, including the `.github` folder.
3. Open the repository's **Actions** tab.
4. Select **Build PocketHost IPA**.
5. Choose **Run workflow**.
6. After the workflow succeeds, open that run and download the artifact named `PocketHost-iPhone13-unsigned`.
7. Extract the artifact ZIP; inside is `PocketHost-unsigned.ipa`.

The workflow also runs automatically on pushes to `main`.

If you publish a GitHub Release, the workflow additionally attaches the IPA and SHA-256 file to that release.

## Important: CPython

The normal CI build does **not** compile CPython during every run. If `Vendor/Python.xcframework` is not present, PocketHost still builds with the Python adapter unavailable at runtime. Lua and JavaScript remain independent.

To ship a build with embedded CPython, create the XCFramework on macOS using `Scripts/build-cpython-ios.sh`, add/embed it in the Xcode target, then commit or otherwise provide the framework to the build job before running the IPA workflow.

## Signing

This CI workflow deliberately avoids Apple signing credentials. That is safer for a public repository and works well for sideloading flows that re-sign the IPA locally.

If you later want a **pre-signed development/ad-hoc IPA**, add certificate/provisioning-profile secrets and use the existing archive/export scripts instead. Never commit a `.p12`, its password, or a provisioning profile to Git.
