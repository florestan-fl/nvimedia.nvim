# nvimedia.nvim

Audio + video player for Neovim, backed by [mpv](https://mpv.io/).
Playback is controlled through mpv's JSON IPC socket via libuv: no `socat`/`nc` needed.

## Requirements

- Neovim ≥ 0.9
- [mpv](https://mpv.io/) in your `$PATH`

```bash
sudo apt install mpv      # Debian/Ubuntu
sudo pacman -S mpv        # Arch
brew install mpv          # macOS
```

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'florestan-fl/nvimedia.nvim',
  lazy = false,
  opts = {},  -- calls require('nvimedia').setup({})
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'florestan-fl/nvimedia.nvim',
  config = function() require('nvimedia').setup({}) end,
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'florestan-fl/nvimedia.nvim'
" after plug#end():
lua require('nvimedia').setup({})
```

### Native packages (no plugin manager)

```bash
git clone https://github.com/florestan-fl/nvimedia.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/nvimedia.nvim
```

Then add `require('nvimedia').setup({})` to your `init.lua`.

## Configuration

`setup()` works without arguments. Defaults are shown below; pass only what you want to change:

```lua
require('nvimedia').setup({
  volume          = 80,
  shuffle         = false,
  repeat_mode     = 'none',          -- 'none' | 'queue' | 'track'
  window_position = 'bottom-right',  -- 'top-right' | 'top-left' | 'bottom-left' | 'center'
  subtitles = {
    auto       = true,               -- use song.srt next to song.mp3 automatically
    extensions = { '.srt' },
  },
  -- Keys inside the status window (:MedStatus). Set one to false to disable it.
  keymaps = {
    toggle_play  = '<Space>',
    next_track   = 'n',
    prev_track   = 'p',
    seek_forward = 'f',               -- +10s
    seek_back    = 'b',               -- -10s
    volume_up    = '+',
    volume_down  = '-',
    shuffle      = 's',
    repeat_mode  = 'r',
    close        = 'q',
  },
  -- Supported files. Setting this replaces the whole list.
  media_extensions = {
    '.mp3', '.ogg', '.wav', '.flac', '.aac', '.m4a', '.opus', '.wma',
    '.mp4', '.mkv', '.avi', '.mov', '.webm', '.flv', '.wmv', '.m4v', '.ts', '.ogv',
  },
})
```

## Commands

| Command                             | Action                                                         |
|-------------------------------------|----------------------------------------------------------------|
| `:MedPlay [path] [srt]`             | Play a file or directory (default: current file), with an optional subtitle file |
| `:MedQueue [path]`                  | Append a file or directory to the queue                        |
| `:MedToggle`                        | Pause / resume (starts the current item when stopped)          |
| `:MedPause` `:MedResume` `:MedStop` | Playback control                                               |
| `:MedNext` `:MedPrev`               | Next / previous item (`:MedPrev` after 3s restarts the item)   |
| `:MedSeek {secs}`                   | Relative seek (`:MedSeek -10`)                                 |
| `:MedVolume {0-100}`                | Set volume                                                     |
| `:MedShuffle`                       | Toggle shuffle (applies to the next `:MedPlay`)                |
| `:MedClear`                         | Stop and clear the queue                                       |
| `:MedStatus`                        | Open the status window                                         |
| `:MedSub {file}`                    | Use `{file}` as subtitle of the current item                   |
| `:MedSub!`                          | Disable subtitles for the current item                         |
| `:MedSub`                           | Show the current subtitle file                                 |
| `:MedLyrics`                        | Hide / show the lyrics window                                  |

Paths containing spaces must be escaped: `:MedPlay ~/Music/My\ Song.mp3`.

From Lua: `require('nvimedia').play(path, { subtitle = '/path/to/file.srt' })`.

## Subtitles / lyrics

With `subtitles.auto`, a file with the same name and path as the media but a
`.srt` extension is picked up automatically (`song.mp3` → `song.srt`).
A subtitle set manually (`:MedPlay <file> <srt>`, `:MedSub` or the `subtitle`
option of `play`) always takes precedence for that file. When no subtitle file
exists, nothing is shown and no message is displayed.

- Video: subtitles are rendered by mpv in its window.
- Audio: lyrics are shown in a floating window at the bottom of the editor
  (`:MedLyrics` toggles it), and in the status window (`:MedStatus`).

## AI use notice

nvimedia.nvim is my own project: I designed it and wrote the first version.
Part of the code was then reworked with the help of
[Claude](https://claude.ai) (Anthropic), an AI assistant, notably:

- fixing playback bugs, such as tracks overlapping when skipping
  to the previous/next item,
- rewriting the mpv control layer to use mpv's IPC socket directly
  (no more `socat`/`nc`),
- adding automatic `.srt` subtitle/lyrics detection,
- Neovim 0.9 compatibility, and writing this README.

I reviewed, tested and adjusted all AI-assisted changes, and I remain
responsible for the code. Issues and pull requests are welcome.
