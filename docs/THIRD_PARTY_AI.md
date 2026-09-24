# Third-party AI routing

Nexora Host includes an optional **Free AI Pool** based on public keyless routes documented by the FreeLLMAPI project. Nexora calls those upstream routes directly on iOS; it does not require a Debian server.

Current keyless pool:
- Kilo Gateway free routes
- OVH AI Endpoints anonymous routes
- AI Horde anonymous community inference

Free access, model availability, quotas and upstream data practices can change. Nexora discovers models at runtime and falls back when an endpoint is unavailable.

If a NanoGPT key is saved, Nexora automatically prefers NanoGPT. Other user-supplied providers remain optional. User API keys are stored in the iOS Keychain.

Reference project: https://github.com/tashfeenahmed/freellmapi (MIT).
