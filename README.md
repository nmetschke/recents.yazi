# recents.yazi

Plugin for [Yazi](https://github.com/sxyazi/yazi) to show recently used files based on the [desktop-bookmark-spec](https://www.freedesktop.org/wiki/Specifications/desktop-bookmark-spec) (Linux only).
Recently used files are read and written to / from `~/.local/share/recently-used.xbel`.

## Features

- Shows the recently used files with their `added` (btime), `modified` (mtime), and `visited` (atime) time stamps with a VFS.
- Adding/Deleting/Updating entries in `recently-used.xbel`
- Copying of files from the VFS

## Not yet implemented

- Custom spotter showing recently used metadata

## Dependencies

Requires [xmlstarlet](https://xmlstarlet.github.io) to be available.

## Installation

### [Yazi Package Manager](https://yazi-rs.github.io/docs/cli/#pm)

```bash
ya pkg add nmetschke/recents
```

### Nix flakes

```nix
{
  inputs.recentsYazi = {
    url = "github:nmetschke/recents.yazi";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

## Usage

Add the following to

`vfs.toml`

```toml
[recents."*"]
kind = "hub"
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

The recently used files can be opened using `yazi recents:///@/` or by calling the plugin `plugin recents` with a keybind

`keymap.toml`

```toml
[[mgr.prepend_keymap]]
on = ["g", "r"]
run = "plugin recents"
desc = "Go to recently used"
```

The selected or hovered file(s) can be added to the recents list (or updated) using `plugin recents modify`.
For example

`keymap.toml`

```toml
[[mgr.prepend_keymap]]
on = ["o"]
run = ["plugin recents modify", "open"]
desc = "Open selected files and add to recently used"
```

will change the default `open` keybind to also add the file to `recently-used.xbel`.

## Usage with Nix Home Manager

```nix
{ pkgs, inputs, ... }:
{
  programs.yazi = {
    enable = true;
    plugins = {
      recents = inputs.recentsYazi.packages.${pkgs.stdenv.hostPlatform.system}.default;
    };
    vfs.recents."*" = {
      kind = "hub";
      run = "recents";
    };
    settings.plugin = {
      prepend_fetchers = [
        {
          url = "recents://*";
          run = "recents";
          prio = "high";
          group = "mime";
        }
      ];
      prepend_preloaders = [
        {
          mime = "recents/**";
          run = "recents";
        }
      ];
      prepend_previewers = [
        {
          mime = "recents/**";
          run = "recents";
        }
      ];
    };
    keymap = {
      mgr.prepend_keymap = [
        {
          on = [
            "g"
            "r"
          ];
          run = "plugin recents";
          desc = "Go to recently used";
        }
        {
          on = "o";
          run = [
            "plugin recents modify"
            "open"
          ];
          desc = "Open selected files and add to recently used";
        }
      ];
    };
  };
}
```
