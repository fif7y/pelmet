# Contributing to Pelmet

Thanks for helping. Issues, bug reports with `pelmet.log` excerpts, and pull requests are all welcome.

## Before your first pull request

Pelmet uses a Contributor License Agreement. When you open a pull request, a bot asks you to sign it by posting one comment, once. The short version: you keep your copyright, the GPLv3 version of Pelmet stays GPLv3 forever, and you grant a license broad enough for things like a Mac App Store build or a future license fix. The full text and the reasons are in [CLA.md](CLA.md).

## Building

- Xcode with the macOS 27 SDK, `xcodegen` (`brew install xcodegen`).
- `xcodegen generate` then open `Pelmet.xcodeproj`.
- Tests: `PelmetCore` and `PelmetEngine` are Swift packages (`swift test` inside each), app tests run with `xcodebuild test`.

## Pull requests

- One change per PR, with a short description of the behavior before and after.
- Add or update tests in `PelmetCore` or `PelmetEngine` when you touch section policy, adoption, or converge logic.
- Say what you verified by hand on a real menu bar (hide, reveal, ⌘-drag adoption) and on which macOS build.
