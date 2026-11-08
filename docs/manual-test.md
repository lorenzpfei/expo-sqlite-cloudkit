# Manual test: two devices, real iCloud

About 10 minutes. This is the only test that touches real CloudKit; everything else runs in CI.

## Before you start

- In the Apple Developer portal, create an iCloud container (for example `iCloud.com.yourname.syncnotes`) and an app ID (`com.yourname.syncnotes`) with **iCloud** (CloudKit, that container selected) and **Push Notifications** enabled.
- Copy `example/.env.example` to `example/.env` and fill in the bundle ID, your team ID and the container.
- Two iOS 17+ devices signed in to the **same** iCloud account, with iCloud Drive turned on. One iPhone plus the iOS Simulator works too, see below.

Build and install on each device from your Mac:

```bash
git clone https://github.com/lorenzpfei/expo-sqlite-cloudkit.git
cd expo-sqlite-cloudkit
pnpm install
pnpm build
cd example
cp .env.example .env
npx expo run:ios --device
```

Pick the device when asked, then repeat for the second device. If signing fails with "No profiles for … were found", open `ios/SyncNotes.xcworkspace` in Xcode once and let automatic signing create the profile under Signing & Capabilities. Keep Metro running (`pnpm start` in `example/`) while you test.

The header shows `iCloud: <account> · last sync <time> · <n> pending`. Tap **Sync now** whenever a step says "sync"; changes also go out on their own within a few seconds.

In the list, tap a note to edit it. **Delete** is a soft delete (sets `deleted_at`), **long-press Delete** is a hard delete (removes the row).

## One iPhone plus the Simulator

Sign in to iCloud with the same Apple ID in the Simulator's Settings, then run `npx expo run:ios` and pick a simulator. Two differences:

- The Simulator does not receive CloudKit pushes. Tap **Sync now** on it to fetch changes from the iPhone.
- The Simulator has no airplane mode. Do the offline parts on the iPhone only; the conflicts are the same.

To watch what the sync engine does, stream the module's log:

```bash
xcrun simctl spawn booted log stream --level info --predicate 'subsystem == "expo-sqlite-cloudkit"'
```

On an iPhone, use Console.app with the device selected, **Action → Include Info Messages** on, and the search set to Subsystem `expo-sqlite-cloudkit`.

## Checklist

Call the devices A and B.

1. **First launch.** Open the app on A and B. Both show `iCloud: available` and no error line.
2. **Basic sync.** On A, add "Milk". Within a few seconds (or after Sync now on B), B shows "Milk". `pending` returns to 0 on A.
3. **Edit.** On B, rename "Milk" to "Oat milk". A shows "Oat milk".
4. **Offline edits on both.** Turn on airplane mode on A and B. On A add "From A" and rename "Oat milk" to "A's milk". On B add "From B" and, a few seconds later, rename the same note to "B's milk". `pending` grows on both. Turn airplane mode off on both, sync both twice. Both show "From A", "From B" and "B's milk" (B's edit was later, so it wins).
5. **Delete vs edit.** On A turn on airplane mode, long-press **Delete** on "From B" (hard delete). On B rename "From B" to "Edited". Turn airplane mode off on A, sync both twice. The note is gone on both devices: hard deletes win over concurrent edits.
6. **Soft delete.** On B, tap **Delete** on "From A". It disappears on A.
7. **Airplane-mode recovery.** On A turn on airplane mode, add three notes, force-quit the app, reopen it (still offline): the notes are there and `pending` is 3. Turn airplane mode off and wait without tapping anything. B receives all three within about a minute.
8. **Signing out of iCloud.** On B open Settings → your name → Sign Out (keep a copy of data if asked). Open the app: the notes are still there and the header shows `iCloud: noAccount`. Add "While signed out". Sign back in with the same account, open the app, sync. A receives "While signed out".
9. **First sync of a device that already has data.** On B delete the app, then install it again from your Mac but do **not** open it yet. On A turn on airplane mode. Open the app on B and add "Fresh install" before it has synced (or in airplane mode). Turn airplane mode off on both and sync both twice. Both devices show every note from A plus "Fresh install", with no duplicates.

## When something fails

- Note the step, the header line on both devices, and any red error text under it.
- CloudKit Console (icloud.developer.apple.com) → your container → Development → Records → zone `SQLiteSync` shows what reached the server. Record names look like `notes|<id>`.
- To start over on a device, delete the app; to start over in iCloud, reset the Development environment in CloudKit Console.
