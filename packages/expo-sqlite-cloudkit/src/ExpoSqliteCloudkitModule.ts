import { requireOptionalNativeModule, type NativeModule } from 'expo';

import type { AccountStatus, SyncStatus } from './types.ts';

type Events = {
  onChange(event: { tables: string[] }): void;
  onStatus(status: SyncStatus): void;
};

declare class ExpoSqliteCloudkitNativeModule extends NativeModule<Events> {
  configure(databasePath: string, containerIdentifier: string, schemaJson: string): Promise<void>;
  syncNow(): Promise<void>;
  getStatus(): Promise<SyncStatus>;
  accountStatus(): Promise<AccountStatus>;
  resetLocalSyncState(): Promise<void>;
}

const nativeModule = requireOptionalNativeModule<ExpoSqliteCloudkitNativeModule>('ExpoSqliteCloudkit');

export function native(): ExpoSqliteCloudkitNativeModule {
  if (!nativeModule) {
    throw new Error('expo-sqlite-cloudkit: the native module is not available. It supports iOS 17+ development builds only.');
  }
  return nativeModule;
}
