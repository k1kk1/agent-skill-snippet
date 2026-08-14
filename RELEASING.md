# Releasing Agent Recipes

## Before the first public release

1. Replace `<YOUR NAME OR ORGANIZATION>` in [LICENSE](LICENSE) with the legal
   copyright holder.
2. Choose a Bundle ID that you control and update `Resources/Info.plist` (for
   example, `io.github.<github-user>.agent-recipes`).
3. Update the version in `Resources/Info.plist` and add release notes.
4. Run the complete local verification:

   ```bash
   swift test
   ./scripts/build-app.sh
   codesign --verify --deep --strict build/AgentRecipes.app
   ```

5. Confirm that no data from `~/Library/Application Support/AgentRecipes/`,
   `.vscode/`, build directories, or local Skills is staged for commit.
6. Verify the supported Herdr version and test Copy, Paste, Submit, and a
   structured rich-result Recipe.

## Distribution options

### Source release / local build

This is the recommended starting point for individuals and internal teams. Tag
the reviewed source commit and let users build it locally with
`./scripts/build-app.sh`. The output is ad-hoc signed and intended for local use.

### Public binary release

Do not publish the ad-hoc-signed `build/AgentRecipes.app` as the final public
artifact. Use an Apple Developer Program account to sign with Developer ID,
enable the hardened runtime as appropriate, notarize the app, and staple the
notarization ticket before publishing a ZIP, DMG, or PKG.

Build and test both Apple Silicon and Intel variants, or publish a universal
binary, if Intel Mac support is promised.

## Dependency note

Agent Recipes does not bundle Herdr. It invokes the user's locally installed
`herdr` CLI, which remains a separate dependency with its own license and
release lifecycle.
