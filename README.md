# recents.yazi

Plugin for [Yazi](https://github.com/sxyazi/yazi) to show recently used files based on the [desktop-bookmark-spec](https://www.freedesktop.org/wiki/Specifications/desktop-bookmark-spec) (Linux only).
The plugin accesses `recently-used.xbel`.

## Features

- Shows the recently used files with their `added` (btime), `modified` (mtime), and `visited` (atime) time stamps.
- Adding entries to recently used
- Deletion of entries from recently used

## Not yet implemented

- Some file operations in the recents VFS (open, copy)
- Custom spotter showing recently used metadata

## Dependencies

- [xmlstarlet](https://xmlstarlet.github.io)

## Usage

Add the following to

`vfs.toml`

```toml
[recents.""]
kind = "scope"
run = "recents"
```

and

`yazi.toml`

```toml
[[plugin.prepend_fetchers]]
group = "mime"
prio = "high"
run = "recents"
url = "recents://*"

[[plugin.prepend_preloaders]]
mime = "recents/**"
run = "recents"

[[plugin.prepend_previewers]]
mime = "recents/**"
run = "recents"

```

.

The recently used files can be opened using `yazi recents://` or with a keybind

`keymap.toml`

```toml
[[mgr.prepend_keymap]]
on = ["g", "r"]
run = "cd recents://"
desc = "Go to recently used"
```

.

The selected or hovered file(s) can be added to the recents list (or updated) using `plugin recents modify`.
For example

`keymap.toml`

```toml
[[mgr.prepend_keymap]]
on = ["o"]
run = ["pluging recents modify", "open"]
desc = "Open selected files and add to recently used"
```

will overwrite the default `open` command to also add the file to `recently-used.xbel`.
