module.exports = {
  branches: ['main'],
  repositoryUrl: 'https://github.com/T410/razer-naga-v2-mac.git',
  tagFormat: 'v${version}',
  plugins: [
    ['@semantic-release/commit-analyzer', {
      preset: 'angular',
      releaseRules: [
        { breaking: true, release: 'major' },
        { type: 'feat', release: 'minor' },
        { type: '*', release: 'patch' },
      ],
    }],
    ['@semantic-release/release-notes-generator', { preset: 'angular' }],
    './Scripts/prepare-release.cjs',
    ['@semantic-release/github', {
      assets: [
        { path: 'build/razer-naga-v2-mac-*-arm64.dmg', label: 'macOS Apple Silicon installer' },
        { path: 'build/razer-naga-v2-mac-*-arm64.dmg.sha256', label: 'SHA-256 checksum' },
      ],
      successComment: false,
      failComment: false,
      releasedLabels: false,
    }],
  ],
};
