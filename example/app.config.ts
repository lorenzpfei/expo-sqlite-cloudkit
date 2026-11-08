import type { ExpoConfig } from 'expo/config';

const bundleIdentifier = process.env.EXAMPLE_BUNDLE_IDENTIFIER ?? 'com.example.syncnotes';
const containerIdentifier = process.env.EXPO_PUBLIC_ICLOUD_CONTAINER ?? 'iCloud.com.example.syncnotes';

const config: ExpoConfig = {
  name: 'SyncNotes',
  slug: 'expo-sqlite-cloudkit-example',
  version: '1.0.0',
  orientation: 'portrait',
  icon: './assets/icon.png',
  userInterfaceStyle: 'automatic',
  platforms: ['ios'],
  ios: {
    bundleIdentifier,
    appleTeamId: process.env.EXAMPLE_APPLE_TEAM_ID,
    supportsTablet: true,
  },
  plugins: ['expo-sqlite', ['expo-sqlite-cloudkit', { containerIdentifier }]],
};

export default config;
