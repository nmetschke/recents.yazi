# recents.yazi

Plugin for [Yazi](https://github.com/sxyazi/yazi) to show recently used files based on the [desktop-bookmark-spec](https://www.freedesktop.org/wiki/Specifications/desktop-bookmark-spec) (Linux only).

## Dependencies

The plugin requires [xmlstarlet](https://xmlstarlet.github.io) to be available.

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

## Features

- Shows the recently used files with their `added` (btime), `modified` (mtime), and `visited` (atime) time stamps.
- Deletion of entries from recently used

## Not yet implemented

- Copying files
- Adding entries to recently used
