# expo-sqlite-cloudkit

[![npm](https://img.shields.io/npm/v/expo-sqlite-cloudkit)](https://www.npmjs.com/package/expo-sqlite-cloudkit)
[![CI](https://github.com/lorenzpfei/expo-sqlite-cloudkit/actions/workflows/ci.yml/badge.svg)](https://github.com/lorenzpfei/expo-sqlite-cloudkit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/npm/l/expo-sqlite-cloudkit)](https://github.com/lorenzpfei/expo-sqlite-cloudkit/blob/main/LICENSE)

Sync the tables your Expo app already keeps in `expo-sqlite` to the user's private iCloud database, through Apple's `CKSyncEngine`. Your SQLite tables stay the source of truth: no new data layer, no server, no account system.

> Status: experimental. The API may change before 1.0.

## Why

- [SQLiteData](https://github.com/pointfreeco/sqlite-data) syncs SQLite through `CKSyncEngine`, but only for native Swift apps.
- [expo-cloudkit](https://www.npmjs.com/package/expo-cloudkit) uses `CKSyncEngine` for its own record store, not for your SQLite tables.
- [expo-cloudkit-bridge](https://www.npmjs.com/package/expo-cloudkit-bridge) wraps CloudKit calls without any sync logic.

This module fills the gap: triggers record every local change in an outbox, and a native `CKSyncEngine` adapter uploads them and applies remote changes back into the same tables.

## Quick start

Install it in a development build (Expo Go cannot load it):

```bash
npx expo install expo-sqlite expo-sqlite-cloudkit
```

Add the config plugin to `app.json`. It adds the iCloud container, the CloudKit and push entitlements and the `remote-notification` background mode:

```json
{
  "expo": {
    "ios": { "bundleIdentifier": "com.example.notes" },
    "plugins": [
      "expo-sqlite",
      ["expo-sqlite-cloudkit", { "containerIdentifier": "iCloud.com.example.notes" }]
    ]
  }
}
```

Create the container in the Apple Developer portal and enable iCloud with CloudKit and Push Notifications for your app ID. Then configure sync once your tables exist. This is the example app's setup:

```tsx
import { SQLiteProvider, type SQLiteDatabase } from 'expo-sqlite';
import { addChangeListener, configureSync, syncNow } from 'expo-sqlite-cloudkit';

const DATABASE_NAME = 'notes.db';

async function migrate(db: SQLiteDatabase) {
  await db.execAsync(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS notes (
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL DEFAULT '',
      updated_at INTEGER NOT NULL,
      deleted_at INTEGER
    );
  `);
  await configureSync({
    databaseName: DATABASE_NAME,
    containerIdentifier: 'iCloud.com.example.notes',
    tables: [
      {
        name: 'notes',
        primaryKey: ['id'],
        updatedAtColumn: 'updated_at',
        deletedAtColumn: 'deleted_at',
        encryptedColumns: ['body'],
      },
    ],
  });
}

export default function App() {
  return (
    <SQLiteProvider databaseName={DATABASE_NAME} onInit={migrate}>
      <Notes />
    </SQLiteProvider>
  );
}
```

Write to your tables as usual, and always set `updated_at`:

```ts
await db.runAsync('UPDATE notes SET title = ?, updated_at = ? WHERE id = ?', [title, Date.now(), id]);
```

Reload your queries when other devices change data:

```ts
useEffect(() => {
  const subscription = addChangeListener((tables) => {
    if (tables.includes('notes')) load();
  });
  return () => subscription.remove();
}, [load]);
```

Local changes go out on their own within a few seconds. Call `syncNow()` for an immediate round trip, for example on pull to refresh. The full app is in [`example/`](https://github.com/lorenzpfei/expo-sqlite-cloudkit/blob/main/example/App.tsx).

## API

| Function | What it does |
| --- | --- |
| `configureSync(config)` | Installs the sync tables and triggers (idempotent), queues existing rows on first run, and starts the sync engine. Call it on every launch after your migrations. |
| `syncNow()` | Fetches remote changes, then sends local ones. |
| `getStatus()` | `{ configured, account, syncing, pendingChanges, lastSyncAt, lastError }` |
| `addChangeListener(cb)` | `cb(tables)` after remote changes were written to those tables. |
| `addStatusListener(cb)` | `cb(status)` whenever the status changes. |
| `accountStatus()` | `'available' \| 'noAccount' \| 'restricted' \| 'couldNotDetermine' \| 'temporarilyUnavailable'` |
| `resetLocalSyncState()` | Forgets all sync state and uploads every row again. Local data is kept. |

`config.tables[]`:

| Field | |
| --- | --- |
| `name` | Table name. Becomes the CloudKit record type. |
| `primaryKey` | Column names, single or composite. |
| `updatedAtColumn` | Integer timestamp column used for conflicts. |
| `deletedAtColumn` | Optional soft-delete column. |
| `encryptedColumns` | Optional column list or `'all'`, stored in CloudKit's end-to-end encrypted fields. |

`databaseName` and an optional `directory` are the same values you pass to `expo-sqlite`.

## Data contract

- Every synced table has a primary key. Key columns are `TEXT` or `INTEGER` and never `NULL`.
- Every synced table has an integer `updated_at` column that your app sets on every insert and update. Seconds or milliseconds both work; use one unit per table on all devices.
- Soft deletes set `deleted_at` **and** bump `updated_at`. They sync like any other update.
- Hard deletes (`DELETE FROM …`) are supported and become CloudKit record deletions.
- Table and column names start with a letter and contain only letters, digits and underscores. CloudKit uses them as record types and field names.
- Keep columns of a table on one storage type (always `INTEGER`, always `REAL`, …). CloudKit fixes a field's type the first time it sees it.
- Schema changes: add columns freely. A device that does not know a column yet ignores it; a record without a column sets it to `NULL` (or leaves it alone if the column is `NOT NULL`).

The module adds `_sync_meta`, `_sync_outbox`, `_sync_records` and triggers named `_sync_<table>_<event>` to your database. Leave them alone.

## Conflict policy

- **Last writer wins per row**, by `updated_at`. There is no field-level merge.
- **Equal `updated_at`:** a soft-deleted row wins over a live one; otherwise the device that syncs its edit last wins. All devices converge.
- **Hard delete vs edit:** the delete wins, in both directions.
- **Account changes:** signing out keeps local data and pauses sync. Signing in with the same account resumes; a different account gets all local rows uploaded. If the iCloud data is reset or deleted, local rows are uploaded again. The module never deletes your rows on its own.

## Encrypted columns

Columns listed in `encryptedColumns` are written to `CKRecord.encryptedValues`, so Apple cannot read them. Choose them before the first sync and do not change them later: CloudKit rejects a field that switches between encrypted and plain. Record names contain the primary key values in plain text, so do not put secrets in keys.

## Limitations

- iOS 17 or newer (`CKSyncEngine`). Development builds only, not Expo Go.
- No Android, no web, no CloudKit sharing, no public database.
- Whole-row last writer wins; no field-level merges.
- Record names are limited to 255 characters, so keep primary keys short.
- Simulators cannot receive CloudKit pushes, so they only receive changes on launch and on `syncNow()` (see [docs/manual-test.md](https://github.com/lorenzpfei/expo-sqlite-cloudkit/blob/main/docs/manual-test.md)).

## How it compares

| | expo-sqlite-cloudkit | SQLiteData | expo-cloudkit |
| --- | --- | --- | --- |
| Platform | Expo / React Native (iOS) | Native Swift | Expo / React Native (iOS) |
| Your data lives in | Your own `expo-sqlite` tables | SQLite via GRDB | The module's own record store |
| Sync engine | `CKSyncEngine` | `CKSyncEngine` | `CKSyncEngine` |
| Changes to your data layer | None beyond `updated_at` | Adopt SQLiteData | Move data into the module |

## Development

```bash
pnpm install
pnpm test                 # SQL layer and config plugin, on Node's built-in SQLite
pnpm typecheck
pnpm swift:test:linux     # Swift sync core in Docker (or: cd packages/sync-core && swift test on a Mac)
```

The Swift sync core (`packages/sync-core`) has no CloudKit dependency and is tested with several simulated devices against an in-memory CloudKit stand-in. CI also runs it on macOS, unit-tests the `CKSyncEngine` adapter's pure parts and builds the example app for the iOS Simulator. Design decisions are in [docs/decisions.md](https://github.com/lorenzpfei/expo-sqlite-cloudkit/blob/main/docs/decisions.md).

To release, raise `version` in `packages/expo-sqlite-cloudkit/package.json`, commit, and publish a GitHub release tagged `v<version>`. The Release workflow tests the package and publishes it to npm with provenance.

## License

MIT
