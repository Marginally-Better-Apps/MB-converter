const {
  withDangerousMod,
  createRunOncePlugin,
} = require('@expo/config-plugins');
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const PACKAGE_VERSION = require('./package.json').version;

/**
 * Ensures tylerjonesio ffmpeg-kit-spm xcframeworks are present before CocoaPods runs.
 * Frameworks are gitignored; CI and local `expo prebuild` / `expo run:ios` must download them.
 */
function withFFmpegFrameworks(config) {
  return withDangerousMod(config, [
    'ios',
    async (cfg) => {
      const projectRoot = cfg.modRequest.projectRoot;
      const script = path.join(projectRoot, 'scripts', 'download-ffmpeg-frameworks.sh');
      if (!fs.existsSync(script)) {
        throw new Error(
          `[ffmpeg-module] Missing download script at ${script}. Restore scripts/download-ffmpeg-frameworks.sh.`
        );
      }
      execFileSync('bash', [script], {
        cwd: projectRoot,
        stdio: 'inherit',
        env: process.env,
      });
      return cfg;
    },
  ]);
}

module.exports = createRunOncePlugin(withFFmpegFrameworks, 'ffmpeg-module', PACKAGE_VERSION);
