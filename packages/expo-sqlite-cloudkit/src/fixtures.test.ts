import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { fixtureFiles } from './test/fixture-files.ts';

test('Swift test fixtures match the SQL generator', () => {
  for (const { path, content } of fixtureFiles()) {
    assert.equal(readFileSync(path, 'utf8'), content, `${path} is stale, run "pnpm fixtures"`);
  }
});
