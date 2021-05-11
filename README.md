# zedikor

A simple vulkan-based modal editor written in zig. The project is only for the purposes of learning and is not intended for productive use.

## Dependencies

- glfw
- vulkan

## Running

```sh
zig build run
```

NOTE: Only tested on linux

## Keymaps

Toggle mode: ```Ctrl-j```

Command mode only

- Cursor Up: ```k```
- Cursor Down: ```j```
- Cursor Left: ```l```
- Cursor Right: ```h```
- Scroll Up: ```i```
- Scroll Down: ```m```

## Cli commands

To begin a cli command, press ':' when in command mode.

E.g ```:w /path/to/file``` or ```:q```

### Commands

- Write: ```w <filename> ```
- Open: ```o <filename>```
- Quit: ```q```

## Issues and Limitations

- Fixed text buffer size (1MB)
- No syntax highlighting
- Cursor movement differs from standard behaviour (Does not remember previous larger x-position when moving up and down lines)
- Entire vertex buffer is updated when change is detected
- Poor code quality in places
- Hardcoded font (/usr/share/fonts/TTF/Hack-Regular.ttf) and font size (16 pixels)