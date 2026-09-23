# Nexora Host implementation status

## Architecture decision

Nexora Host is now remote-first. The iPhone 13 is the controller/editor. Project servers, package installs, compilers, Git operations and long-running tasks belong to the Debian backend or external build runners.

## Phase 1 implemented in this upgrade

- mobile navigation: Projects / AI / Hosting / Activity / Settings
- one-owner backend configuration and Keychain token storage
- GitHub clone and empty project creation
- project dashboard with detected runtime/framework/branch/status
- remote file manager and code editor
- remote commands/tasks and basic mobile terminal helper bar
- dependency setup
- project start / stop / restart
- port detection and in-app web preview
- Git status / pull / commit / push
- project logs
- searchable NanoGPT model picker and project-aware AI modes
- review-before-apply AI file edits
- readable NanoGPT 402/balance errors rather than raw JSON
- runtime inventory and expanded language catalog
- hosting/process overview and task/activity overview

## Phase 2 next

- backend-owned AI Agent task lifecycle: Understand → Search → Plan → Checkpoint → Edit → Run → Test → Inspect → Fix → Verify → Finish
- multi-file patch sets
- Git checkpoints/worktrees
- Problems and Tests panels
- package/dependency UI
- process manager with stronger resource isolation

## Later phases

Follow the private Nexora Host platform specification for hosting/deployment, backups, databases, Docker, Discord/webhooks, automation, push notifications, Share Sheet, Shortcuts and iPhone polish.
