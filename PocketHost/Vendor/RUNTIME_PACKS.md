# Runtime packs

PocketHost runtime packs are intentionally restricted to `data` and `wasm` payloads. iOS does not allow PocketHost to download a new unsigned native runtime and execute it as if it were a Linux container.

Each install request contains:

- `manifest.id`
- `manifest.version`
- `manifest.runtime`
- `manifest.kind` (`data` or `wasm`)
- `manifest.sha256`
- `manifest.signature` (base64 Ed25519 signature over the raw payload)
- `payloadBase64`

`RuntimePackManager` verifies SHA-256 and the Ed25519 signature before writing the pack to Application Support.

Set the base64-encoded raw 32-byte Ed25519 public key in the app Info.plist as:

```text
RuntimePackPublicKey
```

Without that trusted public key, runtime-pack installation intentionally fails closed.
