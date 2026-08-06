const { getDefaultConfig } = require('expo/metro-config');
const { withNativeWind } = require('nativewind/metro');

const config = getDefaultConfig(__dirname);

// Allow bundling the tiny demo media fixture for Maestro / sample-file flow.
config.resolver.assetExts = Array.from(new Set([...(config.resolver.assetExts ?? []), 'mp4']));

module.exports = withNativeWind(config, { input: './global.css' });
