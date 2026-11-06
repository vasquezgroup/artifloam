# Contributing

Thank you for helping. Issues and pull requests are both welcome.

## Before you start

- For anything larger than a small fix, please open an issue first.
- Keep changes focused, and add a test for anything that decides what gets removed.
- Run `swift test` before opening a pull request.
- Please report security problems [privately](SECURITY.md), not in an issue or pull request.

## Translations

English text in the source is the key. After adding or changing a string, run `scripts/sync-strings.sh`, then translate what it adds in `Localization/Localizable.xcstrings`. `swift test` fails until every language has it with matching placeholders. Translations are machine-made so far; corrections from native speakers are very welcome, above all for anything that says what gets deleted.

## License

Artifloam is licensed under the [Apache License 2.0](LICENSE). Under section 5 of that license, anything you submit is licensed under the same terms, unless you clearly say otherwise. Please only submit work you have the right to share.
