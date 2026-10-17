local RS = game:GetService("ReplicatedStorage")
local G = require(RS:WaitForChild("ImGui"))
local TextEditor = require(RS:WaitForChild("TextEditor"))(G)
local P = TextEditor.DocPos.new

local function eq(a, b, msg)
    assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local e = TextEditor.new()
eq(e:GetLineCount(), 1, "empty line count")
eq(e:GetText(), "", "empty text")

-- round trip incl. UTF-8; upstream drops \r and appends \n after a non-empty last line
e:SetText("héllo wörld\r\nsecond ✓\n")
eq(e:GetLineCount(), 3, "line count")
eq(e:GetText(), "héllo wörld\nsecond ✓\n", "round trip")
eq(e:GetLineText(0), "héllo wörld", "line 0")
e:SetText("abc")
eq(e:GetText(), "abc\n", "trailing newline")

-- word boundaries (non-ASCII counts as word char)
e:SetText("foo héllo bar")
eq(e:FindWordStart(P(0, 7)), P(0, 4), "word start")
eq(e:FindWordEnd(P(0, 5)), P(0, 9), "word end")

-- insert + delete
e:SetText("hello world")
e:SetCursor(P(0, 5))
e:ReplaceTextInAllCursors(",\nbig")
eq(e:GetText(), "hello,\nbig world\n", "insert")
eq(e:GetCursorPosition(0), P(1, 3), "cursor after insert")
e:SelectRegion(P(0, 5), P(1, 4))
eq(e:GetSelectedText(), ",\nbig ", "region")
e:ReplaceTextInCurrentCursor("")
eq(e:GetText(), "helloworld\n", "delete")
e:ReplaceSectionText(P(0, 0), P(0, 5), "")
eq(e:GetText(), "world\n", "section delete")

-- undo/redo
assert(e:CanUndo() and not e:CanRedo(), "can undo")
e:Undo()
eq(e:GetText(), "helloworld\n", "undo 1")
e:Undo()
eq(e:GetText(), "hello,\nbig world\n", "undo 2")
e:Undo()
eq(e:GetText(), "hello world\n", "undo 3")
assert(not e:CanUndo() and e:CanRedo(), "can redo")
e:Redo(); e:Redo(); e:Redo()
eq(e:GetText(), "world\n", "redo")

-- read only
e:SetReadOnly(true)
assert(e:IsReadOnly() and not e:CanUndo(), "read only")
e:ReplaceTextInAllCursors("x")
eq(e:GetText(), "world\n", "read only blocks edits")
e:SetReadOnly(false)

-- SelectAll + GetSelectedText
e:SetText("a\nb✓\nc")
assert(not e:HasSelection(), "no selection")
e:SelectAll()
assert(e:HasSelection(), "selection")
eq(e:GetSelectedText(), "a\nb✓\nc", "select all")
local sel = e:GetMainCursorSelection()
eq(sel.start, P(0, 0), "sel start"); eq(sel["end"], P(2, 1), "sel end")

-- multi-cursor typing
e:SetText("ab\ncd")
e:SetCursor(P(0, 1))
e:AddCursor(P(1, 1))
e:ReplaceTextInAllCursors("X")
eq(e:GetText(), "aXb\ncXd\n", "multi cursor")
eq(e:GetNumberOfCursors(), 2, "cursor count")
e:Undo()
eq(e:GetText(), "ab\ncd\n", "multi undo")

print("OK")
