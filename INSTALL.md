# Installing x-shredder (unnotarized build)

This build is signed with a personal-team certificate and is not notarized by Apple. macOS will not open it until you approve it yourself. It is meant for personal use or a small trusted group.

Requires macOS 13 or later. Works on Apple Silicon and Intel Macs.

## 1. Put the app in Applications

Unzip `x-shredder-<version>.zip` and move `x-shredder.app` to `/Applications`.

Do this before installing the helper. The helper is registered at the app's location, so moving the app afterwards breaks the registration.

## 2. Allow the app past Gatekeeper

Either:

- Open the app once. macOS refuses to open it. Go to System Settings → Privacy & Security, scroll to the message about x-shredder, and click "Open Anyway".

Or:

- Remove the quarantine flag in Terminal:

  ```
  xattr -d com.apple.quarantine /Applications/x-shredder.app
  ```

## 3. Install and approve the helper

Erasing needs a helper that runs with administrator rights.

1. Open x-shredder and click "Install Helper".
2. Open System Settings → General → Login Items.
3. Under "Allow in the Background", turn on x-shredder.
4. Go back to x-shredder. The helper notice disappears once it is approved.

## Removing it

1. In x-shredder, choose "Remove Helper" from the x-shredder menu.
2. Delete `/Applications/x-shredder.app`.
3. Optional: delete `/Library/Application Support/com.withpreet.x-shredder` (needs an administrator). It holds the helper's journal of the last run and the resume checkpoint.

## Building from source

1. Open `x-shredder/x-shredder.xcodeproj` in Xcode, signed in with your Apple ID.
2. Select your own team for both the `x-shredder` and `x-shredder-helper` targets. The app and the helper must be signed by the same team, or they refuse to talk to each other.
3. Build and run.

To build a zip for someone else: `scripts/package.sh`. The zip is written to `dist/`.

Debug builds also list small scratch disk images as erasable, for testing without a card. Release builds do not contain that code.
