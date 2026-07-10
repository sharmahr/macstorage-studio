# MacStorage Studio

Native macOS disk analysis and storage intelligence app.

**MVP capabilities**

- Isolated scanner process (crashes don’t take down the UI)
- Local SQLite metadata (offline, no telemetry)
- Hierarchy browser, categories, search
- Interactive dependency graph, history/trends, orphan mapping, hash duplicates
- System guardrails for OS paths
- Safe cleanup via **Move to Trash**

## Download (prebuilt app)

Official builds are published on **GitHub Releases**:

| Item | Location |
|------|----------|
| **Latest release page** | https://github.com/sharmahr/macstorage-studio/releases/latest |
| **App zip (example tag `v0.2.0`)** | https://github.com/sharmahr/macstorage-studio/releases/download/v0.2.0/MacStorageStudio-0.2.0-macos-arm64.zip |

After each tagged release (`v*`), GitHub Actions builds `MacStorageStudio.app`, zips it, and attaches it to that release so users can download without building from source.

### Install from release

1. Download `MacStorageStudio-*-macos-arm64.zip` from the release.
2. Unzip and open `MacStorageStudio.app` (right-click → **Open** if Gatekeeper blocks an unsigned build).
3. System Settings → Privacy & Security → **Full Disk Access** → enable MacStorage Studio (and `ScannerWorker` if listed).
4. In the app, use **Allow All Access** for full app scanning.

## Requirements

- macOS 14 Sonoma or later (Apple Silicon arm64 for CI builds)
- For local builds: Xcode 15+ / Swift 5.9+

## Build from source

```bash
swift build
swift test

# Debug app bundle
make app
open dist/MacStorageStudio.app

# Release zip (same layout as CI)
./scripts/package-release.sh 0.2.0
```

## Publish a new downloadable build

```bash
git tag v0.2.0
git push origin v0.2.0
```

That triggers [`.github/workflows/release-macos.yml`](.github/workflows/release-macos.yml), which uploads the zip to:

`https://github.com/sharmahr/macstorage-studio/releases/download/v0.2.0/MacStorageStudio-0.2.0-macos-arm64.zip`

You can also run **Actions → Release macOS App → Run workflow** manually.

## Architecture

See [docs/architecture.md](docs/architecture.md).

## Privacy

Fully offline. Data lives under:

`~/Library/Application Support/MacStorageStudio/library.sqlite`

## License

See [LICENSE](LICENSE).
