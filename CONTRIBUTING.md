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
