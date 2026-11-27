# Shipyard

A macOS menu-bar app that watches a Git branch of a mobile app project (Flutter, React Native, native iOS, native Android), builds each new commit once per platform, and installs it on every connected phone, tablet and simulator. Public repository: `Rohitha97/shipyard`.

## Workflow rules (always)

1. **Use the Ponytail skill for every code change.** Before writing code, adding a function, or changing an existing function, load `ponytail:ponytail` and follow it: the smallest change that works, standard library and native platform features first, no speculative abstractions.
2. **Review with Ponytail when the code is done.** Run `ponytail:ponytail-review` on the change to find junk code and over-engineering, and fix what it finds.
3. **Check for bugs too.** Ponytail review only covers unnecessary code. Before calling work finished, also re-read the change for correctness and for the invariants below.
4. **Build and self-check before saying it works.** `./build-app.sh` must print `selftest ok` and `Built Shipyard.app`. A build that fails still leaves the old `Shipyard.app` in place, so read the output; don't assume.
5. **Say what was not tested.** Report plainly which paths were exercised for real and which only compiled.
6. **Commit and push only when asked.** Never on your own initiative. Releases are automatic on merge to `main`, so merging is publishing: never merge or push to `main` without being asked.

## Layout

| Path | What it is |
|---|---|
| `Sources/Engine.swift` | Everything that isn't a view: data types, the engine, the command runner, `selftest()` |
| `Sources/App.swift` | All SwiftUI views |
| `Sources/main.swift` | Entry point: `--selftest` or the app |
| `build-app.sh` | Universal build, self-check, bundle, ad-hoc signing. Version comes from `VERSION` or the latest tag |
| `.github/workflows/release.yml` | Publishes the next patch release on every merge to `main` that changes the app |
| `Resources/AppIcon.icns` | Built from `design/app-icon.svg` |
| `docs/` | README images |
| `shipyard.sh` | Original Flutter-only script, kept as a command-line fallback |

Swift package, no dependencies, minimum macOS 14. Keep it dependency-free and keep the file count low; don't split files or add layers without a real need.

## Commands

```bash
./build-app.sh                               # build + self-check + bundle
.build/debug/Shipyard --selftest             # after `swift build`, quick logic check
open -n Shipyard.app --args --demo           # sample data, runs nothing, writes nothing
```

## Where data lives

- **Settings:** `UserDefaults` domain `local.shipyard`. `projects` is a JSON array of `Project`; `current` is the selected project path; `interval` is the check interval.
- **Per project:** `~/.shipyard/<dir>/` holds `src/` (the Git worktree builds run in), `builds/<sha>/<platform>/` (kept artifacts, last five commits) and `state.json` (devices, built and failed commits, history).

## Invariants: do not break these

**The user's project folder is not ours.**
- Build only in the worktree under `~/.shipyard`. Never check out, reset or edit files in the user's own checkout.
- The only command run in their checkout is `git fetch` (no `--prune`) and worktree bookkeeping.

**Saved data must keep loading.**
- Every new stored field on `Project`, `Device` or `BuildRecord` is optional. A non-optional field makes old saved data fail to decode.
- Never rename or reorder the stored values of `Platform` or `ProjectKind`. Display text belongs in `label`.
- Never save over data that failed to load. Keep the unreadable copy.
- Add a self-check case whenever the stored format changes.

**Every external command goes through `sh()` / `runShell()`.**
- No other `Process` use for project commands. The runner gives the time limit, lenient decoding, the user's shell environment and Stop support.
- Quote every interpolated value with `q()` / `shq()`: paths, device IDs, branch names, commit messages, project and scheme names.
- Nothing blocking on the main thread.

**One pass at a time.**
- `busy` guards the single pipeline. Set `busy = true` before starting a `Task`, not inside it.
- A pass works on the `active` snapshot of the project, never on `project` directly, so mid-pass edits can't mix two projects.
- Being stopped by the user is not a failure: don't mark a build failed or notify when `stopRequested` is set.

**Behaviour the user has decided.**
- Changing branch never starts a build. It puts the project in the stopped state and waits for Start or Build.
- Installs must keep the app's data on the device: `devicectl`, `simctl install`, `adb install -r`. Never `flutter install`.
- Simulators and emulators default to Auto off.
- A locked device is "Locked", not "Failed", and is retried quietly.
- Removing a project deletes only its folder under `~/.shipyard`, never the project itself.

**Demo mode stays inert.** With `--demo` the app must not run commands, read or write `UserDefaults`, or touch `~/.shipyard`.

**macOS 14 is the floor.** Don't use newer-only API without an availability check; the build will reject it.

## SwiftUI notes learned the hard way

- A popover opened from a toolbar item does not take the keyboard. Use the `KeyWindow` helper so text fields in it accept typing.
- `List` row separators start at each row's first text. Set both separator alignment guides so every line is full width.
- Keep the project and branch pickers in one toolbar item, or the toolbar truncates the first.
- Long lists (branches) go in a bounded, searchable popover, never a plain menu.
- Row views take plain values, not the whole engine state, and state the user must not lose goes through the engine.
- Destructive or irreversible actions in the UI ask for confirmation first.

## Testing safely on this Mac

The user's real phones and tablets are connected, and the installed app is watching their real project.

- **Check UI changes in `--demo` first.** It is the only way to click around without side effects.
- **Never press Build, Start or Install, or switch branch, on the real project without asking.** Those put builds on real devices.
- **Before editing saved settings by hand, export a backup** of the `local.shipyard` defaults, and quit the app first, or it overwrites the edit.
- **Put things back.** If a test changes the branch, the stopped state, or a device's Auto switch, restore it and say so.
- **Before installing on a simulator, check for a running `flutter run`.** Don't replace an app the user is debugging.
- Simulated accessibility presses bypass real hit-testing and keyboard focus. When the report is "clicking doesn't work", test with a real click.

## Privacy: the repository is public

Never put the user's real details into code, the README, release notes or screenshots: device names, the project name or its commit messages, Apple team ID, Firebase app IDs, tester groups, email addresses. Take README screenshots from `--demo`.

## README and UI text

- Update `README.md` in the same change whenever behaviour, settings or requirements change.
- UI text is plain and specific: say what happened and what to do next ("Locked — unlock it and it will install").
- Keep the status badge names consistent: Latest, Update available, Not installed, Installing, Locked, Failed, No build.

## Releasing

Releases are made by `.github/workflows/release.yml`, not by hand.

- **Trigger:** a push to `main` that changes `Sources/`, `Resources/`, `Package.swift`, `build-app.sh` or the workflow. Documentation-only merges do not release.
- **Version:** the latest `v*` tag with its last number raised by one. Never write a version number into a file.
- **A bigger jump** (0.3.0, 1.0.0): push that tag by hand first; numbering continues from it.
- **What it does:** runs `./build-app.sh` (so a failing self-check blocks the release), zips the app, and creates the GitHub release with generated notes plus the install steps.
- **After a release, when asked:** update the copy in `/Applications` from a local `./build-app.sh` and relaunch it.

Because pull request titles become the release notes, write them for users: what changed, in plain words. Don't commit `Shipyard.app`, `Shipyard.zip`, `.build/` or `design/logo/`.

## Known gaps (don't "fix" silently; raise them)

- The app is ad-hoc signed and not notarized.
- The repository has no license file.
- Only the Flutter path has been run on real projects; the other project types use standard commands that are untested.
- Firebase upload for iOS uses the development-signed build.
- A phone connected by USB and Wi-Fi at once shows as two devices.
