# Contributing

Build and test the app with the commands in [README.md](README.md). Node.js 24 and npm are needed only for commit and release tooling, not for the Swift app.

## Commit messages

Follow the [Angular commit message format](https://github.com/angular/angular/blob/main/contributing-docs/commit-message-guidelines.md):

```text
fix(input): release held keys when the active app changes

Prevent a shortcut from remaining pressed after focus moves to another app.
```

- Use `build`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `test`, or `revert`.
- Write the summary in the imperative, starting with a lowercase letter and without a final period. Keep the header at most 72 characters.
- A scope is optional. Use a lowercase area such as `input`, `dpi`, `ui`, or `release`.
- Separate the header, body and footer with blank lines. Include a body of at least 20 characters explaining the change; the body is optional for `docs`.
- Describe breaking changes in a `BREAKING CHANGE:` footer.

Install the pinned tooling and check a message locally:

```sh
npm ci --ignore-scripts
git log -1 --format=%B | npm run commitlint -- --verbose
```

## Pull requests

Submit changes to `main` through a pull request. Squash merge using the PR title and body as the final commit message; check the merge dialog because repository defaults may use individual commit messages instead. The [Commitlint workflow](.github/workflows/commitlint.yml) checks every PR commit and the proposed squash message, including title/body edits. It does not run on tag pushes.

[CI](.github/workflows/ci.yml) also checks release tooling, runs the Swift tests and builds and verifies a DMG before merging. The PR checks are `commitlint`, `Release tooling` and `Tests and DMG`.

## Releases

Every merge to `main` creates a release using semantic-release and the Angular commit message:

| Change | Version bump |
|---|---|
| `BREAKING CHANGE:` footer | Major |
| `feat` | Minor |
| Other allowed types | Patch |

The highest bump wins when a release contains multiple commits. Existing `vX.Y.Z` tags determine the previous version. Tags and releases are produced by CI; do not push version tags manually.

The release job reruns the tests, chooses the next version, updates bundle metadata in its temporary checkout, builds and verifies the Apple Silicon DMG, then pushes the tag and publishes the release with the DMG and checksum. It uses `GITHUB_TOKEN`; no personal access token or npm publication is needed. It does not push version-only commits to `main`.

Versioning and packaging run together, so publishing does not depend on a second workflow being triggered by a bot-created tag or release. Release comments and issue creation are disabled.

Run the release tooling checks locally with `npm run test:release`. Local app builds use the metadata in `Resources/Info.plist`; CI supplies the release version automatically.
