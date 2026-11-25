import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdtempSync, mkdirSync, readFileSync, copyFileSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';
import { analyzeCommits } from '@semantic-release/commit-analyzer';

const root = fileURLToPath(new URL('../../', import.meta.url));
const require = createRequire(import.meta.url);
const config = require('../../.releaserc.cjs');
const analyzer = config.plugins.find(([name]) => name === '@semantic-release/commit-analyzer')[1];
const logger = { log() {} };
const body = 'Keep release behavior consistent across pull requests and CI.';

for (const [type, expected] of [
  ['feat', 'minor'], ['fix', 'patch'], ['perf', 'patch'], ['docs', 'patch'],
  ['ci', 'patch'], ['test', 'patch'], ['build', 'patch'], ['refactor', 'patch'], ['revert', 'patch'],
]) {
  test(`${type} determines a ${expected} release`, async () => {
    const result = await analyzeCommits(analyzer, {
      cwd: root, logger, commits: [{ message: `${type}: update the app\n\n${body}` }],
    });
    assert.equal(result, expected);
  });
}

test('a breaking change takes priority over a feature or patch', async () => {
  const result = await analyzeCommits(analyzer, {
    cwd: root, logger, commits: [
      { message: `fix: update an assignment\n\n${body}` },
      { message: `feat: replace the profile format\n\n${body}\n\nBREAKING CHANGE: migrate existing profiles before upgrading.` },
    ],
  });
  assert.equal(result, 'major');
});

test('no commits produce no new release', async () => {
  assert.equal(await analyzeCommits(analyzer, { cwd: root, logger, commits: [] }), null);
});

test('bundle version updates preserve other metadata and reject invalid values', () => {
  const temporary = mkdtempSync(path.join(os.tmpdir(), 'naga-release-version-'));
  mkdirSync(path.join(temporary, 'Resources'));
  const plist = path.join(temporary, 'Resources/Info.plist');
  copyFileSync(path.join(root, 'Resources/Info.plist'), plist);
  const read = () => JSON.parse(execFileSync('python3', ['-c',
    'import json, plistlib; print(json.dumps(plistlib.load(open("Resources/Info.plist", "rb"))))',
  ], { cwd: temporary, encoding: 'utf8' }));
  const before = read();
  execFileSync('python3', [path.join(root, 'Scripts/set-release-version.py'), '1.2.3', '42'], { cwd: temporary });
  assert.deepEqual(read(), { ...before, CFBundleShortVersionString: '1.2.3', CFBundleVersion: '42' });
  const valid = readFileSync(plist);
  for (const args of [['1.2', '42'], ['1.2.3', 'zero'], ['1.2.3-beta.1', '42']]) {
    const result = spawnSync('python3', [path.join(root, 'Scripts/set-release-version.py'), ...args], { cwd: temporary });
    assert.notEqual(result.status, 0);
    assert.deepEqual(readFileSync(plist), valid);
  }
});

function git(cwd, ...args) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}
function commit(cwd, message) {
  git(cwd, '-c', 'user.name=Release Test', '-c', 'user.email=release@example.invalid',
    'commit', '--allow-empty', '-m', message);
  return git(cwd, 'rev-parse', 'HEAD');
}

test('PR checks validate every commit plus the proposed squash message', () => {
  const temporary = mkdtempSync(path.join(os.tmpdir(), 'naga-pr-lint-'));
  git(temporary, 'init', '-b', 'main');
  for (const name of ['package.json', 'commitlint.config.cjs']) copyFileSync(path.join(root, name), path.join(temporary, name));
  symlinkSync(path.join(root, 'node_modules'), path.join(temporary, 'node_modules'), 'dir');
  const base = commit(temporary, 'docs: seed test history');
  let head = commit(temporary, `fix(input): release held keys\n\n${body}`);
  const eventFile = path.join(temporary, 'event.json');
  const run = (title, prBody = body) => {
    writeFileSync(eventFile, JSON.stringify({ pull_request: { base: { sha: base }, head: { sha: head }, title, body: prBody } }));
    return spawnSync(process.execPath, [path.join(root, 'Scripts/lint-pr.mjs')], {
      cwd: temporary, env: { ...process.env, GITHUB_EVENT_PATH: eventFile }, encoding: 'utf8',
    });
  };
  assert.equal(run('fix(input): release held keys').status, 0);
  assert.notEqual(run('Update the mouse settings').status, 0);
  assert.notEqual(run('fix(input): release held keys', '').status, 0);
  commit(temporary, 'invalid intermediate commit');
  head = commit(temporary, 'docs: update usage');
  assert.notEqual(run('fix(input): release held keys').status, 0);
});

test('release dry run uses v1.0.0 as its base without creating tags', async () => {
  const temporary = mkdtempSync(path.join(os.tmpdir(), 'naga-release-plan-'));
  const repo = path.join(temporary, 'repo');
  const remote = path.join(temporary, 'remote.git');
  mkdirSync(repo);
  git(repo, 'init', '-b', 'main');
  commit(repo, `feat: add the app\n\n${body}`);
  git(repo, 'tag', 'v1.0.0');
  commit(repo, `ci: automate releases\n\n${body}`);
  git(temporary, '-c', 'init.defaultBranch=master', 'init', '--bare', '-b', 'main', remote);
  git(repo, 'remote', 'add', 'origin', remote);
  git(repo, 'push', 'origin', 'main', '--tags');
  const before = git(temporary, '--git-dir', remote, 'tag');
  // semantic-release temporarily intercepts stdout. Keep it out of the Node
  // test runner process so it cannot intercept the test reporter's IPC stream.
  const env = { ...process.env, NAGA_TEST_REPO: repo, NAGA_TEST_REMOTE: pathToFileURL(remote).href };
  delete env.NODE_TEST_CONTEXT;
  const output = execFileSync(process.execPath, ['--input-type=module', '-e', `
    import semanticRelease from 'semantic-release';
    import { PassThrough } from 'node:stream';
    import { createRequire } from 'node:module';
    const config = createRequire(import.meta.url)('./.releaserc.cjs');
    const sink = new PassThrough();
    sink.resume();
    const result = await semanticRelease({
      branches: ['main'], repositoryUrl: process.env.NAGA_TEST_REMOTE,
      tagFormat: config.tagFormat, dryRun: true, ci: false,
      plugins: [config.plugins[0]],
    }, { cwd: process.env.NAGA_TEST_REPO, env: { ...process.env, GITHUB_TOKEN: '', GH_TOKEN: '' }, stdout: sink, stderr: sink });
    console.log(JSON.stringify({ version: result.nextRelease.version }));
  `], { cwd: root, env, encoding: 'utf8' });
  assert.equal(JSON.parse(output).version, '1.0.1');
  assert.equal(git(temporary, '--git-dir', remote, 'tag'), before);
});
