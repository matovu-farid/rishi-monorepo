const { getSentryExpoConfig } = require('@sentry/react-native/metro');
const { withNativeWind } = require('nativewind/metro');
const path = require('path');

const projectRoot = __dirname;
const monorepoRoot = path.resolve(projectRoot, '../..');

const config = getSentryExpoConfig(projectRoot);

// Watch the monorepo root so Metro can find @rishi/shared
config.watchFolders = [monorepoRoot];

// Ensure node_modules resolve from the mobile app first
config.resolver.nodeModulesPaths = [
  path.resolve(projectRoot, 'node_modules'),
  path.resolve(monorepoRoot, 'node_modules'),
];

// Enable package exports resolution for @rishi/shared subpath exports
config.resolver.unstable_enablePackageExports = true;

config.resolver.sourceExts.push('sql');

module.exports = withNativeWind(config, { input: './global.css' });
