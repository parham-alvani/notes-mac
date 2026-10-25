<div align="center">
  <img src="Support/Daftar.png" width="128" alt="">
  <h1>Daftar for macOS</h1>
</div>

## Introduction

Daftar is a native macOS app for an [Obsidian](https://obsidian.md) vault that is kept in a Git repository. It is the Mac part of [Daftar for Android](https://github.com/parham-alvani/notes-droid), and it uses the same colors (the naz palette on dark, Daylight on light) and the same rules for links, tasks and the calendar week notes.

The aim is to replace Obsidian on the Mac. It has the reader, the daily tool and the editor; the Neovim mode comes next.

## Features

- **Reader:** Obsidian's markdown with wikilinks, embeds, callouts, highlights, tags, footnotes, math (KaTeX), Mermaid diagrams and colored code. Each paragraph takes its own direction, so Persian text reads right to left with no plugin.
- **Editor:** ⌘E opens the note's markdown, styled as you type in the same colors. It saves a second after you stop typing. It shows embedded images, completes `[[` links from the vault's notes, continues lists on Return, moves list items by four spaces with Tab, ticks a task with ⌘↩, and saves a pasted image to the attachment folder.
- **Task queries:** ` ```tasks ` blocks show their tasks, grouped and sorted as the Tasks plugin does, with a checkbox that ticks the task in its own note. A line the app cannot read is shown above the result.
- **Fonts:** New York for notes and JetBrains Mono for code by default, both settings, with Vazirmatn for Persian.
- **Sidebar:** the folder tree with folder notes, full-text search (SQLite FTS5) in the system search field, and `#tag` search.
- **Quick open:** ⌘O finds a note by its name.
- **Inspector:** the outline, the backlinks and the tags of the note.
- **Today:** the meetings of the day from the week notes in `Calendar/` (which Daftar on the phone writes), the free time, and the tasks that are overdue, due, in progress and coming. A click on a checkbox completes a task, also a repeating one, as the Tasks plugin does.
- **Notifications:** an alert before each meeting, with a Join button, and a morning digest of the tasks that are due.
- **Menu bar and Dock:** today's meetings and tasks in the menu bar, and the count of tasks due on the Dock icon.
- **Git:** commit, pull with a rebase, and push, with the system `git` and your own SSH keys. The toolbar shows the branch and the changed files. The app pulls when it starts, and automatic sync is a setting that is off at first.
- **Terminal:** ⌃` opens your login shell in the vault's folder, under the note, in the same colors.
- **Icons:** the folders and notes show the icons and colors of the Iconic plugin.

## Configuration

Every setting is in one file, `~/.config/daftar/config.toml`. The app makes it on the first start, with a comment on each setting. Edit it in any editor and the app follows the change at once, or use the Settings window, which writes back only the value that you change. The file is safe to keep in your dotfiles.

## Build

The build needs Swift 6 (the Xcode command line tools are sufficient), Node.js and [just](https://github.com/casey/just).

```bash
just test     # the Swift tests and the renderer tests
just app      # build/Daftar.app
just run      # build and start it
just install  # copy it to /Applications
```

Xcode is not necessary. The code uses no SwiftUI macro, because the plugin for those macros ships only with Xcode.

## License

GPL-3.0. See [LICENSE](LICENSE).
