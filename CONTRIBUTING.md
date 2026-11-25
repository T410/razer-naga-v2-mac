# Contributing

Build and test the app with the commands in [README.md](README.md). Node.js 24 and npm are needed only for commit message checks, not for the Swift app.

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

The [Commitlint workflow](.github/workflows/commitlint.yml) runs on pushes and checks every commit in the pushed range. For a new branch, or when the previous commit is unavailable after a force push, it checks the full reachable history. Standard Git merge/revert messages are ignored by commitlint's default rules.
