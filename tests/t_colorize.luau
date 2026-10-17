local RS = game:GetService("ReplicatedStorage")
local G = require(RS:WaitForChild("ImGui"))
local TextEditor = require(RS:WaitForChild("TextEditor"))(G)
local P = TextEditor.DocPos.new
local C = TextEditor.Color

local function eq(a, b, msg)
    assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

-- expect `color` for glyphs [from, to] (0-based, inclusive) on `line`
local function colors(e, line, from, to, color, msg)
    for i = from, to do
        eq(e:GetGlyphColor(P(line, i)), color, msg .. " @" .. line .. ":" .. i)
    end
end

-- palettes
eq(#TextEditor.GetDarkPalette(), C.count, "dark palette size")
eq(#TextEditor.GetLightPalette(), C.count, "light palette size")
eq(TextEditor.GetDarkPalette()[C.text], G.IM_COL32(224, 224, 224, 255), "dark text")
local e = TextEditor.new()
eq(e:GetPalette()[C.background], G.IM_COL32(30, 30, 30, 255), "default palette")
e:SetPalette(TextEditor.GetLightPalette())
eq(e:GetPalette()[C.background], G.IM_COL32(255, 255, 255, 255), "light palette")

-- language API
eq(e:GetLanguageName(), "None", "no language")
assert(TextEditor.LanguageDefinition == TextEditor.Language, "alias")
e:SetLanguageDefinition(TextEditor.LanguageDefinition.Lua())
eq(e:GetLanguageName(), "Lua", "lua name")
eq(e:GetLanguage(), TextEditor.Language.Lua(), "get language")

-- Lua colorizing
--            0         1         2
--            0123456789012345678901234567
e:SetText({
    'local x = 0x1F + 3.5 -- hi',
    'print("a\\"b", \'c\')',
    '--[==[ long',
    'still ]] ]==] y',
    's = [[a',
    'b]] end',
})
colors(e, 0, 0, 4, C.keyword, "local")
eq(e:GetGlyphColor(P(0, 5)), C.whitespace, "ws")
eq(e:GetGlyphColor(P(0, 6)), C.identifier, "x")
eq(e:GetGlyphColor(P(0, 8)), C.punctuation, "=")
colors(e, 0, 10, 13, C.number, "hex")
colors(e, 0, 17, 19, C.number, "float")
colors(e, 0, 21, 25, C.comment, "comment")
colors(e, 1, 0, 4, C.knownIdentifier, "print")
colors(e, 1, 6, 11, C.string, "escaped string")
eq(e:GetGlyphColor(P(1, 12)), C.punctuation, ",")
colors(e, 1, 14, 16, C.string, "single quoted")
colors(e, 2, 0, 10, C.comment, "long comment start")
colors(e, 3, 0, 12, C.comment, "long comment level")
eq(e:GetGlyphColor(P(3, 14)), C.identifier, "after long comment")
colors(e, 4, 4, 6, C.string, "long string")
colors(e, 5, 0, 2, C.string, "long string end")
colors(e, 5, 4, 6, C.keyword, "end")

-- incremental: opening a comment recolors following lines
e:SetText("a = 1\nb = 2\n")
eq(e:GetGlyphColor(P(1, 0)), C.identifier, "before")
e:ReplaceSectionText(P(0, 0), P(0, 0), "--[[")
eq(e:GetGlyphColor(P(1, 0)), C.comment, "after insert")
e:Undo()
eq(e:GetGlyphColor(P(1, 0)), C.identifier, "after undo")

-- C++
e:SetLanguage(TextEditor.Language.Cpp())
e:SetText("#include <x>\nint main() { return 42u; } /* c\n*/")
colors(e, 0, 0, 11, C.preprocessor, "preprocessor")
colors(e, 1, 0, 2, C.declaration, "int")
colors(e, 1, 13, 18, C.keyword, "return")
colors(e, 1, 20, 22, C.number, "42u")
colors(e, 1, 27, 30, C.comment, "block comment")
colors(e, 2, 0, 1, C.comment, "block comment end")

-- bracket matching
e:SetLanguage(TextEditor.Language.Lua())
e:SetText("f(a[1], {b})\n-- ( ignored\n)")
eq(e:GetGlyphColor(P(0, 1)), C.matchingBracketLevel1, "( level 1")
eq(e:GetGlyphColor(P(0, 3)), C.matchingBracketLevel2, "[ level 2")
eq(e:GetGlyphColor(P(0, 5)), C.matchingBracketLevel2, "] level 2")
eq(e:GetGlyphColor(P(0, 8)), C.matchingBracketLevel2, "{ level 2")
eq(e:GetGlyphColor(P(0, 11)), C.matchingBracketLevel1, ") level 1")
eq(e:GetGlyphColor(P(1, 3)), C.comment, "bracket in comment")
eq(e:GetGlyphColor(P(2, 0)), C.matchingBracketError, "unmatched")
e:SetCursor(P(0, 4))
e:SelectToBrackets(false)
eq(e:GetSelectedText(), "1", "select inside brackets")
e:SetCursor(P(0, 4))
e:SelectToBrackets()
eq(e:GetSelectedText(), "[1]", "select incl brackets")

-- no language resets colors
e:SetLanguage(nil)
eq(e:GetGlyphColor(P(0, 0)), C.text, "reset")

print("OK")
