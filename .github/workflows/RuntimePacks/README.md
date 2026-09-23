# Runtime packs

Runtime pack installation is implemented by `RuntimePackManager` and exposed through:

```text
GET  /api/v1/runtime-packs
POST /api/v1/runtime-packs/install
```

Packs are limited to signed `data` or `wasm` payloads. The manager verifies SHA-256 plus an Ed25519 signature before installation.

See `../Vendor/RUNTIME_PACKS.md` for the manifest format and trusted public-key setup.

Lua is already linked as an embedded interpreter through LuaSwift. CPython uses the separate official iOS XCFramework flow documented in `../Vendor/CPYTHON_IOS.md`.
