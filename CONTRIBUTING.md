# Contributing

Thank you for helping. Issues and pull requests are both welcome.

## Before you start

- For anything larger than a small fix, please open an issue first.
- Keep changes focused, and add a test for anything that decides what gets removed.
- Run `swift test` before opening a pull request.
- Please report security problems [privately](SECURITY.md), not in an issue or pull request.

## Translations

All translations live in one file, `Localization/Localizable.xcstrings`, and the English text is the key. Opening it in Xcode gives you a table for each language. It's also plain JSON, so any editor works. The macOS permission prompts are in `Localization/InfoPlist.xcstrings`.

The translations are machine-made so far, so corrections from native speakers are very welcome, above all for anything that says what gets deleted, kept or moved to the Trash.

**To correct a translation:** change the text and open a pull request. Keep placeholders such as `%@` and `%lld`. To change their order, number them, for example `%2$@ %1$lld`.

**To add a language:**

1. Add its code and its name in that language to `AppLanguage.all` in `Sources/MacStewardCore/AppLanguage.swift`.
2. Add the translations to both catalog files.
3. If its plural forms differ from English, add them to `requiredPlurals` in `Tests/MacStewardCoreTests/LocalizationTests.swift`.

**To add or change text in the app:** use `Text("…")` or `String(localized: "…")`, then run `scripts/sync-strings.sh` to add the new text to the catalog.

**Before you open the pull request:** `swift test` lists anything missing in any language and any placeholder that doesn't match. To see a language in the app, build it and open it in that language, because `swift run` shows English only:

```sh
./scripts/package-app.sh
open dist/Artifloam.app --args -AppleLanguages '(de)'
```

## License

Artifloam is licensed under the [Apache License 2.0](LICENSE). Under section 5 of that license, anything you submit is licensed under the same terms, unless you clearly say otherwise. Please only submit work you have the right to share.
