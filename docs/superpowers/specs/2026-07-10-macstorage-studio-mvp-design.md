# MacStorage Studio MVP Design

**Date:** 2026-07-10  
**Status:** Implemented (MVP)  
**Stack:** Swift 5.9+, SwiftUI, SQLite3, macOS 14+  
**Distribution:** Direct download + Full Disk Access (not sandboxed)

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Modular monolith + worker process | Ship speed with real crash isolation |
| UI | SwiftUI | Native, maintainable for hierarchy/lists |
| Persistence | SQLite via system SQLite3 | Zero deps, WAL, millions of rows |
| Scan roots | Home + mounted volumes | Practical cleanup scope |
| Cleanup | Trash only + confirmation | Safety first |
| Scanner isolation | Separate `ScannerWorker` process | UI survives scanner abort/crash |

## Components

See [architecture.md](../../architecture.md).

## Safety

- Protected path denylist
- Never trash `/`, home root, or SIP prefixes
- Every recommendation includes reason, confidence, risk, regenerable, explanation
- Multiple UI confirmations before Trash

## Testing

- Unit: classifier, store, recommendations, cleanup, protocol
- Isolation: worker crash test proves host continues
- Integration: temp-directory scan via worker
