# imguicolortextedit-luau

Syntax-highlighting text editor widget for imgui-luau (Roblox / LÖVE).

Luau port of [TextEditor](https://github.com/goossens/ImGuiColorTextEdit) for [imgui-luau](https://git.bug.tools/bug/imgui-luau) ([GitHub](https://github.com/4DBug/imgui-luau)).
Mirrors: [git.bug.tools](https://git.bug.tools/bug/imguicolortextedit-luau) / [GitHub](https://github.com/4DBug/imguicolortextedit-luau).

**Status: work in progress** (core editor usable, see below).

## Usage

```lua
local G = require(ReplicatedStorage.ImGui)
local TextEditor = require(ReplicatedStorage.TextEditor)(G)

local editor = TextEditor.new()
editor:SetLanguage(TextEditor.Language.Lua())
editor:SetText("local x = 1\nprint(x)")

-- every frame, between ImGui.NewFrame() and ImGui.Render():
ImGui.Begin("Editor")
editor:Render("TextEditor")          -- Render(title, size?, childFlags?, windowFlags?)
ImGui.End()
```

Full demo (menu bar, status line, palettes): `examples/roblox/main.client.luau`.

**Positions are 0-based**, exactly like upstream: `TextEditor.DocPos.new(line, index)`, line numbers and
cursor numbers all start at 0 (internally the document is a 1-based Lua array).

## Public API

- Construction / config: `TextEditor.new`, `Set/GetTabSize`, `SetInsertSpacesOnTabs`, `Set/IsReadOnlyEnabled`,
  `SetAutoIndentEnabled`, `SetOverwriteEnabled`/`IsOverwriteEnabled`, `SetShowWhitespacesEnabled`, `SetShowSpacesEnabled`,
  `SetShowTabsEnabled`, `SetShowLineNumbersEnabled`, `SetShowCurrentLineHighlightEnabled`, `SetShowMatchingBrackets`,
  `SetCompletePairedGlyphs`, `SetLineSpacing`, `SetCaretsVisible`, `SetLineNumberLeftMargin`, `SetTextLeftMargin`
- Palette: `SetPalette`/`GetPalette`, `TextEditor.GetDarkPalette`, `GetLightPalette`, `Set/GetDefaultPalette`
- Language: `SetLanguage`/`GetLanguage`/`HasLanguage`/`GetLanguageName`, `SetLanguageChangeCallback`,
  `TextEditor.Language.C()`, `.Cpp()`, `.Lua()`
- Text: `SetText`, `GetText`, `GetSectionText`, `GetCursorText`, `GetLineText`, `GetSelectedText`,
  `ReplaceSectionText`, `ReplaceTextInCurrentCursor`, `ReplaceTextInAllCursors`, `ClearText`, `IsEmpty`, `GetLineCount`
- Undo: `Undo`, `Redo`, `CanUndo`, `CanRedo`, `GetUndoIndex`, `SetTransactionCallback`/`ClearTransactionCallback`
- Selection / cursors: `SelectAll`, `SelectLine`, `SelectLines`, `SelectRegion`, `SelectToBrackets`, `SetCursor`,
  `AddCursor`, `ClearCursors`, `GetNumberOfCursors`, `Get{Main,Current}CursorPosition`, `Get{Main,Current}CursorSelection`,
  `AnyCursorHasSelection`, `AllCursorsHaveSelection`, `FindWordStart`/`FindWordEnd`
- Clipboard: `Cut`, `Copy`, `Paste`
- Rendering / view: `Render`, `SetFocus`, `ScrollToLine`, `GetFirst/LastVisibleRow/Column`, `GetGlyphColor`
- Markers / menus: `AddMarker`, `ClearMarkers`, `HasMarkers`, `SetLineNumberContextMenuCallback`, `SetTextContextMenuCallback`

## Port status

Ported: document model, multi-cursor editing, undo/redo transactions, keyboard/mouse input, clipboard,
find/replace, bracket matching, markers, palettes, colorizer, C / C++ / Lua languages.

`[Port] TODO`: word wrap, line folding, mini-map, autocomplete, squiggles/decorations, other languages
(C#, AngelScript, Python, GLSL, HLSL, JSON, Markdown, SQL), TextDiff, LSP bridge.

## Development

```sh
git clone --recursive https://git.bug.tools/bug/imguicolortextedit-luau.git
bash tools/test.sh   # tests/t_*.luau + the example in the core's Roblox mock
```

Upstream source (pinned) is in `tools/upstream/`; port-specific comments are tagged `[Port]`.

## License

MIT, see LICENSE (upstream copyright kept).
