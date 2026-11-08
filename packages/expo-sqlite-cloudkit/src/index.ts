import type { EventSubscription } from 'expo';
import { openDatabaseAsync } from 'expo-sqlite';

import { native } from './ExpoSqliteCloudkitModule.ts';
import { buildSchema, installSchema } from './schema.ts';
import type { AccountStatus, SyncConfig, SyncStatus } from './types.ts';

export type { TableSyncConfig } from './schema.ts';
export type { AccountStatus, SyncConfig, SyncStatus } from './types.ts';

export async function configureSync(config: SyncConfig): Promise<void> {
  const schema = buildSchema(config.tables);
  const db = await openDatabaseAsync(config.databaseName, { useNewConnection: true }, config.directory);
  try {
    await db.execAsync('PRAGMA busy_timeout = 5000');
    await installSchema(
      {
        exec: (sql) => db.execAsync(sql),
        getFirst: (sql) => db.getFirstAsync(sql),
        getAll: (sql) => db.getAllAsync(sql),
      },
      schema,
    );
  } finally {
    await db.closeAsync();
  }
  await native().configure(db.databasePath, config.containerIdentifier, JSON.stringify(schema));
}

export function syncNow(): Promise<void> {
  return native().syncNow();
}

export function getStatus(): Promise<SyncStatus> {
  return native().getStatus();
}

export function accountStatus(): Promise<AccountStatus> {
  return native().accountStatus();
}

export function resetLocalSyncState(): Promise<void> {
  return native().resetLocalSyncState();
}

export function addChangeListener(listener: (tables: string[]) => void): EventSubscription {
  return native().addListener('onChange', (event) => listener(event.tables));
}

export function addStatusListener(listener: (status: SyncStatus) => void): EventSubscription {
  return native().addListener('onStatus', listener);
}
