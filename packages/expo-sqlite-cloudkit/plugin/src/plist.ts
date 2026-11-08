export type PluginProps = {
  containerIdentifier: string;
  apsEnvironment?: 'development' | 'production';
};

type Plist = Record<string, unknown>;

export function applyEntitlements<T extends Plist>(entitlements: T, props: PluginProps | undefined): T {
  const containerIdentifier = props?.containerIdentifier;
  if (!containerIdentifier?.startsWith('iCloud.')) {
    throw new Error(
      'expo-sqlite-cloudkit: the config plugin needs a containerIdentifier that starts with "iCloud.", e.g. ["expo-sqlite-cloudkit", { "containerIdentifier": "iCloud.com.example.app" }]',
    );
  }
  const result: Plist = {
    ...entitlements,
    'aps-environment': entitlements['aps-environment'] ?? props?.apsEnvironment ?? 'development',
    'com.apple.developer.icloud-container-identifiers': union(
      entitlements['com.apple.developer.icloud-container-identifiers'],
      [containerIdentifier],
    ),
    'com.apple.developer.icloud-services': union(entitlements['com.apple.developer.icloud-services'], ['CloudKit']),
  };
  return result as T;
}

export function applyInfoPlist<T extends Plist>(infoPlist: T): T {
  const result: Plist = {
    ...infoPlist,
    UIBackgroundModes: union(infoPlist.UIBackgroundModes, ['remote-notification']),
  };
  return result as T;
}

function union(existing: unknown, values: string[]): string[] {
  const current = Array.isArray(existing) ? existing.filter((value) => typeof value === 'string') : [];
  return [...current, ...values.filter((value) => !current.includes(value))];
}
