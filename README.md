# imguicolortextedit-luau

Syntax-highlighting text editor widget for imgui-luau (Roblox / LÖVE).

Luau port of [TextEditor](https://github.com/goossens/ImGuiColorTextEdit) for [imgui-luau](https://git.bug.tools/bug/imgui-luau) ([GitHub](https://github.com/4DBug/imgui-luau)).
Mirrors: [git.bug.tools](https://git.bug.tools/bug/imguicolortextedit-luau) / [GitHub](https://github.com/4DBug/imguicolortextedit-luau).

**Status: work in progress.**

```lua
local G = require(ReplicatedStorage.ImGui)
local TextEditor = require(ReplicatedStorage.TextEditor)(G)
```

## Development

```sh
git clone --recursive https://git.bug.tools/bug/imguicolortextedit-luau.git
bash tools/test.sh   # tests/t_*.luau in the core's Roblox mock
```

Upstream source (pinned) is in `tools/upstream/`; port-specific comments are tagged `[Port]`.

## License

MIT, see LICENSE (upstream copyright kept).
