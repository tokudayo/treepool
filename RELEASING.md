# Release checklist

1. Ensure `VERSION` and the changelog identify the intended release.
2. Run `swift test` and release builds for `twt` and, on macOS, `TreepoolMenu`.
3. Confirm the working tree is clean and CI passes on `main`.
4. Tag exactly `v$(cat VERSION)` and push the tag.
5. Confirm all three archives, `SHA256SUMS`, provenance, and dependency manifest exist.
6. Install each runnable artifact into a clean temporary prefix and run a lifecycle smoke test.
7. Publish the changelog entry and verify the binary installer.
