# Tala

Chat, audio calls and video calls for Nextcloud Talk, as a native desktop app
for Linux. Tala (Old Norse "to speak") is an independent project, not affiliated
with or endorsed by Nextcloud GmbH.

It's early, and not packaged yet. Help is on the
[wiki](https://github.com/kz6fittycent/tala/wiki).

## Building

You need Flutter, plus `libayatana-appindicator3-dev` and `libsecret-1-dev`.

    flutter build linux --release --no-tree-shake-icons

The flag matters: without it, the release build's trimmed icon font can lose an
icon.

## Support Tala

Tala is free and stays free. A one-time or monthly tip on
[Ko-fi](https://ko-fi.com/kz6fittycent) helps keep it going.

## License

GNU Affero General Public License, version 3. See `LICENSE`.
