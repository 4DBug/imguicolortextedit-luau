-- Editing commands and find/replace through the public API (no rendering).
local RS = game:GetService("ReplicatedStorage")
local G = require(RS:WaitForChild("ImGui"))
local TextEditor = require(RS:WaitForChild("TextEditor"))(G)
local P = TextEditor.DocPos.new

local function eq(a, b, msg)
    assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local e = TextEditor.new()
e:SetLanguage(TextEditor.Language.Lua())

-- toggle comments (Lua "--"), keeps indentation, round-trips
e:SetText("local a = 1\n    print(a)\n")
e:SelectLines(0, 2)
e:ToggleComments()
eq(e:GetText(), "-- local a = 1\n    -- print(a)\n", "comment")
e:SelectLines(0, 2)
e:ToggleComments()
eq(e:GetText(), "local a = 1\n    print(a)\n", "uncomment")
e:Undo()
eq(e:GetText(), "-- local a = 1\n    -- print(a)\n", "undo uncomment")

-- move lines
e:SetText("one\ntwo\nthree")
e:SetCursor(P(1, 1))
e:MoveUpLines()
eq(e:GetText(), "two\none\nthree\n", "move up")
eq(e:GetCursorPosition(0), P(0, 1), "move up cursor")
e:MoveUpLines()
eq(e:GetText(), "two\none\nthree\n", "move up at top is a no-op")
e:MoveDownLines()
e:MoveDownLines()
eq(e:GetText(), "one\nthree\ntwo\n", "move down")
eq(e:GetCursorPosition(0), P(2, 1), "move down cursor")

-- case changes
e:SetText("Hello World")
e:SelectRegion(P(0, 0), P(0, 5))
e:SelectionToUpperCase()
eq(e:GetText(), "HELLO World\n", "upper")
e:SelectAll()
e:SelectionToLowerCase()
eq(e:GetText(), "hello world\n", "lower")

-- tabs/spaces (tab size 4) and trailing whitespace
e:SetTabSize(4)
e:SetText("\tx\n  \ty\nab\tc")
e:TabsToSpaces()
eq(e:GetText(), "    x\n    y\nab  c\n", "tabs to spaces")
e:SetText("    x\n        y\nab  c")
e:SpacesToTabs()
eq(e:GetText(), "\tx\n\t\ty\nab\tc\n", "spaces to tabs")
e:SetText("a  \nb\t\n  ")
e:StripTrailingWhitespaces()
eq(e:GetText(), "a\nb\n", "strip trailing")

-- find + replace all (case-insensitive by default, then case-sensitive and whole word)
e:SetText("foo Foo food foo")
e:SetFindString("foo")
e:SetReplaceString("bar")
e:ReplaceAll()
eq(e:GetText(), "bar bar bard bar\n", "replace all")
e:SetText("foo Foo food foo")
e:SetFindCaseSensitive(true)
e:SetFindWholeWord(true)
e:ReplaceAll()
eq(e:GetText(), "bar Foo food bar\n", "replace all case+word")
e:SetText("x x x")
e:SetFindString("x")
e:SetReplaceString("y")
e:SetCursor(P(0, 0))
e:Replace()
eq(e:GetText(), "y x x\n", "replace one")
e:FindAll()
eq(e:GetNumberOfCursors(), 2, "find all")

-- grow/shrink selections
e:SetText("f(abc)")
e:SetCursor(P(0, 3))
e:GrowSelections()
eq(e:GetSelectedText(), "abc", "grow to word")
e:GrowSelections()
eq(e:GetSelectedText(), "(abc)", "grow to brackets")
e:ShrinkSelections()
eq(e:GetSelectedText(), "abc", "shrink")

print("OK")
