import type { TableSyncConfig } from './schema.ts';

export type SyncConfig = {
  databaseName: string;
  directory?: string;
  containerIdentifier: string;
  tables: readonly TableSyncConfig[];
  encryptionKey?: string;
};

export type AccountStatus =
  | 'available'
  | 'noAccount'
  | 'restricted'
  | 'couldNotDetermine'
  | 'temporarilyUnavailable'
  | 'unsupported';

export type SyncStatus = {
  configured: boolean;
  account: AccountStatus | 'unknown';
  syncing: boolean;
  pendingChanges: number;
  lastSyncAt: number | null;
  lastError: string | null;
};
