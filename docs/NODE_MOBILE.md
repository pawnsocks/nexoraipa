# Embedded Node.js runtime

Nexora Host embeds NodeMobile for real Node.js project execution on iOS.

The unsigned IPA build downloads the pinned NodeMobile iOS release, verifies its SHA-256, and embeds the arm64 `NodeMobile.framework`. At runtime Nexora additionally probes the `node_start` symbol before reporting Node.js as available.

Node and TypeScript projects run inside the embedded Node runtime. Nexora creates a project-local bootstrap that forwards console output to Nexora logs, supports stop requests, reads package.json, and can fetch/install compatible JavaScript dependencies from the npm registry.

This is not a full desktop npm environment. Packages that require native desktop addons, unsupported subprocess behavior, or platform-specific binaries may still fail on iOS. Pure-JavaScript packages are the intended path.
