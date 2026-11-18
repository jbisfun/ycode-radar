# ycode-radar

[radar](https://github.com/jbisfun/radar) inside [ycode](https://github.com/jbisfun/ycode), as a Lua extension.

- **radar: panel** opens a right-dock panel with the open reports in the pull workspace, grouped by repo. Click a report to open its file at that line. Hover it to close it.
- **radar: report** files the current editor selection. A small window shows where it points and the selected text, with a box for a note. Ctrl-Enter files it and Escape cancels.

Reports go through the `radar` CLI against `$PULL_ROOT/issues/radar.db`. The workspace is `$PULL_ROOT`, or else the nearest `pullfile.plist` above a folder open in ycode.

Bind the report action to a key in `keymap.json`:

```json
{ "context": "Editor", "bindings": { "ctrl-alt-r": ["ycode::Run", { "name": "radar::Report" }] } }
```

## Install

Link the repo into the hooks folder and reload hooks:

```sh
ln -s ~/jbisfun/ycode-radar ~/.config/zed/hooks/ycode-radar
```
