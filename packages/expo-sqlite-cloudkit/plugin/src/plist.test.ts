import assert from 'node:assert/strict';
import { test } from 'node:test';

import { applyEntitlements, applyInfoPlist } from './plist.ts';

test('entitlements for a fresh app', (t) => {
  t.assert.snapshot(applyEntitlements({}, { containerIdentifier: 'iCloud.com.example.notes' }));
});

test('entitlements merge with existing iCloud and push settings', (t) => {
  t.assert.snapshot(
    applyEntitlements(
      {
        'aps-environment': 'production',
        'com.apple.developer.icloud-container-identifiers': ['iCloud.com.example.other'],
        'com.apple.developer.icloud-services': ['CloudDocuments', 'CloudKit'],
        'com.apple.developer.associated-domains': ['applinks:example.com'],
      },
      { containerIdentifier: 'iCloud.com.example.notes' },
    ),
  );
});

test('entitlements are idempotent', () => {
  const props = { containerIdentifier: 'iCloud.com.example.notes' };
  const once = applyEntitlements({}, props);
  assert.deepEqual(applyEntitlements(once, props), once);
});

test('entitlements reject a missing or malformed container identifier', () => {
  assert.throws(() => applyEntitlements({}, undefined), /needs a containerIdentifier/);
  assert.throws(() => applyEntitlements({}, { containerIdentifier: 'com.example.app' }), /needs a containerIdentifier/);
});

test('Info.plist for a fresh app', (t) => {
  t.assert.snapshot(applyInfoPlist({ CFBundleDisplayName: 'Notes' }));
});

test('Info.plist keeps existing background modes', (t) => {
  t.assert.snapshot(applyInfoPlist({ UIBackgroundModes: ['audio', 'remote-notification'] }));
});
