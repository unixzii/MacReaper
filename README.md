# MacReaper

A Mac disk cleaner driven by extensible rules: rules describe what is safe to clean, a scan
collects candidates for review, and cleanup deletes exactly what was reviewed.

## Layout

| Path | Contents |
|---|---|
| [MacReaper.xcodeproj](MacReaper.xcodeproj) | The SwiftUI app. Its sources live in [MacReaper/](MacReaper/), a folder Xcode keeps in sync, so new files need no project edits. |
| [Docs/RuleFormat.md](Docs/RuleFormat.md) | The rule format specification: documents, conditions, actions, evaluation, validation, style. |
| [ReaperKit/](ReaperKit/) | The Swift package with everything below the user interface. |
| [ReaperKit/Sources/ReaperRules/Resources/BuiltinRules/](ReaperKit/Sources/ReaperRules/Resources/BuiltinRules/) | The rule sets that ship with MacReaper, and the JSON Schema editors use to validate them. |

ReaperKit's targets:

| Target | Role |
|---|---|
| `ReaperFS` | File system access: `getattrlistbulk` listings, probes, deletion, and errors. |
| `ReaperFSTesting` | An in-memory file system and a tree DSL, for tests and previews. |
| `ReaperRules` | Loads and validates rule files, and compiles them for scanning. |
| `ReaperEngine` | Evaluates rules, walks the file system on a worker pool, sizes candidates, and deletes them. |

## Running the app

Open `MacReaper.xcodeproj` and run the MacReaper scheme, or build from the command line:

```sh
xcodebuild -project MacReaper.xcodeproj -scheme MacReaper build
```

The app is not sandboxed, since it scans the whole data volume (`/System/Volumes/Data`) by
default, or the home folder or another folder of your choice. Scanning only reads. Deleting the
marked candidates takes a confirmation, and deletes them permanently rather than moving them to
the Trash. Some folders under `~/Library` need Full Disk Access; the scan lists what it
couldn't read and links to the setting. The app is signed to run locally, so macOS treats each
rebuild as a new app and Full Disk Access may need granting again.

SwiftUI previews scan an in-memory home folder (`MacReaper/Preview Content/`), built with
`ReaperFSTesting`.

## Testing

```sh
cd ReaperKit
swift test
```

The rule loader's tests run the conformance corpus in
`ReaperKit/Tests/ReaperRulesTests/Conformance/`: documents that must load, or be rejected with
a given diagnostic code at a given line. The engine's tests scan an in-memory home folder with
the shipped rules and check every candidate, and that weakening any rule changes the result.

To measure a scan of your real `~/Developer` and `~/Library/Developer` (read-only):

```sh
cd ReaperKit
REAPER_BENCH=1 swift test -c release --filter BenchmarkTests
```
