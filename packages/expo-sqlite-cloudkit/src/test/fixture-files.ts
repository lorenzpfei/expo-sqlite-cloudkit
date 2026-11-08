import { join } from 'node:path';

import { buildSchema } from '../schema.ts';
import { fixtures } from './fixtures.ts';

const directory = join(import.meta.dirname, '../../../sync-core/Tests/SyncCoreTests/Fixtures');

export function fixtureFiles(): { path: string; content: string }[] {
  return fixtures.map((fixture) => ({
    path: join(directory, `${fixture.name}.json`),
    content: `${JSON.stringify({ ddl: fixture.ddl, schema: buildSchema(fixture.tables) }, null, 2)}\n`,
  }));
}
