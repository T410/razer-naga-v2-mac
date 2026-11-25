const { execFileSync } = require('node:child_process');
const path = require('node:path');

exports.prepare = async (_config, { cwd, env, nextRelease }) => {
  const version = nextRelease.version;
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version)) {
    throw new Error('The main release must have a stable semantic version.');
  }
  const buildNumber = env.GITHUB_RUN_NUMBER || '1';
  const app = path.join(cwd, 'build', 'Razer NAGA v2.app');
  const dmg = path.join(cwd, 'build', `razer-naga-v2-mac-${version}-arm64.dmg`);
  const options = { cwd, env, stdio: 'inherit' };
  execFileSync('python3', ['Scripts/set-release-version.py', version, buildNumber], options);
  execFileSync('zsh', ['Scripts/package-dmg.sh'], {
    ...options,
    env: { ...env, NAGA_APP_DIR: app, NAGA_DMG_FILE: dmg },
  });
  execFileSync('lipo', [path.join(app, 'Contents/MacOS/Naga'), '-verify_arch', 'arm64'], options);
  execFileSync('shasum', ['-a', '256', '-c', path.basename(dmg) + '.sha256'], {
    ...options,
    cwd: path.dirname(dmg),
  });
};
