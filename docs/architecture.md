# MacStorage Studio — Architecture

## Goals (MVP)

- Deep-ish filesystem scan of home + mounted volumes
- Local SQLite metadata store
- Hierarchy UI with category breakdown
- Explainable, safe cleanup recommendations (Trash only)
- **Scanner process isolation**: worker crashes never take down the UI

## Module map

```
┌─────────────────────────────────────────────────────────────┐
│ MacStorageStudio (SwiftUI App)                              │
│  AppModel · ContentView · Settings                          │
└───────────────┬─────────────────────────────▲───────────────┘
                │ spawn + JSON-lines            │ progress/entries
                ▼                               │
┌───────────────────────────┐     ┌───────────────────────────┐
│ ScannerClient             │     │ MetadataStore (SQLite)    │
│ process host, restart,    │────▶│ sessions, entries, recs   │
│ checkpoint resume         │     └───────────────────────────┘
└───────────────┬───────────┘
                │ Process
                ▼
┌───────────────────────────┐
│ ScannerWorker (executable)│
│ FilesystemScanner engine  │
│ crash-isolated            │
└───────────────────────────┘

Classifier ──▶ RecommendationEngine ──▶ CleanupEngine (Trash)
```

## Crash isolation

`ScannerWorker` is a separate executable. The app communicates with newline-delimited JSON on stdin/stdout (`WorkerProtocol`).

- If the worker `abort()`s or is killed, the app catches non-zero / uncaught-signal exit.
- Session status becomes `crashed`; last path is stored as `checkpointPath`.
- **Resume Scan** restarts the worker from the checkpoint.
- Automatic restart loop (up to N times) attempts seamless recovery.

## Data flow

1. User starts scan → `AppModel` creates `ScanSession` in SQLite.
2. `ScannerClient` launches worker with roots + excludes + optional checkpoint.
3. Worker streams `entry` / `progress` messages; client classifies and batches inserts.
4. On completion: directory size rollup → recommendation engine → UI refresh.
5. Cleanup moves paths to Trash via `FileManager.trashItem` after confirmation.

## Privacy

- Fully offline
- DB: `~/Library/Application Support/MacStorageStudio/library.sqlite`
- No network client, no telemetry

## Non-goals for MVP

- Interactive dependency graph canvas
- Content-hash duplicate detection at scale
- Permanent delete / secure erase
- App Store sandbox distribution
- Historical multi-scan trends UI (schema ready for sessions)

## Future extraction

Package boundaries allow promoting `ScannerWorker` to an XPC service without rewriting domain models.

## Intelligence layer (post-MVP)

| Feature | Module | UI |
|---------|--------|-----|
| Dependency graph | `GraphBuilder` | `GraphCanvasView` — pan/zoom, filter, inspector |
| History & trends | `HistoryAnalytics` | `HistoryTrendsView` — Charts area/line, deltas, timeline |
| App orphan mapping | `OrphanMapper` | `OrphansView` — apps + orphan artifacts |
| Hash duplicates | `DuplicateDetector` | `DuplicatesView` — SHA-256 groups, trash copies |

Package: `Analysis`
