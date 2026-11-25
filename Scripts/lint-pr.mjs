import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
const pr = event.pull_request;
if (!pr) throw new Error('This command requires a pull_request event.');
const cli = fileURLToPath(new URL('../node_modules/@commitlint/cli/cli.js', import.meta.url));
function lint(label, message) {
  console.log(`Checking ${label}`);
  const result = spawnSync(process.execPath, [cli], {
    input: message,
    stdio: ['pipe', 'inherit', 'inherit'],
  });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status || 1);
}
const commits = spawnSync('git', ['rev-list', '--reverse', `${pr.base.sha}..${pr.head.sha}`], {
  encoding: 'utf8',
});
if (commits.status !== 0) throw new Error(commits.stderr || 'Could not read PR commits.');
for (const revision of commits.stdout.trim().split('\n').filter(Boolean)) {
  const message = spawnSync('git', ['show', '-s', '--format=%B', revision], { encoding: 'utf8' });
  if (message.status !== 0) throw new Error(message.stderr || 'Could not read a commit.');
  lint(revision, message.stdout);
}
// GitHub squash merges use the PR title and body as the release commit message.
lint('the proposed squash commit', `${pr.title}\n\n${pr.body || ''}\n`);
