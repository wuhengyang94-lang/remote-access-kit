# Remote access kit reliability implementation plan

**Goal:** Fix the reviewed recovery and GUI defects and complete direct PC access without changing customer machines during development.

**Authority and baseline:** The user requested optimization after the review in this task. Baseline is `19a6b83`; implementation branch is `codex/remote-access-kit-reliability`. Existing 84 offline checks passed before changes. No GitHub push, customer deployment, live initialization, or production connection is included.

**Architecture:** Keep PowerShell 5.1 and WinForms. Separate portable settings, current-user DPAPI credentials, and child-process management into small shared helpers. Keep site journals on the jump host and local journals on the local PC.

**Tech stack:** Windows PowerShell 5.1, WinForms, Windows DPAPI, existing standalone offline tests.

## 1. Recovery and profile preservation

- [x] Add failing tests for default selection after an unchanged connect rerun, optional Tailscale cleanup after a previous undo, and restoring overwritten profile bytes.
- [x] Default undo selects all outstanding runs in the requested scope/site, newest first. Explicit `-Latest` remains an intentional narrower operation. Previously undone runs may be selected for explicitly requested optional Tailscale cleanup without replaying restored registry/account operations.
- [x] Add `Save-ZcProfile -Root -Journal -Path -Content -Marker`; back up existing files under the protected local state root, record hashes and backup location, and restore the original only if ownership/current content and backup integrity still match.
- [x] Run Recovery/State/Forwarding tests with fake registry, firewall, services, and native commands. Preserve RED and GREEN output separately under the local untracked lab evidence directory.

## 2. Settings and credentials

- [x] Add failing tests asserting that a saved public config contains neither plaintext password nor auth key, secrets decrypt only through the user credential store, and missing credentials on another PC produce an actionable error.
- [x] Add `zc-config.ps1`. Use a random credential ID, current-user DPAPI, and an ACL restricted to the current user and SYSTEM. Public settings retain empty legacy secret fields for compatibility. Saving through the GUI migrates existing plaintext values; CLI legacy input remains readable with a warning.
- [x] Update `run.ps1`, the config template, and launcher sandbox dependencies. Never place decrypted secrets in child-process arguments or logs.

## 3. Direct PC connection

- [x] Add a failing launcher case with a jump-host address and no target server; the selected direct mode must reach the engine as `-DirectOnly`.
- [x] Add `-DirectOnly` to 02. Normal mode prepares local Tailscale/WinRM/TrustedHosts and verifies an actual remote command; read-only mode only checks existing setup. Direct mode performs no discovery, portproxy, or remote firewall changes.
- [x] Forward mode still requires an explicit target in noninteractive usage. Preserve existing validation and conflict refusal.
- [x] Route profile writing through `Save-ZcProfile`.

## 4. GUI execution

- [x] Add failing tests for a script path containing spaces and retained exit code 7 from a redirected Windows PowerShell child.
- [x] Add `zc-process.ps1` for quoted argument construction, hidden noninteractive child processes, retained handles, protected temporary logs, and cleanup.
- [x] Update GUI mode selection, secure config save/load, success/failure status, busy controls, and post-initialization address refresh. Add undo preview; execution requires a matching successful preview and shows the selected scope/site.
- [x] Verify actual button/event wiring with stub engines, not syntax checks alone. Keep GUI source UTF-8 BOM.

## 5. Review and delivery

- [x] Run all old and new offline tests under Windows PowerShell 5.1, parse every script, and inspect the GUI rendering with no engine main flow executed.
- [x] Request an independent review of the diff and this plan; address findings and rerun affected checks.
- [x] Update README to describe current behavior and actual validation boundaries. Sync controlled files to the local runnable kit, preserve lab evidence, and rebuild a credential-free ZIP from an explicit file list.
- [x] Verify ZIP contents, SHA256, source synchronization, and final Git diff. Report local completion separately from unperformed customer acceptance and publishing.
