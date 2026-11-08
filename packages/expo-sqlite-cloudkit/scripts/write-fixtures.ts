import { writeFileSync } from 'node:fs';

import { fixtureFiles } from '../src/test/fixture-files.ts';

for (const { path, content } of fixtureFiles()) {
  writeFileSync(path, content);
  console.log(`wrote ${path}`);
}
