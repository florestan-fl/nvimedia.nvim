# nvimedia.nvim

Audio + video player for Neovim, backed by [mpv](https://mpv.io/).
Playback is controlled through mpv's JSON IPC socket via libuv: no `socat`/`nc` needed.

## Setup

```lua
require('nvimedia').setup({
  volume          = 80,
  shuffle         = false,
  repeat_mode     = 'none',          -- 'none' | 'queue' | 'track'
  window_position = 'bottom-right',  -- 'top-right' | 'top-left' | 'bottom-left' | 'center'
  subtitles = {
    auto       = true,      -- use song.srt next to song.mp3 automatically
    extensions = { '.srt' },
  },
})
```

## Commands

| Command              | Action                                                    |
|----------------------|-----------------------------------------------------------|
| `:MedPlay [path] [srt]` | Play a file or directory (default: current file), with an optional subtitle file |
| `:MedQueue [path]`    | Append a file or directory to the queue                   |
| `:MedToggle`          | Pause / resume (starts the current item when stopped)     |
| `:MedPause` `:MedResume` `:MedStop` | Playback control                              |
| `:MedNext` `:MedPrev`  | Next / previous item (`:MedPrev` after 3s restarts the item) |
| `:MedSeek {secs}`     | Relative seek (`:MedSeek -10`)                             |
| `:MedVolume {0-100}`  | Set volume                                                |
| `:MedShuffle`         | Toggle shuffle (applies to the next `:MedPlay`)            |
| `:MedClear`           | Stop and clear the queue                                  |
| `:MedStatus`          | Open the status window                                    |
| `:MedSub {file}`      | Use `{file}` as subtitle of the current item              |
| `:MedSub!`            | Disable subtitles for the current item                    |
| `:MedSub`             | Show the current subtitle file                            |
| `:MedLyrics`          | Hide / show the lyrics window                             |

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
