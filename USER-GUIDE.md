# x-shredder user guide

x-shredder erases an SD card by overwriting all of it and then reading all of it back to check.

## What you need

- An SD or microSD card in the Mac's built-in SD card slot or in a USB card reader.
- The helper installed, approved and given Full Disk Access. See `INSTALL.md`.

The built-in SD card slot works on Apple silicon Macs that have one.

## Erasing a card

1. Insert the card. It appears under "Erasable cards".
2. Select it. Check the name and size.
3. Options:
   - The default is one pass of random data.
   - You can add a second pass of zeros.
   - Every pass is read back and checked. This cannot be turned off.
4. Click "Continue".
5. Read the warning. Everything on the card will be destroyed and cannot be recovered.
6. Type the size and name of the card exactly as shown, then click "Erase Card".
7. Wait. The app shows the pass, the phase (writing or verifying), the speed and the time remaining. Do not remove the card. Keep the Mac awake.
8. When it finishes, the result screen says whether the erase succeeded. You can export a signed report as PDF or JSON.

You can cancel while it runs. A cancelled card is partly overwritten and has not been verified. Do not treat it as erased.

## Why a disk is not selectable

Turn on "Show excluded disks" to see every other disk with the reason it is excluded. Excluded disks can never be erased by this app. There is no setting to change that.

A disk is selectable only if all of these are true:

- It is a whole disk, not a partition.
- It is not internal.
- It is not a disk image or other virtual disk.
- It is not the boot disk and does not hold system volumes.
- It is removable or ejectable.
- It is connected by USB or Secure Digital.
- It is 2 TB or smaller.
- It is writable. Check the write-protect switch on the side of the card.

If the app cannot read one of these facts about a disk, it treats that disk as excluded.

## If the erase fails

- **Verification failed on pass 1.** The data read back did not match what was written. The card may report more capacity than it really has (a counterfeit card), or it may be faulty. Do not treat the card as erased.
- **Write failed.** The card or reader returned an error and three retries did not help. If the card was removed or the Mac slept, insert the same card and start again. The erase continues from where it stopped, and the whole card is still verified.
- **Aborted by the safety guard.** The disk changed identity during the erase, for example the card was swapped. Nothing more is written.

## Limits of this method

The method is "Clear via overwrite, verified". That means every block the card exposes was overwritten and read back.

Overwrite cannot reach remapped or spare blocks. Physical destruction is recommended for high-sensitivity data.

The app does not use the SD erase commands and never claims "Purge".

## The report

The report lists the tool version, date and time, device model, size, serial number if the reader provides one, the passes, the verification result, any errors, the method label and the limits statement.

It is signed with an Ed25519 key that is created on first use and kept in your login keychain. The signature shows the report was not changed after it was made on this Mac.
