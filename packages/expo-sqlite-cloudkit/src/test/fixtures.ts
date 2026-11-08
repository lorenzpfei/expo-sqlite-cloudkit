import type { TableSyncConfig } from '../schema.ts';

export type Fixture = {
  name: string;
  ddl: string[];
  tables: TableSyncConfig[];
};

export const notes: Fixture = {
  name: 'notes',
  ddl: [
    'CREATE TABLE notes (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL DEFAULT \'\', updated_at INTEGER NOT NULL, deleted_at INTEGER)',
  ],
  tables: [
    {
      name: 'notes',
      primaryKey: ['id'],
      updatedAtColumn: 'updated_at',
      deletedAtColumn: 'deleted_at',
      encryptedColumns: ['body'],
    },
  ],
};

export const commitHealth: Fixture = {
  name: 'commit-health',
  ddl: [
    "CREATE TABLE `health_days` (`user_id` text DEFAULT 'local' NOT NULL, `day` text NOT NULL, `steps` integer DEFAULT 0 NOT NULL, `active_energy_kcal` real DEFAULT 0 NOT NULL, `exercise_ms` integer DEFAULT 0 NOT NULL, `distance_meters` real DEFAULT 0 NOT NULL, `stand_hours` integer DEFAULT 0 NOT NULL, `hr_avg` real, `hr_min` real, `hr_max` real, `resting_hr_avg` real, `hrv_avg` real, `vo2max_avg` real, `oxygen_saturation_avg` real, `respiratory_rate_avg` real, `source` text, `created_at` integer DEFAULT (strftime('%s','now')) NOT NULL, `updated_at` integer DEFAULT (strftime('%s','now')) NOT NULL, PRIMARY KEY(`user_id`, `day`))",
    "CREATE TABLE `sleep_days` (`user_id` text DEFAULT 'local' NOT NULL, `day` text NOT NULL, `in_bed_ms` integer DEFAULT 0 NOT NULL, `awake_ms` integer DEFAULT 0 NOT NULL, `core_ms` integer DEFAULT 0 NOT NULL, `deep_ms` integer DEFAULT 0 NOT NULL, `rem_ms` integer DEFAULT 0 NOT NULL, `unspecified_ms` integer DEFAULT 0 NOT NULL, `total_in_bed_ms` integer DEFAULT 0 NOT NULL, `total_asleep_ms` integer DEFAULT 0 NOT NULL, `source` text, `created_at` integer DEFAULT (strftime('%s','now')) NOT NULL, `updated_at` integer DEFAULT (strftime('%s','now')) NOT NULL, PRIMARY KEY(`user_id`, `day`))",
    "CREATE TABLE `intake_items` (`user_id` text DEFAULT 'local' NOT NULL, `id` text NOT NULL, `name` text NOT NULL, `unit` text NOT NULL, `kind` text NOT NULL, `is_acute` integer DEFAULT 0 NOT NULL, `notes` text, `created_at` integer DEFAULT (strftime('%s','now')) NOT NULL, `updated_at` integer DEFAULT (strftime('%s','now')) NOT NULL, `deleted_at` integer, PRIMARY KEY(`user_id`, `id`))",
    'ALTER TABLE `intake_items` ADD `important` integer DEFAULT 0 NOT NULL',
    "CREATE TABLE `pain_episodes` (`user_id` text DEFAULT 'local' NOT NULL, `id` text NOT NULL, `type` text NOT NULL, `day` text NOT NULL, `started_at` text NOT NULL, `ended_at` text, `intensity` integer, `side` text, `notes` text, `created_at` integer DEFAULT (strftime('%s','now')) NOT NULL, `updated_at` integer DEFAULT (strftime('%s','now')) NOT NULL, `deleted_at` integer, PRIMARY KEY(`user_id`, `id`))",
    "CREATE TABLE `diary_entries` (`user_id` text DEFAULT 'local' NOT NULL, `id` text NOT NULL, `day` text NOT NULL, `written_at` text NOT NULL, `body` text NOT NULL, `created_at` integer DEFAULT (strftime('%s','now')) NOT NULL, `updated_at` integer DEFAULT (strftime('%s','now')) NOT NULL, `deleted_at` integer, PRIMARY KEY(`user_id`, `id`))",
  ],
  tables: [
    { name: 'health_days', primaryKey: ['user_id', 'day'], updatedAtColumn: 'updated_at' },
    { name: 'sleep_days', primaryKey: ['user_id', 'day'], updatedAtColumn: 'updated_at' },
    {
      name: 'intake_items',
      primaryKey: ['user_id', 'id'],
      updatedAtColumn: 'updated_at',
      deletedAtColumn: 'deleted_at',
    },
    {
      name: 'pain_episodes',
      primaryKey: ['user_id', 'id'],
      updatedAtColumn: 'updated_at',
      deletedAtColumn: 'deleted_at',
      encryptedColumns: ['notes'],
    },
    {
      name: 'diary_entries',
      primaryKey: ['user_id', 'id'],
      updatedAtColumn: 'updated_at',
      deletedAtColumn: 'deleted_at',
      encryptedColumns: 'all',
    },
  ],
};

export const fixtures = [notes, commitHealth];
