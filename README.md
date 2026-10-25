<div align="center">
  <img src="Support/Daftar.png" width="128" alt="">
  <h1>Daftar for macOS</h1>
</div>

## Introduction

Daftar is a native macOS app for an [Obsidian](https://obsidian.md) vault that is kept in a Git repository. It is the Mac part of [Daftar for Android](https://github.com/parham-alvani/notes-droid), and it uses the same colors (the naz palette on dark, Daylight on light) and the same rules for links, tasks and the calendar week notes.

The aim is to replace Obsidian on the Mac. This first release is the reader and the daily tool. The editor and the Neovim mode come in the next releases.

## Features

- **Reader:** Obsidian's markdown with wikilinks, embeds, callouts, highlights, tags, footnotes, math (KaTeX), Mermaid diagrams and colored code. Each paragraph takes its own direction, so Persian text reads right to left with no plugin.
- **Sidebar:** the folder tree with folder notes, full-text search (SQLite FTS5) in the system search field, and `#tag` search.
- **Quick open:** ⌘O finds a note by its name.
- **Inspector:** the outline, the backlinks and the tags of the note.
- **Today:** the meetings of the day from the week notes in `Calendar/` (which Daftar on the phone writes), the free time, and the tasks that are overdue, due, in progress and coming. A click on a checkbox completes a task, also a repeating one, as the Tasks plugin does.
- **Notifications:** an alert before each meeting, with a Join button, and a morning digest of the tasks that are due.
- **Menu bar and Dock:** today's meetings and tasks in the menu bar, and the count of tasks due on the Dock icon.
- **Git:** commit, pull with a rebase, and push, with the system `git` and your own SSH keys. Automatic sync is a setting, and it is off at first.

## Build

The build needs Swift 6 (the Xcode command line tools are sufficient), Node.js and [just](https://github.com/casey/just).

```bash
just test     # the Swift tests and the renderer tests
just app      # build/Daftar.app
just run      # build and start it
just install  # copy it to /Applications
```

Without Xcode, the build uses the macOS 26.5 SDK of the command line tools. The newest SDK makes SwiftUI's `@State` a macro, and the plugin for that macro ships only with Xcode.

## License

GPL-3.0. See [LICENSE](LICENSE).
