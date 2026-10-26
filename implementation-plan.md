# Implementation Plan: macOS Secure Disk Erase Tool (SD cards)

**Target:** macOS 13+ (needed for `SMAppService`), Apple Silicon and Intel
**Stack:** Swift, SwiftUI, DiskArbitration, IOKit, XPC privileged helper
**Erase method:** Full-range overwrite with read-back verification (NIST 800-88 "Clear"), reported honestly as such
**Distribution:** Built and run without Apple notarization, signed with a free personal-team certificate (Xcode with a free Apple ID). Notarized public release is an optional add-on (Phase 8, optional step).
**Marker:** Steps tagged **(HUMAN)** need a person's input, hardware, or sign-off and cannot be completed by automation alone.

---

## 1. Goals and non-goals

**Goals**
- Erase an external SD card (via USB reader) by full overwrite, then verify by reading back.
- Detect fake capacity before trusting the erase.
- Make it impossible for the user to select an internal disk, even by mistake or by tampering with the UI.
- Produce a signed erase report.

**Non-goals**
- No CMD38 or other raw SD commands (macOS has no public API for them). The tool never claims "Purge".
- No Mac App Store distribution (raw disk access is incompatible with the sandbox).
- No dependency on notarization or a paid Apple Developer account for the core build. Unnotarized builds are for personal use or a small trusted group, who must approve them manually past Gatekeeper.
- No erasing of internal disks, boot disks, disk images, or network volumes. This is a hard rule, not a setting.

---

## 2. Architecture

| Component | Runs as | Responsibility |
| --- | --- | --- |
| App (SwiftUI) | Normal user | Device list, options, confirmation, progress, report export |
| Helper (launch daemon) | root | Re-validates the disk, performs the erase, reports progress over XPC |
| Engine (Swift package) | Inside helper | `BlockDevice`, pattern generator, pass runner, verifier, checkpointing |
| DiskGuard (Swift package) | Shared by app and helper | Eligibility rules, the only code that decides if a disk is selectable |
| Report (Swift package) | App | Builds and signs the erase certificate |

The app never touches a raw device. It sends the helper a BSD name (for example `disk4`) and nothing else.

---

## 3. Internal-disk protection (design, highest priority)

This is enforced in three independent layers. A failure in any one layer must not be enough to erase an internal disk.

### Layer 1: Eligibility rules (DiskGuard)

A disk is selectable only if **every** rule passes. The check is an allowlist: anything unknown or missing fails closed.

1. It is a **whole disk** (`kDADiskDescriptionMediaWholeKey` is true), never a partition or slice.
2. `kDADiskDescriptionDeviceInternalKey` is **false**.
3. It is not virtual: protocol is not "Virtual Interface", it is not an APFS synthesized container or disk image.
4. It is not the **boot disk** and not the physical store behind any container that holds a mounted system, data, Preboot, Recovery or VM volume. Resolve this by walking from `/` and `/System/Volumes/Data` up to their physical whole disks.
5. Media is **removable or ejectable** (`kDADiskDescriptionMediaRemovableKey` or `kDADiskDescriptionMediaEjectableKey`).
6. Protocol is in an allowlist, initially `USB` and `Secure Digital`. Unknown protocols are refused.
7. Size is at most a configurable cap (default 2 TB).
8. Media is writable (not read-only, no write-protect).

Any key that cannot be read is treated as a failure of that rule.

**Known gotcha:** the built-in SD card slot on many Macs is reported as an *internal* device. Under rule 2 it will not be selectable. Decision (HUMAN): accept that users must use a USB card reader, or relax the rule for the built-in slot only. The default is the strict choice.

### Layer 2: UI

- Ineligible disks are not shown as selectable. An optional "Show excluded disks" view lists them greyed out with the reason (for example "Internal disk"), so users understand why.
- There is no "override" control, preference, or command-line flag in release builds.

### Layer 3: Helper re-validation

- The helper receives only a BSD name, never a path or a "trust me" flag.
- It re-runs the full DiskGuard check itself, using fresh DiskArbitration and IOKit data, immediately before acting.
- It captures an **identity fingerprint** (IORegistry entry ID, size, block size, protocol) at validation time.
- After unmounting and opening `/dev/rdiskN`, it checks the fingerprint again. If anything changed (for example the card was pulled and a different disk took the same name), the erase aborts. This closes the time-of-check/time-of-use gap.
- The helper only accepts XPC connections from a client with the expected code-signing requirement. In a personal-team build this pins the team ID and bundle ID. See Phase 4 for the weaker fallbacks if that cannot be made to work without notarization.
- A final unmissable guard: if the device resolves to the boot disk or reports internal at any point during the erase, abort and log.

---

## 4. Phases

### Phase 0: Decisions and accounts
- Sign in to Xcode with a free Apple ID so it creates a personal-team Apple Development certificate. **(HUMAN)**
- Decide the distribution scope: personal use only, a small trusted group, or public. **(HUMAN)**
- Optional, only for public distribution: paid Developer Program enrollment, Developer ID certificate, and notarization credentials. **(HUMAN)**
- Confirm the internal-slot policy (strict vs relaxed). **(HUMAN)**
- Confirm the allowed-protocol list, default size cap, and report wording. **(HUMAN)**
- Agree minimum macOS version.

### Phase 1: Project scaffolding
- Create the Xcode workspace with the app target, helper target, and three Swift packages (Engine, DiskGuard, Report).
- Set up CI to build and run unit tests on every commit.
- Establish logging (unified logging, no secrets in logs).
- Build an early hello-world signed with the personal-team certificate, with an embedded helper. Confirm `SMAppService` registration, the XPC connection, and the caller check all work without notarization. If any fail, choose a fallback from Phase 4 now rather than late in the project. **(HUMAN)** (needs a Mac with the helper approved in Login Items)

### Phase 2: DiskGuard (build this first)
- Enumerate disks with DiskArbitration and read their descriptions.
- Query IOKit for model, serial where available, and registry entry ID.
- Implement the eight eligibility rules as small, separately tested functions.
- Implement boot-disk resolution (APFS container to physical store to whole disk).
- Implement the identity fingerprint and comparison.
- Build a fixture layer so rules can be tested against recorded disk descriptions (internal SSD, boot disk, built-in SD slot, USB reader, USB hard drive, disk image, APFS synthesized container, missing keys).
- Exit criterion: an exhaustive test matrix shows every internal, virtual, boot and unknown case is rejected.

### Phase 3: Engine
- `BlockDevice`: open `/dev/rdiskN`, set `F_NOCACHE`, read geometry with `DKIOCGETBLOCKSIZE` and `DKIOCGETBLOCKCOUNT`, aligned buffers, `F_FULLFSYNC` flushes.
- Pattern generator: AES-CTR via CommonCrypto (or a ChaCha20 package), keyed per run, nonce derived from pass and block index so any block can be regenerated for verification.
- Pass runner: write loop with retry (3 attempts), then fail hard.
- Verifier: read-back compare against regenerated data, full range for pass 1 (this is the capacity check).
- Checkpointing: save progress and the encrypted run key; resume support; discard key on completion.
- Unit-test everything against a disk image or a file-backed fake `BlockDevice` first. No real disk is touched in this phase.

### Phase 4: Privileged helper
- Register the daemon with `SMAppService`.
- Define the XPC protocol: `listEligibleDisks`, `startErase(bsdName, options)`, `cancel`, progress callbacks.
- Implement caller validation, in order of preference:
  1. **Personal-team build (default):** code-signing requirement pinning team ID and bundle ID.
  2. **Ad-hoc build fallback:** there is no team ID, so pin the app's code directory hash (cdhash). This breaks on every rebuild and is weaker, so use it only if the default fails, and document the trade-off.
  3. **No-helper fallback:** a command-line build of the Engine and DiskGuard run with `sudo`. This gives up privilege separation, but DiskGuard's eligibility rules still apply in full.
- Implement unmount via DiskArbitration, exclusive open, fingerprint re-check, then hand over to the Engine.
- Handle cancel, card removal mid-erase, and helper crash (state marked as failed, never as success).

### Phase 5: GUI (SwiftUI)
- Device list with name, size, protocol, and reader details. Refreshes on disk arrival and removal.
- Options: passes (default one random pass), verification on (cannot be turned off), optional second zero pass.
- Confirmation: user must type the card's size and name exactly. Show a plain-language warning that all data will be destroyed.
- Progress view with phase (write, verify), throughput, time remaining, cancel.
- Result view: success or failure, with the honest method label ("Clear via overwrite, verified").
- Accessibility pass (VoiceOver, keyboard navigation).

### Phase 6: Reporting
- Report fields: tool version, date and time, device model, size, serial if available, passes, verification result, any errors, method label.
- Sign the report (Ed25519 or a Developer ID certificate) and export as PDF and JSON.
- Include a clear limits statement: overwrite cannot reach remapped or spare blocks, and physical destruction is recommended for high-sensitivity data.
- Review the report wording for compliance suitability. **(HUMAN)**

### Phase 7: Testing
- Unit and integration tests in CI (fake devices, disk images in a test-only build flag).
- **Safety tests on real hardware (HUMAN):** attempt to select or erase the internal SSD, the boot disk, an external USB hard drive holding system volumes, and the built-in SD slot. Every attempt must be refused at all three layers.
- **Real-card tests (HUMAN):** genuine SD and microSD cards from at least SanDisk and Sony, several sizes, via at least two different USB readers.
- **Counterfeit-card test (HUMAN):** a known fake-capacity card must fail the capacity check.
- Fault tests: pull the card mid-erase, kill the helper, fill with bad sectors if possible, sleep and wake the Mac.
- Independent security review of the helper and XPC boundary. **(HUMAN)**

### Phase 8: Packaging and release
- Sign the app and helper with the personal-team certificate and package as a DMG or zip.
- Write install instructions for unnotarized builds: allow the app via System Settings → Privacy & Security → "Open Anyway" (or remove the quarantine flag with `xattr -d com.apple.quarantine`), then approve the helper under Login Items.
- Test installation on a second Mac, Apple Silicon and Intel. **(HUMAN)**
- Write a short user guide with the limits of overwrite stated plainly.
- Beta with a small trusted group on varied Macs, collect feedback. **(HUMAN)**
- Final release sign-off. **(HUMAN)**
- **Optional, public distribution only:** sign with Developer ID, enable hardened runtime, notarize, and staple. Needs the paid account and notarization credentials. **(HUMAN)**

---

## 5. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Wrong disk erased | Three-layer protection (section 3), typed confirmation, fingerprint re-check |
| Built-in SD slot reported as internal | Strict policy by default, USB reader required; decision recorded |
| Disk name reused after card removal (TOCTOU) | Identity fingerprint compared after open |
| Fake-capacity cards | Full-range seeded write and read-back on pass 1 |
| Overstating security | Fixed method label, limits statement in every report |
| Helper abused by another process | Code-signing check on XPC clients, BSD-name-only API |
| Controller cache hides write failures | `F_NOCACHE`, `F_FULLFSYNC`, verification after cache drop |
| Helper registration or caller check fails under personal-team or ad-hoc signing | Test a signed hello-world with helper in Phase 1; fall back to cdhash pinning or the `sudo` CLI |
| Recipients blocked by Gatekeeper on an unnotarized build | Ship install instructions; notarize later if distribution widens |

---

## 6. Definition of done

- All unit and integration tests pass in CI.
- Every internal, boot, virtual and unknown-disk test case is refused at all three layers, including on real hardware.
- Verified erases succeed on the real-card test set; the counterfeit card is detected.
- The security review has no open high-severity findings.
- A personal-team-signed build installs and runs, including the helper, on a second Mac following the install instructions. A notarized build is required only if public distribution was chosen.
- Human sign-offs recorded for policy decisions, report wording, and release.
