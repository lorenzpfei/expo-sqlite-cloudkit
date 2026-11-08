export type TableSyncConfig = {
  name: string;
  primaryKey: readonly string[];
  updatedAtColumn: string;
  deletedAtColumn?: string;
  encryptedColumns?: readonly string[] | 'all';
};

export type SyncTable = {
  name: string;
  primaryKey: string[];
  updatedAtColumn: string;
  deletedAtColumn: string | null;
  encryptedColumns: string[] | 'all';
};

export type SyncSchema = {
  version: string;
  tables: SyncTable[];
  installSql: string[];
  resetSql: string[];
};

export type SqlExecutor = {
  exec(sql: string): Promise<void>;
  getFirst<T>(sql: string): Promise<T | null>;
  getAll<T>(sql: string): Promise<T[]>;
};

const FORMAT = 1;
const IDENTIFIER = /^[A-Za-z][A-Za-z0-9_]*$/;
const NOW_MS = "CAST(unixepoch('subsec') * 1000 AS INTEGER)";
const NOT_APPLYING = "(SELECT value FROM _sync_meta WHERE key = 'applying') IS NOT '1'";

export function buildSchema(configs: readonly TableSyncConfig[]): SyncSchema {
  const tables = configs.map(normalizeTable);
  assertUnique(tables.map((table) => table.name), 'table');

  const installSql = [
    'CREATE TABLE IF NOT EXISTS _sync_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT)',
    "INSERT OR IGNORE INTO _sync_meta (key, value) VALUES ('applying', '0')",
    "CREATE TABLE IF NOT EXISTS _sync_outbox (table_name TEXT NOT NULL, pk_json TEXT NOT NULL, op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')), changed_at INTEGER NOT NULL, version INTEGER NOT NULL DEFAULT 1, PRIMARY KEY (table_name, pk_json)) WITHOUT ROWID",
    'CREATE TABLE IF NOT EXISTS _sync_records (record_name TEXT PRIMARY KEY NOT NULL, table_name TEXT NOT NULL, system_fields BLOB NOT NULL) WITHOUT ROWID',
    ...tables.flatMap((table) => [
      ...triggerSql(table),
      `${backfillSql(table)} AND NOT EXISTS (SELECT 1 FROM _sync_meta WHERE key = ${literal(`backfilled:${table.name}`)}) ON CONFLICT (table_name, pk_json) DO NOTHING`,
      `INSERT OR IGNORE INTO _sync_meta (key, value) VALUES (${literal(`backfilled:${table.name}`)}, '1')`,
    ]),
  ];

  const resetSql = [
    'DELETE FROM _sync_outbox',
    'DELETE FROM _sync_records',
    ...tables.map((table) => `${backfillSql(table)} ON CONFLICT (table_name, pk_json) DO NOTHING`),
  ];

  const version = JSON.stringify({ format: FORMAT, tables });
  installSql.push(
    `INSERT INTO _sync_meta (key, value) VALUES ('schema_version', ${literal(version)}) ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
  );

  return { version, tables, installSql, resetSql };
}

export async function installSchema(db: SqlExecutor, schema: SyncSchema): Promise<boolean> {
  await db.exec('BEGIN IMMEDIATE');
  try {
    await db.exec('CREATE TABLE IF NOT EXISTS _sync_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT)');
    const stored = await db.getFirst<{ value: string }>(
      "SELECT value FROM _sync_meta WHERE key = 'schema_version'",
    );
    if (stored?.value === schema.version) {
      await db.exec('COMMIT');
      return false;
    }

    for (const table of schema.tables) {
      await assertColumnsExist(db, table);
    }
    const triggers = await db.getAll<{ name: string }>(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name GLOB '_sync_*'",
    );
    for (const { name } of triggers) {
      await db.exec(`DROP TRIGGER IF EXISTS ${quote(name)}`);
    }
    for (const statement of schema.installSql) {
      await db.exec(statement);
    }
    await db.exec('COMMIT');
    return true;
  } catch (error) {
    await db.exec('ROLLBACK');
    throw error;
  }
}

function normalizeTable(config: TableSyncConfig): SyncTable {
  assertIdentifier(config.name, 'table name');
  if (config.primaryKey.length === 0) {
    throw new Error(`expo-sqlite-cloudkit: table "${config.name}" needs at least one primary key column`);
  }
  for (const column of config.primaryKey) assertIdentifier(column, `primary key column of "${config.name}"`);
  assertUnique(config.primaryKey, `primary key column of "${config.name}"`);
  assertIdentifier(config.updatedAtColumn, `updatedAtColumn of "${config.name}"`);
  if (config.deletedAtColumn !== undefined) {
    assertIdentifier(config.deletedAtColumn, `deletedAtColumn of "${config.name}"`);
  }
  const encrypted = config.encryptedColumns ?? [];
  if (encrypted !== 'all') {
    for (const column of encrypted) assertIdentifier(column, `encrypted column of "${config.name}"`);
  }

  return {
    name: config.name,
    primaryKey: [...config.primaryKey],
    updatedAtColumn: config.updatedAtColumn,
    deletedAtColumn: config.deletedAtColumn ?? null,
    encryptedColumns: encrypted === 'all' ? 'all' : [...encrypted],
  };
}

function triggerSql(table: SyncTable): string[] {
  const pk = (row: 'NEW' | 'OLD') =>
    `json_array(${table.primaryKey.map((column) => `CAST(${row}.${quote(column)} AS TEXT)`).join(', ')})`;
  const enqueue = (row: 'NEW' | 'OLD', op: 'upsert' | 'delete', where = '') =>
    `INSERT INTO _sync_outbox (table_name, pk_json, op, changed_at) SELECT ${literal(table.name)}, ${pk(row)}, '${op}', ${NOW_MS}${where} ON CONFLICT (table_name, pk_json) DO UPDATE SET op = excluded.op, changed_at = excluded.changed_at, version = version + 1;`;
  const keyChanged = table.primaryKey
    .map((column) => `OLD.${quote(column)} IS NOT NEW.${quote(column)}`)
    .join(' OR ');
  const name = (event: string) => quote(`_sync_${table.name}_${event}`);
  const on = quote(table.name);

  return [
    `CREATE TRIGGER ${name('insert')} AFTER INSERT ON ${on} WHEN ${NOT_APPLYING} BEGIN ${enqueue('NEW', 'upsert', ' WHERE true')} END`,
    `CREATE TRIGGER ${name('update')} AFTER UPDATE ON ${on} WHEN ${NOT_APPLYING} BEGIN ${enqueue('OLD', 'delete', ` WHERE ${keyChanged}`)} ${enqueue('NEW', 'upsert', ' WHERE true')} END`,
    `CREATE TRIGGER ${name('delete')} AFTER DELETE ON ${on} WHEN ${NOT_APPLYING} BEGIN ${enqueue('OLD', 'delete', ' WHERE true')} END`,
  ];
}

function backfillSql(table: SyncTable): string {
  const pk = table.primaryKey.map((column) => `CAST(${quote(column)} AS TEXT)`).join(', ');
  return `INSERT INTO _sync_outbox (table_name, pk_json, op, changed_at) SELECT ${literal(table.name)}, json_array(${pk}), 'upsert', ${NOW_MS} FROM ${quote(table.name)} WHERE true`;
}

async function assertColumnsExist(db: SqlExecutor, table: SyncTable): Promise<void> {
  const columns = await db.getAll<{ name: string }>(`SELECT name FROM pragma_table_info(${literal(table.name)})`);
  if (columns.length === 0) {
    throw new Error(`expo-sqlite-cloudkit: table "${table.name}" does not exist`);
  }
  const existing = new Set(columns.map((column) => column.name));
  const required = [
    ...table.primaryKey,
    table.updatedAtColumn,
    ...(table.deletedAtColumn ? [table.deletedAtColumn] : []),
    ...(table.encryptedColumns === 'all' ? [] : table.encryptedColumns),
  ];
  for (const column of required) {
    if (!existing.has(column)) {
      throw new Error(`expo-sqlite-cloudkit: column "${column}" does not exist in table "${table.name}"`);
    }
  }
}

function assertIdentifier(value: string, what: string): void {
  if (!IDENTIFIER.test(value)) {
    throw new Error(
      `expo-sqlite-cloudkit: ${what} "${value}" must start with a letter and contain only letters, digits and underscores`,
    );
  }
}

function assertUnique(values: readonly string[], what: string): void {
  const duplicate = values.find((value, index) => values.indexOf(value) !== index);
  if (duplicate !== undefined) {
    throw new Error(`expo-sqlite-cloudkit: duplicate ${what} "${duplicate}"`);
  }
}

function quote(identifier: string): string {
  return `"${identifier.replaceAll('"', '""')}"`;
}

function literal(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}
