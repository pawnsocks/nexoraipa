PocketHost CI fix for GitHub Actions run #3.

Upload the PocketHost folder at the repository root and replace the four existing Swift files:
- PocketHost/Core/SystemMetrics.swift
- PocketHost/Runtimes/RuntimeSupervisor.swift
- PocketHost/UI/TerminalView.swift
- PocketHost/UI/FilesView.swift

Then run Actions -> Build PocketHost IPA -> Run workflow again.
