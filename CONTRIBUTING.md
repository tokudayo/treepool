# Contributing

Treepool uses Swift Package Manager and requires Swift 6.

```sh
swift build
swift test
```

Keep `TreepoolCore` free of AppKit and other Apple-only APIs. Platform behavior belongs
behind conditional adapters, and lifecycle changes should include an integration
test using a temporary real Git repository.

Before submitting a change:

1. Run the full test suite.
2. Confirm `swift build -c release --product twt`.
3. On macOS, confirm `swift build -c release --product TreepoolMenu`.
4. Update `README.md` when commands or `.twt.json` change.

## Releases

Fast-forward `main` from `origin/main`, then create `release/vX.Y.Z`. Merge only
validated feature work into that branch. Keep `VERSION` at the published version
and changelog entries under `Unreleased` until the release is finalized.

When ready, set `VERSION` to `X.Y.Z`, move the entries into a dated changelog
section, and open a PR from `release/vX.Y.Z` to `main`. After merging, wait for
main's CI to pass. **Prepare release tag** then creates annotated tag `vX.Y.Z`
at that exact tested merge commit and starts **Release**, which builds and
publishes the release artifacts. Ordinary feature merges do not publish releases.

The branch name, version, and dated changelog must agree. Existing tags are
reused only when annotated and pointing to the same commit. Already published
or running releases are skipped. To retry a failure, rerun **Prepare release
tag** after resolving its error. A tag created with the built-in GitHub token
does not trigger tag-push workflows, so the automation explicitly dispatches
**Release** at that tag. No additional repository secret is required.

Manual annotated tag pushes still trigger **Release** as a recovery path.
Release automation tests can be run with:

```sh
python3 -m unittest discover -s scripts/tests
```
