# Task List: macOS Secure Disk Erase Tool

Companion to `implementation-plan.md`. Tasks marked **(HUMAN)** need human input, hardware, accounts, or sign-off.
Task IDs follow the plan's phases. Internal-disk protection tasks are tagged `[SAFETY]` and are release-blocking.

---

## Phase 0: Decisions and accounts

- [ ] 0.1 Sign in to Xcode with a free Apple ID and create a personal-team Apple Development certificate **(HUMAN)**
- [ ] 0.2 Decide the distribution scope: personal use, small trusted group, or public **(HUMAN)**
- [x] 0.3 Decide the built-in SD slot policy: strict (USB reader required) or relaxed **(HUMAN)** `[SAFETY]`
  - Note: decided: relaxed, the built-in SD card slot is allowed. Applies only to disks under Apple's SDXC driver
- [ ] 0.4 Approve the allowed-protocol list (default `USB`, `Secure Digital`) and size cap (default 2 TB) **(HUMAN)** `[SAFETY]`
- [x] 0.5 Set minimum macOS version (13+ for `SMAppService`)
  - Note: set to macOS 13.0
- [ ] 0.6 Approve the method label and limits wording used in the UI and reports **(HUMAN)**
- [ ] 0.7 OPTIONAL, public distribution only: enroll in the paid Developer Program, obtain a Developer ID certificate, and create notarization credentials **(HUMAN)**

## Phase 1: Scaffolding

- [x] 1.1 Create Xcode workspace: App target, Helper target
  - Note: app and helper targets added to the existing x-shredder project; no separate workspace file
- [x] 1.2 Create Swift packages: Engine, DiskGuard, Report
- [x] 1.3 Set up CI to build and run all unit tests on every commit
  - Note: `.github/workflows/ci.yml` and `scripts/test-all.sh` written; the workflow has not run yet because this folder is not a git repository
- [x] 1.4 Set up unified logging with a no-secrets rule
- [ ] 1.5 Produce a personal-team-signed hello-world with an embedded helper; confirm `SMAppService` registration, the XPC connection, and the caller check all work without notarization **(HUMAN)** (needs a Mac with the helper approved in Login Items)
- [ ] 1.7 If 1.5 fails, choose the helper fallback (cdhash pinning or `sudo` CLI) and record the decision **(HUMAN)** `[SAFETY]`
- [x] 1.6 Add a debug-only build flag for test disk images; confirm it is compiled out of release builds `[SAFETY]`

## Phase 2: DiskGuard `[SAFETY]`

- [x] 2.1 Enumerate disks with DiskArbitration and read their description dictionaries
- [x] 2.2 Read model, serial (where available) and IORegistry entry ID via IOKit
- [x] 2.3 Rule: whole disk only
- [x] 2.4 Rule: `DeviceInternal` must be false
- [x] 2.5 Rule: reject virtual disks, disk images and APFS synthesized containers
- [x] 2.6 Rule: resolve and reject the boot disk and every physical store behind a mounted system or data container
- [x] 2.7 Rule: require removable or ejectable media
- [x] 2.8 Rule: protocol allowlist, unknown protocols refused
- [x] 2.9 Rule: size cap
- [x] 2.10 Rule: refuse read-only or write-protected media
- [x] 2.11 Fail closed: any unreadable key counts as a failed rule
- [x] 2.12 Implement identity fingerprint (registry entry ID, size, block size, protocol) and comparison
- [x] 2.13 Build recorded-description fixtures: internal SSD, boot disk, built-in SD slot, USB reader with SD card, external USB hard drive, disk image, APFS synthesized container, missing-key cases
  - Note: internal SSD, boot disk, APFS container and disk image fixtures are recorded from this Mac; the built-in SD slot, USB reader and USB hard drive fixtures are constructed, not recorded on hardware (the SD slot driver class chain matches the empty slot on this Mac)
- [x] 2.14 Write the exhaustive rule test matrix; every internal, virtual, boot and unknown case must be rejected
- [ ] 2.15 Review the DiskGuard code and tests line by line **(HUMAN)**

## Phase 3: Engine

- [x] 3.1 Define a `BlockDevice` protocol with a file-backed fake for tests
- [x] 3.2 Implement the raw `BlockDevice`: open `/dev/rdiskN`, `F_NOCACHE`, geometry via `DKIOCGETBLOCKSIZE` and `DKIOCGETBLOCKCOUNT`, aligned buffers
- [x] 3.3 Implement `F_FULLFSYNC` flushing and cache-dropping before verification
- [x] 3.4 Implement the pattern generator (AES-CTR via CommonCrypto, nonce from pass and block index)
- [x] 3.5 Implement the zero pattern
- [x] 3.6 Implement the write loop with 3 retries, then hard fail
- [x] 3.7 Implement the verifier (full read-back, mismatch reports block index)
- [x] 3.8 Make pass 1 a full-range write plus read-back, doubling as the capacity check
- [x] 3.9 Implement checkpointing with an encrypted run key; resume support; delete key on completion
- [x] 3.10 Implement progress reporting (phase, bytes, throughput, ETA)
- [x] 3.11 Test the Engine end to end against the fake device: success, write error, mismatch, wrap-around (fake capacity), resume
- [x] 3.12 Test the Engine against a test disk image in a debug build only

## Phase 4: Privileged helper

- [x] 4.1 Register the daemon with `SMAppService`
  - Note: registration code is in place; it has not been exercised, see 1.5 and 4.9
- [x] 4.2 Define the XPC protocol: `listEligibleDisks`, `startErase(bsdName, options)`, `cancel`, progress callbacks
- [x] 4.3 Validate XPC callers by code-signing requirement pinning team ID and bundle ID (personal-team build) `[SAFETY]`
- [x] 4.4 Accept only a BSD name and options; no paths, no override flags `[SAFETY]`
- [x] 4.5 Re-run full DiskGuard inside the helper using fresh data before acting `[SAFETY]`
- [x] 4.6 Capture the identity fingerprint; unmount via DiskArbitration; open exclusively; compare fingerprint again and abort on any change `[SAFETY]`
- [x] 4.7 Add in-flight guard: abort and log if the target is ever found to be boot or internal `[SAFETY]`
- [x] 4.8 Handle cancel, card removal mid-erase, and helper crash (state recorded as failed, never as success)
  - Note: cancel, helper crash and resume verified on scratch disk images; card removal verified only with the fake device, real removal is 7.12
- [ ] 4.9 Approve the helper in System Settings during first run **(HUMAN)**
- [ ] 4.10 Only if needed: implement the ad-hoc fallback caller check (pin the app cdhash, regenerate per build) and document it as weaker `[SAFETY]`
- [ ] 4.11 Only if needed: implement the no-helper `sudo` CLI build of Engine and DiskGuard; confirm the DiskGuard rules still apply in full `[SAFETY]`

## Phase 5: GUI

- [x] 5.1 Build the device list (name, size, protocol, reader details) with live arrival and removal updates
- [x] 5.2 Show only eligible disks as selectable; optional greyed "excluded disks" view with the reason shown `[SAFETY]`
- [x] 5.3 Confirm there is no override control, preference or flag in release builds `[SAFETY]`
- [x] 5.4 Build options: passes (default one random pass), second zero pass optional, verification always on
- [x] 5.5 Build the confirmation step: type the card's size and name exactly; plain-language data-loss warning
- [x] 5.6 Build the progress view: phase, throughput, time remaining, cancel
- [x] 5.7 Build the result view with the honest method label
- [ ] 5.8 Accessibility pass: VoiceOver and keyboard navigation
  - Note: NOT DONE: labels, hints and keyboard shortcuts are implemented, but nothing has been checked with VoiceOver switched on
- [ ] 5.9 UI review of the warning and confirmation wording **(HUMAN)**

## Phase 6: Reporting

- [x] 6.1 Define report fields: version, date and time, model, size, serial if available, passes, verification result, errors, method label
- [x] 6.2 Implement report signing (Ed25519 or Developer ID certificate)
- [x] 6.3 Export as PDF and JSON
- [x] 6.4 Add the limits statement (remapped and spare blocks, physical destruction advice for high-sensitivity data)
- [ ] 6.5 Review report wording for compliance suitability (for example GDPR or HIPAA expectations) **(HUMAN)**

## Phase 7: Testing

- [ ] 7.1 Run all unit and integration tests in CI
  - Note: NOT DONE: all tests pass locally through `scripts/test-all.sh`; they have not run in CI
- [ ] 7.2 Attempt to select and erase the internal SSD; must be refused at all three layers **(HUMAN)** `[SAFETY]`
- [ ] 7.3 Attempt to select and erase the boot disk; must be refused **(HUMAN)** `[SAFETY]`
- [ ] 7.4 Attempt to select an external USB drive holding system volumes; must be refused **(HUMAN)** `[SAFETY]`
- [ ] 7.5 Attempt to select the built-in SD slot; behavior must match the policy chosen in 0.3 **(HUMAN)** `[SAFETY]`
- [ ] 7.6 Attempt to bypass the UI by sending a crafted XPC request for an internal disk; the helper must refuse **(HUMAN)** `[SAFETY]`
- [ ] 7.7 Test the card-swap case: remove the card after validation and insert a different device; the fingerprint check must abort **(HUMAN)** `[SAFETY]`
- [ ] 7.8 Verified erase on genuine SanDisk SD and microSD cards, several sizes **(HUMAN)**
- [ ] 7.9 Verified erase on genuine Sony SD cards, several sizes **(HUMAN)**
- [ ] 7.10 Repeat on at least two different USB card readers **(HUMAN)**
- [ ] 7.11 Run a known fake-capacity card; the capacity check must fail it **(HUMAN)**
- [ ] 7.12 Fault tests: pull the card mid-erase, kill the helper, sleep and wake the Mac **(HUMAN)**
- [ ] 7.13 Independent security review of the helper and XPC boundary **(HUMAN)**
- [ ] 7.14 Fix all high-severity findings and re-test
- [ ] 7.15 Confirm the helper rejects a client signed with a different identity, and rejects an unsigned client outside fallback mode **(HUMAN)** `[SAFETY]`

## Phase 8: Packaging and release

- [x] 8.1 Sign the app and helper with the personal-team certificate and package as a DMG or zip
  - Note: zip produced by `scripts/package.sh`, Apple silicon (arm64) only
- [x] 8.2 Write install instructions for unnotarized builds: "Open Anyway" in Privacy & Security (or `xattr -d com.apple.quarantine`), then approve the helper in Login Items
- [ ] 8.3 Test installation on a second Mac, on both Apple Silicon and Intel **(HUMAN)**
  - Note: Intel support dropped, Apple silicon only
- [ ] 8.3a OPTIONAL, public distribution only: sign with Developer ID, enable hardened runtime, notarize and staple **(HUMAN)** (needs the paid account and notarization credentials)
- [x] 8.4 Write the user guide, with the limits of overwrite stated plainly
- [ ] 8.5 Run a small beta on varied Macs and collect feedback **(HUMAN)**
- [ ] 8.6 Final release sign-off, confirming every `[SAFETY]` task is done **(HUMAN)**

---

## Release-blocking checklist

- [ ] Every `[SAFETY]` task above is complete
- [ ] Hardware tests 7.2 to 7.7 passed and recorded
- [ ] No open high-severity security findings
- [ ] Signed build (with helper) verified on a second Mac; notarized build verified only if public distribution was chosen
- [ ] Policy decisions 0.2, 0.3, 0.4 and 0.6 recorded
