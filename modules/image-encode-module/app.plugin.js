const { createRunOncePlugin } = require('@expo/config-plugins');

const PACKAGE_VERSION = require('./package.json').version;

/**
 * ImageEncodeModule uses system ImageIO / UniformTypeIdentifiers only — no download step.
 * Plugin is a no-op marker so the package is listed under app.json plugins consistently.
 */
function withImageEncodeModule(config) {
  return config;
}

module.exports = createRunOncePlugin(
  withImageEncodeModule,
  'image-encode-module',
  PACKAGE_VERSION
);
