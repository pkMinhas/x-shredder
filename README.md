# x-shredder

A macOS app that erases an SD card (in the Mac's built-in SD card slot or a USB card reader) by overwriting all of it and then reading all of it back to check. The method is NIST 800-88 "Clear" via overwrite, and the app reports it as exactly that. It produces a signed erase report.

The app never erases internal disks, boot disks, disk images or network volumes. This is a hard rule, not a setting.

Requires macOS 13 or later on an Apple silicon Mac. Intel Macs are not supported.

## Status

Built and tested locally. Not yet tested on real SD cards, card readers or the built-in SD card slot, and the helper has not yet been run as an approved launch daemon. See `task-list.md` for what is done and what still needs a person (hardware tests, policy decisions, reviews and sign-off).

## How it works

| Component | Runs as | Responsibility |
| --- | --- | --- |
| App (SwiftUI) | Normal user | Device list, options, confirmation, progress, report export |
| Helper (launch daemon) | root | Re-validates the disk, performs the erase, reports progress over XPC |
| Engine (Swift package) | Inside helper | Raw block device, pattern generator, write and verify passes, checkpointing |
| DiskGuard (Swift package) | App and helper | Eligibility rules, the only code that decides if a disk is selectable |
| Report (Swift package) | App | Builds, signs and exports the erase report |

The app never touches a raw device. It sends the helper a BSD name (for example `disk4`) and nothing else.

### Internal-disk protection

Enforced in three independent layers:

1. **Eligibility rules (DiskGuard).** A disk is selectable only if every rule passes: whole disk, not internal (except the built-in SD card slot, see below), not virtual or a disk image, not the boot disk or behind a mounted system container, removable or ejectable, protocol in the allowlist (`USB`, `Secure Digital`), at most 2 TB, writable. Any value that cannot be read counts as a failure.
2. **UI.** Only eligible disks can be selected. Excluded disks can be shown greyed out with the reason. There is no override.
3. **Helper.** Accepts only a BSD name from a caller signed by the same team with the app's bundle ID. It re-runs DiskGuard on fresh data, captures an identity fingerprint, unmounts, opens the device exclusively, checks the fingerprint again, and aborts if the device ever resolves to the boot disk or an internal disk during the erase.

### Built-in SD card slot

macOS reports the built-in SD card slot as an internal device. The "not internal" rule makes one exception for it: a disk passes that rule if it is internal, its protocol is `Secure Digital`, it is not layered or virtual, and it sits directly under Apple's SDXC driver (`AppleSDXCBlockStorageDevice`, `AppleSDXCSlot`, `AppleSDXC`). Every other rule still applies to it, including the boot-disk, removable, size and write-protect rules. The helper's in-flight guard uses the same exception.

### Erase

- Pass 1 writes AES-CTR random data across the whole card and reads it all back. This also detects fake-capacity cards.
- An optional second pass writes zeros and reads them back.
- Verification cannot be turned off.
- Writes are retried 3 times, then the erase fails.
- Progress is checkpointed so an interrupted erase can resume. A cancelled, failed or interrupted run is never reported as a success.

### Report

JSON and PDF, signed with Ed25519. It includes the tool version, date and time, device model, size, serial if available, passes, verification result, errors and the method label. It states the limits of overwrite: remapped and spare blocks cannot be reached, and physical destruction is recommended for high-sensitivity data.

## Repository layout

```
x-shredder/
  x-shredder.xcodeproj
  x-shredder/            App (SwiftUI)
  x-shredder-helper/     Privileged helper
  Shared/                XPC protocol and constants used by app and helper
  HelperSupport/         launchd plist for the helper
  Packages/DiskGuard/    Eligibility rules, fixtures and the diskguard-dump tool
  Packages/Engine/       Erase engine
  Packages/Report/       Erase report
  x-shredderTests/
scripts/                 Test, lint, release-flag and packaging scripts
.github/workflows/       CI
INSTALL.md               Installing an unnotarized build
USER-GUIDE.md            Using the app
implementation-plan.md   Design
task-list.md             Task status
```

## Building

Open `x-shredder/x-shredder.xcodeproj` in Xcode and build the `x-shredder` scheme. Signing uses a personal-team (free Apple ID) certificate. The build is not notarized.

Debug builds also list small scratch disk images (256 MB or less) as erasable, for testing. This is compiled out of Release builds.

## Testing

```
scripts/test-all.sh
```

Runs the safety lint, the tests for all three packages, the app tests and the release-flag check. Set `XSHREDDER_DISK_IMAGE_TESTS=1` to also run the tests that attach a small scratch disk image.

To print the disk descriptions DiskGuard sees on your Mac (read-only):

```
cd x-shredder/Packages/DiskGuard
swift run diskguard-dump
```

## Packaging

```
scripts/package.sh
```

Builds an Apple silicon (arm64) Release app, checks that the app and helper are arm64 only and signed by the same team, and writes `dist/x-shredder-<version>.zip`.

## Installing and using

See `INSTALL.md` for getting past Gatekeeper and approving the helper in Login Items, and `USER-GUIDE.md` for erasing a card.

## License

MIT. See `LICENSE`.
