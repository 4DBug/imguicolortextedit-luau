-- Cached state stays equal to a fresh computation: widest line (per-line column cache) and the selected text memo,
-- through edits (single/multi-line inserts and deletes, tabs, undo/redo), tab size changes and SetText.
local RS = game:GetService("ReplicatedStorage")
local G = require(RS:WaitForChild("ImGui"))
local TextEditor = require(RS:WaitForChild("TextEditor"))(G)
local P = TextEditor.DocPos.new
G.ImGui.CreateContext()

local function eq(a, b, msg)
    assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local e = TextEditor.new()
local function check(msg)
    e:updateState()
    local columns = 0
    for _, line in ipairs(e.document.lines) do columns = math.max(columns, TextEditor.lineColumns(line, e.config.tabSize)) end
    eq(e.maxColumns, columns, msg .. " columns")
    local c = e.cursors:getCurrent()
    eq(e:GetSelectedText(), e.document:getSectionTextUncached(c:getSelectionStart(), c:getSelectionEnd()), msg .. " selected text")
end

e:SetText("short\na much longer line here\n\tx\nmid line")
check("set")
e:SelectRegion(P(1, 0), P(1, 6))
check("select")
e:ReplaceTextInAllCursors("")
check("delete in line")
e:SelectRegion(P(0, 2), P(2, 1))
check("select multi")
e:ReplaceTextInAllCursors("")
check("delete multi")
e:SetCursor(P(0, 1))
e:ReplaceTextInAllCursors("0123456789012345678901234567890123456789\nnext\t\tline")
check("insert multi")
e:SelectRegion(P(1, 0), P(1, 4))
check("select after insert")
e:Undo()
check("undo")
e:Redo()
check("redo")
e:SetTabSize(8)
check("tab size")
e:SetText("a\n\t\tb")
check("set again")
e:SelectAll()
check("select all")
e:ReplaceTextInAllCursors("x")
check("replace all")
-- same section asked for again after an edit inside it
e:SetText("hello world")
eq(e:GetSectionText(P(0, 0), P(0, 5)), "hello", "section")
e:SetCursor(P(0, 1))
e:ReplaceTextInAllCursors("J")
eq(e:GetSectionText(P(0, 0), P(0, 5)), "hJell", "section after edit")
print("OK")
