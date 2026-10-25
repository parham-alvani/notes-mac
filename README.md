<div align="center">
  <img src="Support/Daftar.png" width="128" alt="">
  <h1>Daftar for macOS</h1>
</div>

## Introduction

Daftar is a native macOS app for an [Obsidian](https://obsidian.md) vault that is kept in a Git repository. It is the Mac part of [Daftar for Android](https://github.com/parham-alvani/notes-droid), and it uses the same colors (the naz palette on dark, Daylight on light) and the same rules for links, tasks and the calendar week notes.

The aim is to replace Obsidian on the Mac. It has the reader, the daily tool and the editor; the Neovim mode comes next.

## Features

- **Reader:** Obsidian's markdown with wikilinks, embeds, callouts, highlights, tags, footnotes, math (KaTeX), Mermaid diagrams and colored code. Each paragraph takes its own direction, so Persian text reads right to left with no plugin. Callouts have their icons, each tag has its own color, `==🔴 text==` and the other five circles color a highlight as in Obsidian, task dates and priorities are colored chips, a code block shows its language and a copy button, and a thin bar at the top shows how far you have read. Videos, sounds and PDFs play in the note.
- **Find:** ⌘F finds in the note, in the reader and in the editor. ⌘G and ⇧⌘G go to the next and the previous match.
- **Editor:** ⌘E opens the note's markdown, styled as you type in the same colors as the reader, with the cursor's line lit and the words and characters counted in the bar under it. It saves a second after you stop typing. It shows embedded images, completes `[[` links from the vault's notes, continues lists on Return, moves list items by four spaces with Tab, ticks a task with ⌘↩, and saves a pasted image to the attachment folder.
- **Neovim mode:** a setting that makes your own Neovim the editor. Neovim owns the buffer and writes the file, with your `init.lua`, motions, macros and plugins; the editor shows it with its colors, images and right-to-left text, a block cursor in Normal mode, and a bar with the mode and the command line.
- **Task queries:** ` ```tasks ` blocks show their tasks, grouped and sorted as the Tasks plugin does, with a checkbox that ticks the task in its own note. A line the app cannot read is shown above the result.
- **Fonts:** New York for notes and JetBrains Mono for code by default, both settings, with Vazirmatn for Persian.
- **Sidebar:** the folder tree with folder notes, full-text search (SQLite FTS5) in the system search field, and `#tag` search.
- **Bases:** a `.base` file opens as its views, with a tab for each: the filters, formulas, sort, `groupBy` and `limit` of Obsidian Bases, with the same expression language (`file.*`, `formula.*`, dates and durations, `if()`, string and list methods). `![[x.base]]`, `![[x.base#View]]` and ` ```base ` blocks show a base inside a note. Every view type is shown as a table. A filter that the app cannot read is shown above the table and is not applied.
- **Pictures:** a click on an image or a Mermaid diagram shows it as large as the window. A click or Escape closes it.
- **Quick open:** ⌘P or ⌘O finds a note or a base by its name. Obsidian's excluded files (`userIgnoreFilters`) stay out of it and out of search.
- **Files:** ⌘N makes a note in the open note's folder, ⇧⌘N a folder. Rename (⌘R), move (⌥⌘M, or drag onto a folder in the sidebar) and move to the Trash, from the File menu or a right click. When a file or a folder moves, every link to it in the vault follows, in the style it was written, as Obsidian's "always update links" does. A folder note takes its folder's new name.
- **Inspector:** the outline in the heading colors, the backlinks, the outgoing links (a missing note in red) and the tags of the note.
- **Edit a task:** a right click on a task, in a note or on the Today page, opens a form for its text, status, priority, due, scheduled and start dates and repeat rule. It writes the line in the Tasks plugin's order and keeps the tags, the block ID and the rest.
- **Tags:** the sidebar lists the vault's tags as a tree, `#a/b` under `#a`, each in its color with its count. A click lists the notes.
- **Missing links:** a click on a link to a note that is not there yet makes the note and opens it in the editor.
- **Slash commands:** in the editor, `/` at the start of a line or after a space opens a menu of headings, tasks, callouts, code, Mermaid, math, tables, links, dates and the six highlight colors.
- **Extract:** ⌥⌘X moves the editor's selection to a new note and puts a link to it in its place, as Obsidian's note composer does.
- **Tabs:** every window is a tab of one window. ⌘T opens a tab, and ⌘-click on a link opens the note in a new tab.
- **Command palette:** ⇧⌘P runs any command by its name, with a fuzzy match, and keeps the commands you used last at the top.
- **Link preview:** hold the pointer on a link to a note to see the note, or the section the link names, in a card.
- **Bookmarks:** ⌘D bookmarks the note. The sidebar shows the bookmarks at the top, from Obsidian's own `.obsidian/bookmarks.json`, groups too, and keeps the kinds it does not show when it writes the file. A bookmark follows its file when the file moves.
- **Graph:** ⌥⌘G shows the open note and the notes up to four links away, or the whole vault. Each top folder has its color, a note grows with its links, and a click opens it.
- **Today:** the meetings of the day from the week notes in `Calendar/` (which Daftar on the phone writes), the free time, and the tasks that are overdue, due, in progress and coming. A click on a checkbox completes a task, also a repeating one, as the Tasks plugin does.
- **Notifications:** an alert before each meeting, with a Join button, and a morning digest of the tasks that are due.
- **Menu bar and Dock:** today's meetings and tasks in the menu bar, and the count of tasks due on the Dock icon.
- **Git:** commit, pull with a rebase, and push, with the system `git` and your own SSH keys. The toolbar shows the branch and the changed files. The app pulls when it starts, and automatic sync is a setting that is off at first.
- **Terminal:** ⌃` opens your login shell in the vault's folder, under the note, in the same colors.
- **Icons:** the folders and notes show the icons and colors of the Iconic plugin. A `logo.svg` (or `logo.png`, `.webp`, `.jpg`) in a folder is that folder's icon, for example a company's logo on its folder; the file itself is not listed. Daftar on Android shows the same logos.
- **Breadcrumb:** a bar above the note shows the vault, its folders and the note. A folder opens a menu of what is in it, and the note's crumb has the file commands.

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
