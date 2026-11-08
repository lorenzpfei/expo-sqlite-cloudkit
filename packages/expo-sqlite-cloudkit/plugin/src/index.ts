import { withEntitlementsPlist, withInfoPlist, type ConfigPlugin } from 'expo/config-plugins';

import { applyEntitlements, applyInfoPlist, type PluginProps } from './plist.ts';

const withSqliteCloudKit: ConfigPlugin<PluginProps> = (config, props) => {
  config = withEntitlementsPlist(config, (mod) => {
    mod.modResults = applyEntitlements(mod.modResults, props);
    return mod;
  });
  return withInfoPlist(config, (mod) => {
    mod.modResults = applyInfoPlist(mod.modResults);
    return mod;
  });
};

export default withSqliteCloudKit;
