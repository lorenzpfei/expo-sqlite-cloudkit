import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { describe, test } from 'node:test';

import { buildSchema, installSchema, type SqlExecutor, type TableSyncConfig } from './schema.ts';
import { commitHealth, notes, type Fixture } from './test/fixtures.ts';

type OutboxRow = { table_name: string; pk_json: string; op: string; version: number };

function open(fixture: Fixture): DatabaseSync {
  const db = new DatabaseSync(':memory:');
  for (const statement of fixture.ddl) db.exec(statement);
  return db;
}

function executor(db: DatabaseSync): SqlExecutor {
  return {
    exec: async (sql) => {
      db.exec(sql);
    },
    getFirst: async <T>(sql: string) => (db.prepare(sql).get() as T | undefined) ?? null,
    getAll: async <T>(sql: string) => db.prepare(sql).all() as T[],
  };
}

async function install(db: DatabaseSync, tables: readonly TableSyncConfig[]): Promise<boolean> {
  return installSchema(executor(db), buildSchema(tables));
}

function outbox(db: DatabaseSync): OutboxRow[] {
  return db
    .prepare('SELECT table_name, pk_json, op, version FROM _sync_outbox ORDER BY table_name, pk_json')
    .all()
    .map((row) => ({ ...row }) as OutboxRow);
}

function triggerNames(db: DatabaseSync): string[] {
  return (
    db.prepare("SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name").all() as { name: string }[]
  ).map((row) => row.name);
}

describe('notes table', () => {
  test('insert enqueues an upsert', async () => {
    const db = open(notes);
    await install(db, notes.tables);
    db.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Hello', 1)");
    assert.deepEqual(outbox(db), [{ table_name: 'notes', pk_json: '["n1"]', op: 'upsert', version: 1 }]);
  });

  test('update collapses into the pending entry and bumps its version', async () => {
    const db = open(notes);
    await install(db, notes.tables);
    db.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Hello', 1)");
    db.exec("UPDATE notes SET title = 'Changed', updated_at = 2 WHERE id = 'n1'");
    db.exec("UPDATE notes SET title = 'Again', updated_at = 3 WHERE id = 'n1'");
    assert.deepEqual(outbox(db), [{ table_name: 'notes', pk_json: '["n1"]', op: 'upsert', version: 3 }]);
  });

  test('soft delete is an ordinary upsert', async () => {
    const db = open(notes);
    await install(db, notes.tables);
    db.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Hello', 1)");
    db.exec('DELETE FROM _sync_outbox');
    db.exec("UPDATE notes SET deleted_at = 5, updated_at = 5 WHERE id = 'n1'");
    assert.deepEqual(outbox(db), [{ table_name: 'notes', pk_json: '["n1"]', op: 'upsert', version: 1 }]);
  });

  test('hard delete turns the pending entry into a delete', async () => {
    const db = open(notes);
    await install(db, notes.tables);
    db.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Hello', 1)");
    db.exec("DELETE FROM notes WHERE id = 'n1'");
    assert.deepEqual(outbox(db), [{ table_name: 'notes', pk_json: '["n1"]', op: 'delete', version: 2 }]);
  });

  test('re-inserting after a hard delete becomes an upsert again', async () => {
    const db = open(notes);
    await install(db, notes.tables);
    db.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Hello', 1)");
    db.exec("DELETE FROM notes WHERE id = 'n1'");
    db.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Back', 2)");
    assert.deepEqual(outbox(db), [{ table_name: 'notes', pk_json: '["n1"]', op: 'upsert', version: 3 }]);
  });

  test('INSERT OR REPLACE enqueues a single upsert', async () => {
    const db = open(notes);
    await install(db, notes.tables);
    db.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Hello', 1)");
    db.exec("INSERT OR REPLACE INTO notes (id, title, updated_at) VALUES ('n1', 'Replaced', 2)");
    assert.deepEqual(outbox(db), [{ table_name: 'notes', pk_json: '["n1"]', op: 'upsert', version: 2 }]);
  });

  test('writes are not enqueued while applying remote changes', async () => {
    const db = open(notes);
    await install(db, notes.tables);
    db.exec("UPDATE _sync_meta SET value = '1' WHERE key = 'applying'");
    db.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Remote', 1)");
    db.exec("UPDATE notes SET title = 'Remote 2' WHERE id = 'n1'");
    db.exec("DELETE FROM notes WHERE id = 'n1'");
    assert.deepEqual(outbox(db), []);

    db.exec("UPDATE _sync_meta SET value = '0' WHERE key = 'applying'");
    db.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n2', 'Local', 1)");
    assert.deepEqual(outbox(db), [{ table_name: 'notes', pk_json: '["n2"]', op: 'upsert', version: 1 }]);
  });

  test('integer primary keys are stored as text', async () => {
    const db = new DatabaseSync(':memory:');
    db.exec('CREATE TABLE items (id INTEGER PRIMARY KEY, updated_at INTEGER NOT NULL)');
    await install(db, [{ name: 'items', primaryKey: ['id'], updatedAtColumn: 'updated_at' }]);
    db.exec('INSERT INTO items (id, updated_at) VALUES (42, 1)');
    assert.deepEqual(outbox(db), [{ table_name: 'items', pk_json: '["42"]', op: 'upsert', version: 1 }]);
  });
});

describe('composite keys', () => {
  test('both key columns end up in pk_json', async () => {
    const db = open(commitHealth);
    await install(db, commitHealth.tables);
    db.exec(
      "INSERT INTO intake_items (user_id, id, name, unit, kind, updated_at) VALUES ('local', 'i1', 'Ibuprofen', 'mg', 'medication', 100)",
    );
    assert.deepEqual(outbox(db), [
      { table_name: 'intake_items', pk_json: '["local","i1"]', op: 'upsert', version: 1 },
    ]);
  });

  test('changing a key column deletes the old record and upserts the new one', async () => {
    const db = open(commitHealth);
    await install(db, commitHealth.tables);
    db.exec(
      "INSERT INTO intake_items (user_id, id, name, unit, kind, updated_at) VALUES ('local', 'i1', 'Ibuprofen', 'mg', 'medication', 100)",
    );
    db.exec('DELETE FROM _sync_outbox');
    db.exec("UPDATE intake_items SET user_id = 'u-42' WHERE id = 'i1'");
    assert.deepEqual(outbox(db), [
      { table_name: 'intake_items', pk_json: '["local","i1"]', op: 'delete', version: 1 },
      { table_name: 'intake_items', pk_json: '["u-42","i1"]', op: 'upsert', version: 1 },
    ]);
  });

  test('tables with the same key shape stay apart', async () => {
    const db = open(commitHealth);
    await install(db, commitHealth.tables);
    db.exec("INSERT INTO health_days (user_id, day, steps) VALUES ('local', '2026-11-07', 9000)");
    db.exec("INSERT INTO sleep_days (user_id, day, core_ms) VALUES ('local', '2026-11-07', 7200000)");
    assert.deepEqual(outbox(db), [
      { table_name: 'health_days', pk_json: '["local","2026-11-07"]', op: 'upsert', version: 1 },
      { table_name: 'sleep_days', pk_json: '["local","2026-11-07"]', op: 'upsert', version: 1 },
    ]);
  });
});

describe('install', () => {
  test('backfills existing rows on first configure', async () => {
    const db = open(commitHealth);
    db.exec(
      "INSERT INTO pain_episodes (user_id, id, type, day, started_at) VALUES ('local', 'p1', 'migraine', '2026-11-01', '2026-11-01T08:00:00Z'), ('local', 'p2', 'headache', '2026-11-02', '2026-11-02T08:00:00Z')",
    );
    db.exec(
      "INSERT INTO diary_entries (user_id, id, day, written_at, body, deleted_at) VALUES ('local', 'd1', '2026-11-01', '2026-11-01T20:00:00Z', 'Tired', 1762000000)",
    );
    assert.equal(await install(db, commitHealth.tables), true);
    assert.deepEqual(outbox(db), [
      { table_name: 'diary_entries', pk_json: '["local","d1"]', op: 'upsert', version: 1 },
      { table_name: 'pain_episodes', pk_json: '["local","p1"]', op: 'upsert', version: 1 },
      { table_name: 'pain_episodes', pk_json: '["local","p2"]', op: 'upsert', version: 1 },
    ]);
  });

  test('re-installing the same config is a no-op', async () => {
    const db = open(notes);
    db.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Hello', 1)");
    assert.equal(await install(db, notes.tables), true);
    const triggers = triggerNames(db);
    db.exec('DELETE FROM _sync_outbox');

    assert.equal(await install(db, notes.tables), false);
    assert.deepEqual(triggerNames(db), triggers);
    assert.deepEqual(outbox(db), []);
  });

  test('a changed config recreates triggers without backfilling tables twice', async () => {
    const db = open(commitHealth);
    db.exec("INSERT INTO health_days (user_id, day) VALUES ('local', '2026-11-01')");
    db.exec("INSERT INTO sleep_days (user_id, day) VALUES ('local', '2026-11-01')");
    await install(db, commitHealth.tables.filter((table) => table.name === 'health_days'));
    assert.deepEqual(triggerNames(db), ['_sync_health_days_delete', '_sync_health_days_insert', '_sync_health_days_update']);
    db.exec('DELETE FROM _sync_outbox');

    assert.equal(await install(db, commitHealth.tables.filter((table) => table.name === 'sleep_days')), true);
    assert.deepEqual(triggerNames(db), ['_sync_sleep_days_delete', '_sync_sleep_days_insert', '_sync_sleep_days_update']);
    assert.deepEqual(outbox(db), [
      { table_name: 'sleep_days', pk_json: '["local","2026-11-01"]', op: 'upsert', version: 1 },
    ]);

    db.exec("UPDATE health_days SET steps = 1 WHERE day = '2026-11-01'");
    assert.equal(outbox(db).length, 1);
  });

  test('keeps app triggers that do not belong to the sync layer', async () => {
    const db = open(notes);
    db.exec("CREATE TRIGGER notes_audit AFTER INSERT ON notes BEGIN SELECT 1; END");
    await install(db, notes.tables);
    assert.ok(triggerNames(db).includes('notes_audit'));
  });

  test('rejects a missing table or column and leaves the database untouched', async () => {
    const db = open(notes);
    await assert.rejects(
      install(db, [{ name: 'missing', primaryKey: ['id'], updatedAtColumn: 'updated_at' }]),
      /table "missing" does not exist/,
    );
    await assert.rejects(
      install(db, [{ name: 'notes', primaryKey: ['id'], updatedAtColumn: 'modified' }]),
      /column "modified" does not exist in table "notes"/,
    );
    assert.deepEqual(triggerNames(db), []);
    assert.equal(db.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name = '_sync_outbox'").get()?.n, 0);
  });

  test('rejects identifiers CloudKit cannot store', () => {
    assert.throws(
      () => buildSchema([{ name: '_private', primaryKey: ['id'], updatedAtColumn: 'updated_at' }]),
      /table name "_private" must start with a letter/,
    );
    assert.throws(
      () => buildSchema([{ name: 'notes', primaryKey: [], updatedAtColumn: 'updated_at' }]),
      /needs at least one primary key column/,
    );
    assert.throws(
      () =>
        buildSchema([
          { name: 'notes', primaryKey: ['id'], updatedAtColumn: 'updated_at' },
          { name: 'notes', primaryKey: ['id'], updatedAtColumn: 'updated_at' },
        ]),
      /duplicate table "notes"/,
    );
  });
});

describe('reset', () => {
  test('clears sync state and queues every row again', async () => {
    const db = open(notes);
    await install(db, notes.tables);
    db.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'One', 1), ('n2', 'Two', 1)");
    db.exec("DELETE FROM notes WHERE id = 'n2'");
    db.exec("INSERT INTO _sync_records (record_name, table_name, system_fields) VALUES ('notes|n1', 'notes', x'00')");

    for (const statement of buildSchema(notes.tables).resetSql) db.exec(statement);

    assert.deepEqual(outbox(db), [{ table_name: 'notes', pk_json: '["n1"]', op: 'upsert', version: 1 }]);
    assert.equal(db.prepare('SELECT count(*) AS n FROM _sync_records').get()?.n, 0);
  });
});
