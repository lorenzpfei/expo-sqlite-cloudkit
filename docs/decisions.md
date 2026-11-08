# Decisions

Design decisions behind v1, with the reason for each.

## Repository and tooling

- **pnpm workspace, hoisted `node_modules`.** `nodeLinker: hoisted` in `pnpm-workspace.yaml` keeps Expo autolinking, Metro and CocoaPods on the most tested path for monorepos.
- **TypeScript runs directly on Node 24.** Sources use `.ts` import specifiers and erasable syntax only, so `node --test` executes them without a build step. `tsc` rewrites the specifiers when it emits `build/`. No Jest.
- **Config plugin snapshots use `node:test` snapshots** (`t.assert.snapshot`). Update them with `node --test --test-update-snapshots`.
- **Swift tests on Linux run in Docker.** A host toolchain needs system packages (`libsqlite3-dev` and others) that are not always installable without root. `scripts/swift-test-linux.sh` runs `swift test` in the official `swift:6.2` image with `libsqlite3-dev` added. CI's Linux job runs the same script.

## Package layout

- **The Swift core lives inside the npm package.** CocoaPods cannot reference files outside the pod directory, and npm cannot publish symlinks reliably. So the real files are in `packages/expo-sqlite-cloudkit/ios/SyncCore` and `ios/CloudKit`, and `packages/sync-core/Sources/{SyncCore,SyncCloudKit}` are symlinks to them. SwiftPM follows the symlinks; the pod compiles the same files into one module.
- **`SyncCore` never imports CloudKit or SQLite headers.** It talks to SQLite through `SQLiteFunctions`, a table of C function pointers. Tests pass the system SQLite (`SystemSQLite` target); the iOS module passes the `exsqlite3_*` functions that `expo-sqlite` exports.
- **The iOS module uses expo-sqlite's SQLite copy, not the system library.** Two SQLite copies in one process do not share POSIX lock bookkeeping, so they can corrupt a database they both open (see sqlite.org/howtocorrupt.html, section 2.2.1). `expo-sqlite` vendors SQLite with every symbol renamed to `exsqlite3_*`; linking against those keeps a single copy.
- **`SyncCloudKit` is a separate SwiftPM target** whose files are wrapped in `#if canImport(CloudKit)`. On Linux it compiles to nothing; on macOS its pure parts (field mapping, error policy) are unit tested.

## SQL layer

- **Install runs in TypeScript through `expo-sqlite`.** `configureSync` opens a second connection with `useNewConnection: true`, installs in one `BEGIN IMMEDIATE` transaction, and closes it. The same function is tested against `node:sqlite`, so the production install path is the tested one.
- **The schema version is the normalized config itself** (`{"format":1,"tables":[…]}`) stored under `_sync_meta.schema_version`. Any config change reinstalls; an unchanged config is a no-op.
- **Reinstall drops every trigger named `_sync_*`** before creating the current ones, so tables removed from the config stop being tracked.
- **Backfill is per table** and guarded by a `backfilled:<table>` meta key, so a table added to the config later gets backfilled once and existing tables are not queued again.
- **`_sync_outbox` has an extra `version` column.** It increases on every collapsed write. An entry is removed only if the confirmed version is still the current one, so an edit made while a record is in flight is not lost. `changed_at` is kept for ordering.
- **`pk_json` stores every key as text** (`json_array(CAST(col AS TEXT), …)`). This makes record names and outbox keys a bijection without type information. Primary key columns must therefore be `TEXT` or `INTEGER`.
- **A primary key change in an `UPDATE`** enqueues a delete for the old key and an upsert for the new one.
- **`_sync_records(record_name, table_name, system_fields)`** stores the CloudKit system fields (change tag) per record. Without them every save of an existing record would hit `serverRecordChanged` first.
- **Identifiers must match `^[A-Za-z][A-Za-z0-9_]*$`** because table names become CloudKit record types and column names become field names.

## Records and conflicts

- **Record names include the table name:** `table|pk1|pk2`, each part percent-encoded. CloudKit record IDs are unique per zone across all record types, and two tables can share a key shape, for example `health_days` and `sleep_days` both keyed by `(user_id, day)`. Without the table name their records would overwrite each other.
- **Last writer wins by `updated_at`,** compared as numbers regardless of unit. The unit only has to be consistent per table, so there is no unit option.
- **Ties are broken by content.** Both sides of a conflict share the same record name, so a name-based tie-breaker cannot decide. On equal `updated_at`: a soft-deleted side wins over a live one; otherwise the device that still has an unsent edit wins, so the last device to sync wins and all devices converge. This also keeps a second edit in the same second from being overwritten by the echo of the first.
- **Hard deletes win over concurrent edits.** CloudKit deletions carry no timestamp. An incoming save for a row with a pending local delete is skipped and the delete is sent; an incoming delete removes the row and drops any pending local edit.
- **Missing fields:** a field absent from an incoming record becomes `NULL`, except for `NOT NULL` columns, which keep their current value on update and their default on insert. Fields unknown to the local schema are ignored.
- **Every column is sent on every save,** including `NULL` ones, so clearing a value reaches other devices.

## CKSyncEngine adapter

- **Zone `SQLiteSync` in the private database,** created through a pending database change when there is no saved engine state.
- **Engine state is stored in `_sync_meta.engine_state`** (base64 of the JSON-encoded `CKSyncEngine.State.Serialization`).
- **Error handling:** `serverRecordChanged` merges with last writer wins and re-queues if the local copy wins; `zoneNotFound` recreates the zone, forgets all change tags and re-queues; `unknownItem` forgets the change tag and waits for the next fetch (which either delivers the deletion or re-uploads); `quotaExceeded` and unexpected errors are reported in `lastError` and retried on the next sync; network and throttling errors are left to the engine's own retry.
- **`syncNow()` runs its own zone fetch after `CKSyncEngine.fetchChanges()`.** On a device and in the Simulator, the engine's manual fetch returned within a millisecond without contacting the server when no push had arrived, so records saved by another device stayed missing until the next app launch. `syncNow()` therefore also calls `CKDatabase.recordZoneChanges` with its own change token, stored next to the engine state in `_sync_meta.engine_state`. Records that arrive through both paths are applied twice, which last writer wins makes harmless.
- **Local changes reach the engine by polling `PRAGMA data_version` every 2 seconds** while the app runs. The value changes whenever another connection (the app's) commits, costs microseconds, and needs nothing from the app. `syncNow()` is still available for an immediate sync.
- **Account changes:** sign-out keeps all local data and pauses syncing; local edits keep queueing. Signing in again with the same account resumes. Signing in with a different account (directly or after a sign-out) clears sync state, re-queues every row and starts a fresh engine, so the new account receives the data. The last user record name is stored in `_sync_meta.account_user`.
- **A deleted zone** (user reset, encrypted data reset or purge) is handled like an account switch: local data stays and is uploaded again. The app's database is the source of truth, and the library never deletes app rows on its own.

## Expo module

- **iOS deployment target stays 16.4** like the Expo template; everything that needs `CKSyncEngine` is `@available(iOS 17, *)` and `configure` throws on older systems. Android and web get a clear error from the JS API instead of a crash at import.
- **Config plugin options:** `containerIdentifier` (required, must start with `iCloud.`) and `apsEnvironment` (default `development`, an existing value is kept). It adds the container, the `CloudKit` service, `aps-environment` and the `remote-notification` background mode.
- **The example app reads its bundle ID, team ID and iCloud container from `example/.env`** (see `example/.env.example`), so anyone can run it with their own Apple setup and nothing personal lives in the repository. Without a `.env` it builds with `com.example.syncnotes` placeholders, which is what CI does.
