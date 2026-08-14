# Contributing

Thanks for considering a contribution to Agent Recipes.

## Before opening an issue or pull request

- Search existing issues and discussions first.
- Do not include API keys, access tokens, clipboard contents, private prompts,
  agent transcripts, or company paths in issues, logs, screenshots, or commits.
- Keep changes scoped. Discuss a substantial workflow or format change in an
  issue before implementing it.

## Development setup

Requirements:

- macOS 14 or later;
- Xcode with Swift 6 support;
- `herdr` only when manually testing Paste, Submit, or Result behavior.

Run the checks before submitting a pull request:

```bash
swift test
./scripts/build-app.sh
codesign --verify --deep --strict build/AgentRecipes.app
```

Tests use a fake Herdr runner by default and do not start or prompt a real Agent.

## Pull request expectations

- Add or update tests for behavior changes in `AgentRecipesCore` or `HerdrKit`.
- Update `README.md` or `docs/` when user-facing behavior or the result format
  changes.
- Preserve the fallback to plain text for malformed rich-result payloads.
- Keep user data local unless the user explicitly runs a Recipe.

By contributing, you agree that your contribution may be distributed under the
[MIT License](LICENSE).
