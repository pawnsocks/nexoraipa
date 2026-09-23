Nexora Host remote-first upgrade

WHAT CHANGED
- The iPhone 13 is now the controller/editor, not the project host.
- Project runtimes, package installs, compilers, terminals and long-running processes move to the Debian backend.
- Bottom navigation is Projects / AI / Hosting / Activity / Settings.
- Backend URL + one-owner token are stored in Settings; the token is stored in iOS Keychain.
- GitHub clone and empty project creation are wired to the backend.
- Each remote project has Code / Files / Terminal / Preview / Git / Logs / AI / More.
- Remote file editor can save and run common file types on the backend.
- Remote terminal tasks keep running independently of the iPhone screen.
- Dependency Setup, Start, Stop and Restart are remote actions.
- Backend detects runtime/framework/package manager/start command/ports.
- Preview opens inside the app when the backend detects a port.
- Git status, pull, commit and optional push are available.
- AI is project-aware, keyboard-safe, uses searchable NanoGPT models and review-before-apply file edits.
- NanoGPT 402/insufficient-balance errors are readable instead of raw JSON.
- Runtime manager is server-first and includes the expanded language catalog.
- Hosting and Activity tabs show remote processes/tasks.
- No plans, billing, public registration, teams or customer logic were added.

IMPORTANT ARCHITECTURE CHANGE
The old local hosting idea is intentionally not expanded further. The new private Nexora Host specification says the iPhone must NOT run Docker, Node/Python servers, compilers or builds locally. Heavy work belongs to the Debian backend or GitHub Actions/macOS runner.

HOW TO BUILD THE IPA
1. Upload every root .swift file in this ZIP to the ROOT of pawnsocks/nexoraipa, same as the previous fix files.
2. Open .github/workflows/build-ipa.yml.
3. Replace its full contents with this ZIP's build-ipa.yml.
4. Commit.
5. Actions -> Build Nexora Host IPA -> Run workflow.
6. Download the Nexora-Host-iPhone13-unsigned artifact.

HOW TO DEPLOY THE BACKEND
1. Copy the NexoraHostBackend folder to your Debian server.
2. Read NexoraHostBackend/README.md.
3. Run install.sh once as root; the actual service is installed under a restricted 'nexora' user.
4. Set NEXORA_OWNER_TOKEN and NEXORA_PUBLIC_HOST in /opt/nexora/backend/.env.
5. Put HTTPS/reverse proxy in front of port 8787.
6. In the iPhone app, Settings -> Nexora Host backend -> enter the HTTPS URL and same owner token.

PHASING
This implements the strong Phase-1 vertical slice from the supplied Nexora Host platform specification. Autonomous Agent loops/checkpoints, production deploy/rollback, Docker panel, database provisioning, Discord/webhooks, automations, push notifications and other later phases are intentionally not faked yet. See docs/IMPLEMENTATION_STATUS.md.


APP ICON
========
The folder AppIcon.appiconset contains the Nexora Host icon based on the selected anime artwork.
Upload the complete AppIcon.appiconset folder to the repository root together with the patch files.
The build workflow automatically replaces PocketHost/Assets.xcassets/AppIcon.appiconset before compiling.
Do not rename the icon files or the folder.
