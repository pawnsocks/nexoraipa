# CPython on iOS

Nexora Host builds CPython for iOS automatically in GitHub Actions.

The build pipeline runs `Scripts/build-cpython-ios.sh`, which checks out the official CPython source tag configured by `PYTHON_VERSION` (currently 3.14.7), builds the official iOS XCFramework with Apple's CPython build helper, and places it at `Vendor/Python.xcframework`.

`Scripts/build-unsigned-ipa.sh` then embeds the arm64 device `Python.framework`, installs the standard library into the app bundle, and converts stdlib extension `.so` files into iOS frameworks using the same `.fwork` layout expected by CPython's iOS support.

The resulting IPA is intentionally unsigned. Your sideloading signer must sign the app and all embedded frameworks before installation.

Runtime status in Nexora Host is based on the actual bundled framework + standard library. Python is not shown as available if those files are missing.
