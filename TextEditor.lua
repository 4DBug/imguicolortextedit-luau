-- TextEditor for imgui-luau. Port of https://github.com/goossens/ImGuiColorTextEdit (b12d713e77e8edddff1e69973f67085ac9cfaf74).
-- Usage: local TextEditor = require(path.to.TextEditor)(require(path.to.ImGui))
--
-- [Port] Indexing conventions:
--   * Public API (DocPos.line / DocPos.index, line numbers, cursor numbers) is 0-based, exactly like upstream.
--   * Internally the document is a 1-based Lua array: line `n` (0-based) is `document.lines[n + 1]`,
--     glyph `i` (0-based) of a line is `line[i + 1]`. Cursor `c` (0-based) is `cursors.list[c + 1]`.
--   * Text is UTF-8 encoded Lua strings; glyphs store unicode codepoints.
--
-- [Port] Only the non-UI data layer is ported so far: Document, Cursor/Cursors, Transactions (undo/redo),
-- text get/set, insert/delete, word boundaries, palettes, languages/colorizer and bracketeer. Rendering, folding,
-- typesetting, markers, squiggles and find/replace are not ported yet.
return function(G)
    local ImGui, ImVec2, ImVec4 = G.ImGui, G.ImVec2, G.ImVec4
    local TextEditor = {}
    TextEditor.__index = TextEditor

    -- color palette support
    -- [Port] enum values are 1-based so they index a Palette (a Lua array of IM_COL32 ints) directly
    local Color = {
        text = 1,
        keyword = 2,
        declaration = 3,
        number = 4,
        string = 5,
        punctuation = 6,
        preprocessor = 7,
        identifier = 8,
        knownIdentifier = 9,
        comment = 10,
        background = 11,
        cursor = 12,
        selection = 13,
        whitespace = 14,
        matchingBracketBackground = 15,
        matchingBracketActive = 16,
        matchingBracketLevel1 = 17,
        matchingBracketLevel2 = 18,
        matchingBracketLevel3 = 19,
        matchingBracketError = 20,
        lineNumber = 21,
        currentLineNumber = 22,
        currentLineHighlight = 23,
        currentLineHighlightBorder = 24,
        count = 24,
    }
    TextEditor.Color = Color

    -- colorizer/tokenizer state
    -- [Port] LineState is a plain integer enum (same order as upstream)
    local LineState = {
        inText = 0,
        inComment = 1, -- inCommentLevel1..7 = 2..8
        inSingleQuotedString = 9,
        inDoubleQuotedString = 10,
        inOtherString = 11,
        inOtherStringAlt = 12,
        inStringLevel0 = 13, -- inStringLevel1..7 = 14..20
    }
    local maxCommentLevel = 7
    local maxStringLevel = 7
    local function lineStateInComment(state) return state >= 1 and state <= 8 end
    local function lineStateInStringLevel(state) return state >= 13 and state <= 20 end
    local function commentLevelToLineState(level) return LineState.inComment + level end
    local function stringLevelToLineState(level) return LineState.inStringLevel0 + level end

    --
    -- DocPos: logical position of a glyph expressed as a line number and glyph index (both zero-based)
    --

    local DocPos = {}
    DocPos.__index = DocPos
    TextEditor.DocPos = DocPos

    local function newDocPos(line, index)
        return setmetatable({ line = line or 0, index = index or 0 }, DocPos)
    end
    DocPos.new = newDocPos

    DocPos.__eq = function(a, b) return a.line == b.line and a.index == b.index end
    DocPos.__lt = function(a, b)
        if a.line ~= b.line then return a.line < b.line end
        return a.index < b.index
    end
    DocPos.__le = function(a, b)
        if a.line ~= b.line then return a.line < b.line end
        return a.index <= b.index
    end
    DocPos.__tostring = function(a) return "DocPos(" .. a.line .. ", " .. a.index .. ")" end

    -- [Port] DocSelection is a plain table { start = DocPos, ["end"] = DocPos }
    local function newDocSelection(s, e)
        return { start = s, ["end"] = e }
    end

    --
    -- CodePoint
    --

    local CodePoint = {}

    -- [Port] decode UTF-8 into a list of codepoints; invalid sequences fall back to one codepoint per byte
    function CodePoint.decode(text)
        local out = {}
        local ok = pcall(function()
            for _, c in utf8.codes(text) do
                out[#out + 1] = c
            end
        end)
        if not ok then
            table.clear(out)
            for i = 1, #text do
                out[i] = string.byte(text, i)
            end
        end
        return out
    end

    function CodePoint.write(codepoint)
        return utf8.char(codepoint)
    end

    -- [Port] ASCII rules as upstream; the unicode whitespace table is reduced to a few common codepoints
    function CodePoint.isWhiteSpace(codepoint)
        if codepoint < 0x7f then
            return codepoint == 32 or (codepoint >= 9 and codepoint <= 13)
        end
        return codepoint == 0x85 or codepoint == 0xA0 or codepoint == 0x1680 or (codepoint >= 0x2000 and codepoint <= 0x200A)
            or codepoint == 0x2028 or codepoint == 0x2029 or codepoint == 0x202F or codepoint == 0x205F or codepoint == 0x3000
    end

    -- [Port] ASCII rules as upstream; every other non-whitespace codepoint counts as a word character
    function CodePoint.isWord(codepoint)
        if codepoint < 0x7f then
            return (codepoint >= 97 and codepoint <= 122) or (codepoint >= 65 and codepoint <= 90)
                or (codepoint >= 48 and codepoint <= 57) or codepoint == 95
        end
        return not CodePoint.isWhiteSpace(codepoint)
    end

    -- [Port] no east asian width tables: every glyph is one column wide
    function CodePoint.getGlyphWidth(codepoint)
        return 1
    end

    TextEditor.CodePoint = CodePoint

    --
    -- Document: the document being edited (Lines of Glyphs)
    -- a glyph is { codepoint = number, color = Color }
    --

    local Document = {}
    Document.__index = Document

    local function newGlyph(codepoint, color)
        return { codepoint = codepoint, color = color or Color.text }
    end

    function Document.new()
        local self = setmetatable({ lines = {}, updated = false }, Document)
        self:appendLine()
        return self
    end

    function Document:size() return #self.lines end
    function Document:at(line) return self.lines[line + 1] end

    -- [Port] a line is an array of glyphs with hash fields { needsColorizing, state } (upstream's Line members)
    local function newLine()
        return { needsColorizing = true, state = LineState.inText }
    end

    function Document:appendLine()
        self.lines[#self.lines + 1] = newLine()
    end

    function Document:insertLine(offset)
        table.insert(self.lines, offset + 1, newLine())
    end

    function Document:deleteLines(s, e)
        for _ = s, e do
            table.remove(self.lines, s + 1)
        end
    end

    function Document:clearDocument()
        table.clear(self.lines)
    end

    function Document:getSpacesToTab(config, line, index)
        local columns = 0
        for i = 1, index do
            columns = columns + CodePoint.getGlyphWidth(line[i].codepoint)
        end
        return (math.floor(columns / config.tabSize) + 1) * config.tabSize - columns
    end

    function Document:setUtf8Text(config, text)
        -- reset document
        self:clearDocument()
        self:appendLine()

        -- process UTF-8 and generate lines of glyphs
        local cps = CodePoint.decode(text)
        for _, character in ipairs(cps) do
            local back = self.lines[#self.lines]
            if character == 10 then
                self:appendLine()
            elseif config.insertSpacesOnTabs and character == 9 then
                local spaces = self:getSpacesToTab(config, back, #back)
                for _ = 1, spaces do
                    back[#back + 1] = newGlyph(32)
                end
            elseif character ~= 13 then
                back[#back + 1] = newGlyph(character)
            end
        end

        -- [Port] updateIndents skipped (used by rendering only)
        self.updated = true
    end

    -- insert/delete part of the document's text (strings are UTF-8 encoded)
    function Document:insertText(config, start, text)
        local lineNo = start.line
        local line = self:at(lineNo)
        local index = start.index

        -- process all codepoints
        for _, character in ipairs(CodePoint.decode(text)) do
            if character == 10 then
                -- split line
                self:insertLine(lineNo + 1)
                lineNo = lineNo + 1
                local nextLine = self:at(lineNo)
                for j = index + 1, #line do
                    nextLine[#nextLine + 1] = line[j]
                end
                for j = #line, index + 1, -1 do
                    line[j] = nil
                end
                line = nextLine
                index = 0
            elseif config.insertSpacesOnTabs and character == 9 then
                local spaces = self:getSpacesToTab(config, line, index)
                for _ = 1, spaces do
                    index = index + 1
                    table.insert(line, index, newGlyph(32))
                end
            elseif character ~= 13 then
                -- insert next glyph
                index = index + 1
                table.insert(line, index, newGlyph(character))
            end
        end

        -- determine end of insert
        local e = newDocPos(lineNo, index)

        -- mark affected lines as changed
        for j = start.line, e.line do
            self:at(j).needsColorizing = true
        end

        self.updated = true
        return e
    end

    function Document:deleteText(config, start, e)
        local startLine = self:at(start.line)
        local endLine = self:at(e.line)

        -- see if start and end are on the same line
        if start.line == e.line then
            local n = #startLine
            table.move(startLine, e.index + 1, n, start.index + 1)
            for j = n - (e.index - start.index) + 1, n do
                startLine[j] = nil
            end
        else
            -- start and end are on different lines
            -- remove end of first line, then join with the remainder of the last line
            for j = #startLine, start.index + 1, -1 do
                startLine[j] = nil
            end
            for j = e.index + 1, #endLine do
                startLine[#startLine + 1] = endLine[j]
            end

            -- delete lines
            self:deleteLines(start.line + 1, e.line)
        end

        -- mark line and document as changed
        startLine.needsColorizing = true
        self.updated = true
    end

    -- get document text as UTF-8
    function Document:getUtf8Text()
        local parts = {}
        local n = #self.lines
        for l = 1, n do
            local line = self.lines[l]
            for i = 1, #line do
                parts[#parts + 1] = utf8.char(line[i].codepoint)
            end
            if l ~= n or #line > 0 then
                parts[#parts + 1] = "\n"
            end
        end
        return table.concat(parts)
    end

    -- get part of document text (returned strings are UTF-8 encoded)
    function Document:getSectionText(start, e)
        local parts = {}
        local lineNo = start.line
        local index = start.index
        while lineNo < e.line or index < e.index do
            local line = self:at(lineNo)
            if index < #line then
                parts[#parts + 1] = utf8.char(line[index + 1].codepoint)
                index = index + 1
            else
                parts[#parts + 1] = "\n"
                lineNo = lineNo + 1
                index = 0
            end
        end
        return table.concat(parts)
    end

    function Document:getLineText(line)
        return self:getSectionText(newDocPos(line, 0), newDocPos(line, #self:at(line)))
    end

    function Document:getCodePoint(location)
        local line = self:at(location.line)
        if location.index < #line then
            return line[location.index + 1].codepoint
        end
        return 0xFFFD -- IM_UNICODE_CODEPOINT_INVALID
    end

    function Document:getColor(location)
        local line = self:at(location.line)
        if location.index < #line then
            return line[location.index + 1].color
        end
        return Color.text
    end

    -- see if document is empty
    function Document:isEmpty() return #self.lines == 1 and #self.lines[1] == 0 end

    -- [Port] no folding: hidden line helpers just move to the neighbouring line
    function Document:getLeftBeforeHiddenLines(pos)
        if pos.line == 0 then
            return newDocPos(0, 0)
        end
        return newDocPos(pos.line - 1, #self:at(pos.line - 1))
    end

    function Document:getRightAfterHiddenLines(pos)
        if pos.line + 1 >= #self.lines then
            return self:getBottom()
        end
        return newDocPos(pos.line + 1, 0)
    end

    -- coordinate operations in context of document
    function Document:getLeft(from, wordMode)
        if wordMode then
            -- first move left by one glyph
            from = self:getLeft(from)
            -- now skip all whitespaces
            from = self:findPreviousNonWhiteSpace(from, false)
            -- find the start of the current word
            return self:findWordStart(from)
        else
            -- calculate position of previous glyph (could be on previous line)
            if from.index == 0 then
                return self:getLeftBeforeHiddenLines(from)
            end
            return newDocPos(from.line, from.index - 1)
        end
    end

    function Document:getRight(from, wordMode)
        if wordMode then
            -- first move right by one glyph
            from = self:getRight(from)
            -- now skip all whitespaces
            from = self:findNextNonWhiteSpace(from, false)
            -- find the end of the current word
            return self:findWordEnd(from)
        else
            -- calculate pos of next glyph (could be on next line)
            if from.index == #self:at(from.line) then
                return self:getRightAfterHiddenLines(from)
            end
            return newDocPos(from.line, from.index + 1)
        end
    end

    function Document:getTop() return newDocPos(0, 0) end
    function Document:getBottom()
        local lastLine = #self.lines - 1
        return newDocPos(lastLine, #self:at(lastLine))
    end
    function Document:getStartOfLine(from) return newDocPos(from.line, 0) end
    function Document:getEndOfLine(from) return newDocPos(from.line, #self:at(from.line)) end
    function Document:getNextLine(from) return self:getRight(self:getEndOfLine(from)) end

    -- search in document
    function Document:findWordStart(from, wordOnly)
        local line = self:at(from.line)
        if from.index == 0 or #line == 0 then
            return from
        end

        local index = from.index
        local firstCharacter = line[index].codepoint
        local isWord, isWhiteSpace = CodePoint.isWord, CodePoint.isWhiteSpace

        if not wordOnly and isWhiteSpace(firstCharacter) then
            while index > 0 and isWhiteSpace(line[index].codepoint) do
                index = index - 1
            end
        elseif isWord(firstCharacter) then
            while index > 0 and isWord(line[index].codepoint) do
                index = index - 1
            end
        else
            while not wordOnly and index > 0 and not isWord(line[index].codepoint) and not isWhiteSpace(line[index].codepoint) do
                index = index - 1
            end
        end

        return newDocPos(from.line, index)
    end

    function Document:findWordEnd(from, wordOnly)
        local line = self:at(from.line)
        local size = #line
        local index = from.index
        if index >= size then
            return from
        end

        local firstCharacter = line[index + 1].codepoint
        local isWord, isWhiteSpace = CodePoint.isWord, CodePoint.isWhiteSpace

        if not wordOnly and isWhiteSpace(firstCharacter) then
            while index < size and isWhiteSpace(line[index + 1].codepoint) do
                index = index + 1
            end
        elseif isWord(firstCharacter) then
            while index < size and isWord(line[index + 1].codepoint) do
                index = index + 1
            end
        else
            while not wordOnly and index < size and not isWord(line[index + 1].codepoint) and not isWhiteSpace(line[index + 1].codepoint) do
                index = index + 1
            end
        end

        return newDocPos(from.line, index)
    end

    -- utility functions
    function Document:isStartOfLine(from) return from.index == 0 end
    function Document:isEndOfLine(from) return from.index == #self:at(from.line) end
    function Document:isLastLine(line) return line == #self.lines - 1 end

    function Document:isWordStart(pos, wordOnly)
        local line = self:at(pos.line)
        local isWord, isWhiteSpace = CodePoint.isWord, CodePoint.isWhiteSpace
        if self:isEndOfLine(pos) then
            return false
        elseif self:isStartOfLine(pos) then
            if #line == 0 then
                return false
            end
            return not wordOnly or isWord(line[1].codepoint)
        end

        local glyph1 = line[pos.index].codepoint
        local glyph2 = line[pos.index + 1].codepoint
        if wordOnly then
            return not isWord(glyph1) and isWord(glyph2)
        elseif isWord(glyph2) then
            return not isWord(glyph1)
        elseif isWhiteSpace(glyph2) then
            return not isWhiteSpace(glyph1)
        end
        return isWord(glyph1) or isWhiteSpace(glyph1)
    end

    function Document:isWordEnd(pos, wordOnly)
        local line = self:at(pos.line)
        local isWord, isWhiteSpace = CodePoint.isWord, CodePoint.isWhiteSpace
        if self:isStartOfLine(pos) then
            return false
        elseif self:isEndOfLine(pos) then
            if #line == 0 then
                return false
            end
            return not wordOnly or isWord(line[#line].codepoint)
        end

        local glyph1 = line[pos.index].codepoint
        local glyph2 = line[pos.index + 1].codepoint
        if wordOnly then
            return isWord(glyph1) and not isWord(glyph2)
        elseif isWord(glyph1) then
            return not isWord(glyph2)
        elseif isWhiteSpace(glyph1) then
            return not isWhiteSpace(glyph2)
        end
        return isWord(glyph2) or isWhiteSpace(glyph2)
    end

    function Document:isWholeWord(start, e, wordOnly)
        if e <= start or start.line ~= e.line then
            return false
        end
        return self:isWordStart(start, wordOnly) and self:isWordEnd(e, wordOnly)
    end

    function Document:getWholeWord(pos, wordOnly)
        if wordOnly and not self:isStartOfLine(pos) and not self:isEndOfLine(pos) and not CodePoint.isWord(self:at(pos.line)[pos.index + 1].codepoint) then
            return newDocSelection(pos, pos)
        elseif self:isWordStart(pos, wordOnly) then
            return newDocSelection(pos, self:findWordEnd(pos, wordOnly))
        elseif self:isWordEnd(pos, wordOnly) then
            return newDocSelection(self:findWordStart(pos, wordOnly), pos)
        end
        return newDocSelection(self:findWordStart(pos, wordOnly), self:findWordEnd(pos, wordOnly))
    end

    function Document:findPreviousNonWhiteSpace(from, includeEndOfLine)
        if includeEndOfLine == nil then includeEndOfLine = true end
        from = newDocPos(from.line, from.index)
        local done = false
        while not done do
            local line = self:at(from.line)
            local index = from.index
            while not done and index > 0 do
                index = index - 1
                if not CodePoint.isWhiteSpace(line[index + 1].codepoint) then
                    from.index = index
                    done = true
                end
            end
            if not done then
                if from.line == 0 or not includeEndOfLine then
                    from.index = 0
                    done = true
                else
                    from = self:getLeftBeforeHiddenLines(from)
                end
            end
        end
        return from
    end

    function Document:findNextNonWhiteSpace(from, includeEndOfLine)
        if includeEndOfLine == nil then includeEndOfLine = true end
        from = newDocPos(from.line, from.index)
        local done = false
        while not done do
            local line = self:at(from.line)
            local index = from.index
            while not done and index < #line do
                if CodePoint.isWhiteSpace(line[index + 1].codepoint) then
                    index = index + 1
                else
                    from.index = index
                    done = true
                end
            end
            if not done then
                -- [Port] upstream compares with size(); last line check avoids looping at the bottom
                if from.line >= #self.lines - 1 or not includeEndOfLine then
                    from.index = #line
                    done = true
                else
                    from = self:getRightAfterHiddenLines(from)
                end
            end
        end
        return from
    end

    function Document:normalizePos(pos)
        local line = math.max(0, pos.line)
        if line >= #self.lines then
            return self:getBottom()
        elseif pos.index > #self:at(line) then
            return self:getEndOfLine(newDocPos(line, 0))
        end
        return newDocPos(line, math.max(0, pos.index))
    end

    function Document:normalizeLine(line)
        if line >= #self.lines then return #self.lines - 1 end
        return line
    end

    TextEditor.Document = Document

    --
    -- Cursor: a single cursor
    --

    local Cursor = {}
    Cursor.__index = Cursor

    function Cursor.new(s, e)
        return setmetatable({ start = s, ["end"] = e or s, main = false, current = true, updated = true, preferredColumn = 0 }, Cursor)
    end

    function Cursor:copy()
        local c = Cursor.new(self.start, self["end"])
        c.main, c.current, c.updated, c.preferredColumn = self.main, self.current, self.updated, self.preferredColumn
        return c
    end

    -- update the cursor
    -- [Port] overloads: update(pos), update(s, e), update(pos, keep:boolean)
    function Cursor:update(a, b)
        if b == nil then
            self["end"] = a
        elseif type(b) == "boolean" then
            if b then
                self["end"] = a
            else
                self.start = a
                self["end"] = a
            end
        else
            self.start = a
            self["end"] = b
        end
        self.updated = true
    end

    -- grow the cursor either to the left or the right
    function Cursor:grow(position)
        if position < self:getSelectionStart() then
            if self["end"] > self.start then
                self.start, self["end"] = self["end"], self.start
            end
            self["end"] = position
            self.updated = true
        elseif position > self:getSelectionEnd() then
            if self["end"] < self.start then
                self.start, self["end"] = self["end"], self.start
            end
            self["end"] = position
            self.updated = true
        end
    end

    local function adjustCoordinateForInsert(position, insertStart, insertEnd)
        local line, index = position.line, position.index
        if line == insertStart.line then
            index = index + insertEnd.index - insertStart.index
        end
        line = line + insertEnd.line - insertStart.line
        return newDocPos(line, index)
    end

    local function adjustCoordinateForDelete(position, deleteStart, deleteEnd)
        local line, index = position.line, position.index
        if deleteStart.line == deleteEnd.line then
            if line == deleteEnd.line then
                index = index - (deleteEnd.index - deleteStart.index)
            end
        else
            line = line - (deleteEnd.line - deleteStart.line)
            if line == deleteEnd.line then
                index = index - deleteEnd.index
            end
        end
        return newDocPos(line, index)
    end

    -- adjust cursor for insert/delete operations
    -- (these functions assume that insert or delete points are before the cursor)
    function Cursor:adjustForInsert(insertStart, insertEnd)
        self.start = adjustCoordinateForInsert(self.start, insertStart, insertEnd)
        self["end"] = adjustCoordinateForInsert(self["end"], insertStart, insertEnd)
    end

    function Cursor:adjustForDelete(deleteStart, deleteEnd)
        self.start = adjustCoordinateForDelete(self.start, deleteStart, deleteEnd)
        self["end"] = adjustCoordinateForDelete(self["end"], deleteStart, deleteEnd)
    end

    -- access cursor properties
    function Cursor:getInteractiveStart() return self.start end
    function Cursor:getInteractiveEnd() return self["end"] end
    function Cursor:getSelectionStart()
        if self.start < self["end"] then return self.start end
        return self["end"]
    end
    function Cursor:getSelectionEnd()
        if self.start > self["end"] then return self.start end
        return self["end"]
    end
    function Cursor:hasSelection() return self.start ~= self["end"] end
    function Cursor:resetToStart() local p = self:getSelectionStart(); self:update(p, p) end
    function Cursor:resetToEnd() local p = self:getSelectionEnd(); self:update(p, p) end

    TextEditor.Cursor = Cursor

    --
    -- Cursors: overlay to track the current list of cursors
    -- main/current are 0-based indices into list
    --

    local Cursors = {}
    Cursors.__index = Cursors

    function Cursors.new()
        local self = setmetatable({ list = {}, main = 0, current = 0 }, Cursors)
        self:clearAll()
        return self
    end

    function Cursors:copy()
        local c = setmetatable({ list = {}, main = self.main, current = self.current }, Cursors)
        for i, cursor in ipairs(self.list) do
            c.list[i] = cursor:copy()
        end
        return c
    end

    function Cursors:size() return #self.list end
    function Cursors:at(i) return self.list[i + 1] end

    -- reset the cursors
    function Cursors:reset()
        table.clear(self.list)
        self.main = 0
        self.current = 0
    end

    -- erase all cursors and specify a new one
    function Cursors:setCursor(s, e)
        self:reset()
        local c = Cursor.new(s, e or s)
        c.main = true
        c.current = true
        self.list[1] = c
    end

    -- add a cursor to the list
    function Cursors:addCursor(s, e)
        self:at(self.current).current = false
        local c = Cursor.new(s, e or s)
        c.current = true
        self.list[#self.list + 1] = c
        self.current = #self.list - 1
    end

    function Cursors:updateCurrentCursor(a, b) self:at(self.current):update(a, b) end
    function Cursors:growCurrentCursor(position) self:at(self.current):grow(position) end

    -- check cursor status
    function Cursors:hasMultiple() return #self.list > 1 end
    function Cursors:anyHasSelection()
        for _, cursor in ipairs(self.list) do
            if cursor:hasSelection() then return true end
        end
        return false
    end
    function Cursors:allHaveSelection()
        for _, cursor in ipairs(self.list) do
            if not cursor:hasSelection() then return false end
        end
        return true
    end
    function Cursors:cursorHasSelection(cursor)
        if cursor < #self.list then return self:at(cursor):hasSelection() end
        return false
    end
    function Cursors:mainCursorHasSelection() return self:at(self.main):hasSelection() end
    function Cursors:currentCursorHasSelection() return self:at(self.current):hasSelection() end
    function Cursors:mainHasUpdate() return self:at(self.main).updated end
    function Cursors:anyHasUpdate()
        for _, cursor in ipairs(self.list) do
            if cursor.updated then return true end
        end
        return false
    end

    -- clear the selections and create the default cursor
    function Cursors:clearAll()
        self:setCursor(newDocPos(0, 0))
    end

    -- clear all additional cursors
    function Cursors:clearAdditional(reset)
        local kept = {}
        for _, cursor in ipairs(self.list) do
            if cursor.main then kept[#kept + 1] = cursor end
        end
        self.list = kept
        self.main = 0
        self.current = 0
        self.list[1].current = true
        if reset then
            self.list[1]:resetToEnd()
        end
    end

    -- clear all updated flags
    function Cursors:clearUpdated()
        for _, cursor in ipairs(self.list) do
            cursor.updated = false
        end
    end

    function Cursors:getMain() return self:at(self.main) end
    function Cursors:getMainIndex() return self.main end
    function Cursors:getCurrent() return self:at(self.current) end
    function Cursors:getCurrentIndex() return self.current end

    -- update cursors (sort and merge overlapping cursors)
    -- [Port] ensureNotHidden skipped (no folding yet)
    function Cursors:update(document)
        if not self:anyHasUpdate() then
            return
        end

        -- reset update flags
        self:clearUpdated()

        -- only sort and potential merge when we have multiple cursors
        if not self:hasMultiple() then
            return
        end

        local list = self.list
        table.sort(list, function(a, b) return a:getSelectionStart() < b:getSelectionStart() end)

        -- merge cursors (walk backwards: cursor = list[i], previous = list[i - 1])
        local i = #list
        while i > 1 do
            local cursor = list[i]
            local previous = list[i - 1]
            if previous:getSelectionEnd() >= cursor:getSelectionEnd() then
                -- handle case where one cursor completely contains another cursor
                if cursor.main then previous.main = true end
                if cursor.current then previous.current = true end
                table.remove(list, i)
                i = i - 1
            elseif previous:getSelectionEnd() > cursor:getSelectionStart() then
                if cursor:getInteractiveEnd() < cursor:getInteractiveStart() then
                    previous:update(cursor:getSelectionEnd(), previous:getSelectionStart())
                else
                    previous:update(previous:getSelectionStart(), cursor:getSelectionEnd())
                end
                if cursor.main then previous.main = true end
                if cursor.current then previous.current = true end
                table.remove(list, i)
                i = i - 1
            else
                i = i - 1
            end
        end

        -- find main and current cursor
        self.main = 0
        self.current = 0
        for c = 0, #list - 1 do
            if list[c + 1].main then
                self.main = c
            elseif list[c + 1].current then
                self.current = c
            end
        end
    end

    -- adjust cursors for insert/delete operations
    -- [Port] `start` is a 0-based cursor index instead of an iterator
    function Cursors:adjustForInsert(start, insertStart, insertEnd, includeCurrent)
        local first = start + 1
        if includeCurrent then first = start end
        for c = first, #self.list - 1 do
            self.list[c + 1]:adjustForInsert(insertStart, insertEnd)
        end
    end

    function Cursors:adjustForDelete(start, deleteStart, deleteEnd, includeCurrent)
        local first = start + 1
        if includeCurrent then first = start end
        for c = first, #self.list - 1 do
            self.list[c + 1]:adjustForDelete(deleteStart, deleteEnd)
        end
    end

    TextEditor.Cursors = Cursors

    --
    -- Transaction: a collection of actions for a complete transaction
    -- an action is { type = "insertText"|"deleteText", start = DocPos, ["end"] = DocPos, text = string }
    --

    local Transaction = {}
    Transaction.__index = Transaction

    function Transaction.new()
        return setmetatable({ actions = {}, before = nil, after = nil }, Transaction)
    end
    function Transaction:size() return #self.actions end
    function Transaction:setBeforeState(cursors) self.before = cursors:copy() end
    function Transaction:getBeforeState() return self.before end
    function Transaction:setAfterState(cursors) self.after = cursors:copy() end
    function Transaction:getAfterState() return self.after end
    function Transaction:addInsert(s, e, text)
        self.actions[#self.actions + 1] = { type = "insertText", start = s, ["end"] = e, text = text }
    end
    function Transaction:addDelete(s, e, text)
        self.actions[#self.actions + 1] = { type = "deleteText", start = s, ["end"] = e, text = text }
    end

    --
    -- Transactions: overlay for managing the transaction list to support do/undo/redo
    -- undoIndex is a count (0 = nothing to undo), as upstream
    --

    local Transactions = {}
    Transactions.__index = Transactions

    function Transactions.new()
        return setmetatable({ list = {}, undoIndex = 0, version = 0, callback = nil }, Transactions)
    end

    local function makeChanges(transaction, invert)
        local changes = {}
        for _, action in ipairs(transaction.actions) do
            local insert = action.type == "insertText"
            if invert then insert = not insert end
            changes[#changes + 1] = { insert = insert, start = action.start, ["end"] = action["end"], text = action.text }
        end
        return changes
    end

    function Transactions:reset()
        table.clear(self.list)
        self.undoIndex = 0
        self.version = 0
    end

    -- add a transaction to the list and make it undoable
    function Transactions:add(transaction)
        for i = #self.list, self.undoIndex + 1, -1 do
            self.list[i] = nil
        end
        self.list[#self.list + 1] = transaction
        self.undoIndex = self.undoIndex + 1
        self.version = self.version + 1
        if self.callback then
            self.callback(makeChanges(transaction, false))
        end
    end

    -- undo the last transaction
    function Transactions:undo(config, document, editor)
        local transaction = self.list[self.undoIndex]
        self.undoIndex = self.undoIndex - 1
        local actions = transaction.actions
        for i = #actions, 1, -1 do
            local action = actions[i]
            if action.type == "insertText" then
                document:deleteText(config, action.start, action["end"])
            else
                document:insertText(config, action.start, action.text)
            end
        end
        -- [Port] cursors live on the editor; it is replaced by a copy of the saved state
        editor.cursors = transaction:getBeforeState():copy()
        self.version = self.version + 1
        if self.callback then
            self.callback(makeChanges(transaction, true))
        end
    end

    -- redo the last undone transaction
    function Transactions:redo(config, document, editor)
        self.undoIndex = self.undoIndex + 1
        local transaction = self.list[self.undoIndex]
        for _, action in ipairs(transaction.actions) do
            if action.type == "insertText" then
                document:insertText(config, action.start, action.text)
            else
                document:deleteText(config, action.start, action["end"])
            end
        end
        editor.cursors = transaction:getAfterState():copy()
        self.version = self.version + 1
        if self.callback then
            self.callback(makeChanges(transaction, false))
        end
    end

    function Transactions:canUndo() return self.undoIndex > 0 end
    function Transactions:canRedo() return self.undoIndex < #self.list end
    function Transactions:getUndoIndex() return self.undoIndex end
    function Transactions:getVersion() return self.version end

    TextEditor.Transactions = Transactions


    --
    -- Color palettes
    --

    local IM_COL32 = G.IM_COL32

    local darkPalette = {
        IM_COL32(224, 224, 224, 255), -- text
        IM_COL32(197, 134, 192, 255), -- keyword
        IM_COL32( 90, 179, 155, 255), -- declaration
        IM_COL32(181, 206, 168, 255), -- number
        IM_COL32(206, 145, 120, 255), -- string
        IM_COL32(255, 255, 153, 255), -- punctuation
        IM_COL32( 64, 192, 128, 255), -- preprocessor
        IM_COL32(156, 220, 254, 255), -- identifier
        IM_COL32( 79, 193, 255, 255), -- known identifier
        IM_COL32(106, 153,  85, 255), -- comment
        IM_COL32( 30,  30,  30, 255), -- background
        IM_COL32(224, 224, 224, 255), -- cursor
        IM_COL32( 32,  96, 160, 255), -- selection
        IM_COL32( 80,  80,  80, 255), -- whitespace
        IM_COL32( 70,  70,  70, 255), -- matchingBracketBackground
        IM_COL32(140, 140, 140, 255), -- matchingBracketActive
        IM_COL32(246, 222,  36, 255), -- matchingBracketLevel1
        IM_COL32( 66, 120, 198, 255), -- matchingBracketLevel2
        IM_COL32(213,  96, 213, 255), -- matchingBracketLevel3
        IM_COL32(198,   8,  32, 255), -- matchingBracketError
        IM_COL32(128, 128, 144, 255), -- line number
        IM_COL32(224, 224, 240, 255), -- current line number
        IM_COL32(255, 255, 255,   8), -- current line highlight
        IM_COL32(255, 255, 255,  16), -- current line highlight border
    }

    local lightPalette = {
        IM_COL32( 64,  64,  64, 255), -- text
        IM_COL32(170,   0, 220, 255), -- keyword
        IM_COL32( 65,   0, 255, 255), -- declaration
        IM_COL32( 40, 140,  90, 255), -- number
        IM_COL32(160,  32,  32, 255), -- string
        IM_COL32(  0,   0,   0, 255), -- punctuation
        IM_COL32( 96,  96,  64, 255), -- preprocessor
        IM_COL32( 64,  64,  64, 255), -- identifier
        IM_COL32( 16,  96,  96, 255), -- known identifier
        IM_COL32( 35, 135,   5, 255), -- comment
        IM_COL32(255, 255, 255, 255), -- background
        IM_COL32(  0,   0,   0, 255), -- cursor
        IM_COL32(  0,   0,  96,  64), -- selection
        IM_COL32(144, 144, 144, 144), -- whitespace
        IM_COL32(180, 180, 180, 144), -- matchingBracketBackground
        IM_COL32( 72,  72,  72, 255), -- matchingBracketActive
        IM_COL32( 70,   0, 250, 255), -- matchingBracketLevel1
        IM_COL32( 80, 160,  70, 255), -- matchingBracketLevel2
        IM_COL32(120,  60,  25, 255), -- matchingBracketLevel3
        IM_COL32(198,   8,  32, 255), -- matchingBracketError
        IM_COL32(  0,  80,  80, 255), -- line number
        IM_COL32(  0,   0,   0, 255), -- current line number
        IM_COL32(  0,   0,   0,   8), -- current line highlight
        IM_COL32(  0,   0,   0,  16), -- current line highlight border
    }

    -- [Port] palettes are returned as copies so callers can't mutate the built-in ones
    function TextEditor.GetDarkPalette() return table.clone(darkPalette) end
    function TextEditor.GetLightPalette() return table.clone(lightPalette) end

    local defaultPalette = table.clone(darkPalette)
    function TextEditor.SetDefaultPalette(value) defaultPalette = table.clone(value) end
    function TextEditor.GetDefaultPalette() return defaultPalette end

    --
    -- Language support
    --
    -- [Port] a Language is a plain table with upstream's fields:
    --   name, caseSensitive, preprocess (codepoint or nil), singleLineComment, singleLineCommentAlt,
    --   commentStart, commentEnd, commentLevelStart, commentLevelEnd, hasSingleQuotedStrings,
    --   hasDoubleQuotedStrings, otherStringStart, otherStringEnd, otherStringAltStart, otherStringAltEnd,
    --   stringEscape (codepoint or nil), stringLevelStart, stringLevelEnd, indentationForBlocks,
    --   keywords/declarations/identifiers (sets: { [word] = true }), isPunctuation(codepoint),
    --   getIdentifier, getNumber, customTokenizer.
    -- [Port] Iterator replacement: tokenizer functions receive (text, i) where `text` is the line encoded as one
    --   byte per glyph (codepoints >= 128 become "\128") and `i` is the 1-based glyph index of the token start.
    --   They return the index after the token (returning `i` means no token was found). Level functions return
    --   (end, level); customTokenizer returns (end, color). Delimiter strings must be ASCII.
    --

    local Language = {}
    TextEditor.Language = Language
    TextEditor.LanguageDefinition = Language -- [Port] classic API alias

    local function makeSet(list)
        local set = {}
        for _, word in ipairs(list) do
            set[word] = true
        end
        return set
    end

    local function makePunctuation(chars)
        local set = {}
        for i = 1, #chars do
            set[string.byte(chars, i)] = true
        end
        return function(codepoint) return set[codepoint] == true end
    end

    -- [Port] Luau patterns replace upstream's re2c generated scanners; the first (longest-first) match wins
    local function patternScanner(patterns)
        return function(text, i)
            for _, pattern in ipairs(patterns) do
                local _, e = string.find(text, pattern, i)
                if e then
                    return e + 1
                end
            end
            return i
        end
    end

    -- [Port] isXidStart/isXidContinue: ASCII rules, every non-ASCII glyph is accepted
    local function getCStyleIdentifier(text, i)
        local _, e = string.find(text, "^[%a_\128][%w_\128]*", i)
        if e then return e + 1 end
        return i
    end

    local getCStyleNumber = patternScanner({
        "^0[xX]%x+[uUlL]*",
        "^0[bB][01]+[uUlL]*",
        "^%d+%.?%d*[eE][%+%-]?%d+[fFlL]?",
        "^%.%d+[eE][%+%-]?%d+[fFlL]?",
        "^%d+%.%d*[fFlL]?",
        "^%.%d+[fFlL]?",
        "^%d+[uUlL]*",
    })

    local getLuaStyleNumber = patternScanner({
        "^0[xX]%x*%.?%x*[pP][%+%-]?%d+",
        "^0[xX]%x+%.?%x*",
        "^0[xX]%.%x+",
        "^%d+%.?%d*[eE][%+%-]?%d+",
        "^%.%d+[eE][%+%-]?%d+",
        "^%d+%.?%d*",
        "^%.%d+",
    })

    local isCStylePunctuation = makePunctuation("!%&()*+,-./:;<=>?[]^{|}~")
    -- []{}!%#^&*()-+=~|<>?:/;,.
    local isLuaStylePunctuation = makePunctuation("[]{}!%#^&*()-+=~|<>?:/;,.")

    local function luaCommentLevelStart(text, i)
        local _, e, eq = string.find(text, "^%-%-%[(=*)%[", i)
        if e then return e + 1, #eq end
        return i, 0
    end

    local function luaCommentLevelEnd(text, i)
        local _, e, eq = string.find(text, "^%](=*)%]", i)
        if e then return e + 1, #eq end
        return i, 0
    end

    local function luaStringLevelStart(text, i)
        local _, e, eq = string.find(text, "^%[(=*)%[", i)
        if e then return e + 1, #eq end
        return i, 0
    end

    local luaStringLevelEnd = luaCommentLevelEnd

    local cLanguage, cppLanguage, luaLanguage

    function Language.C()
        if not cLanguage then
            cLanguage = {
                name = "C",
                caseSensitive = true,
                preprocess = string.byte("#"),
                singleLineComment = "//",
                commentStart = "/*",
                commentEnd = "*/",
                hasSingleQuotedStrings = true,
                hasDoubleQuotedStrings = true,
                stringEscape = string.byte("\\"),
                keywords = makeSet({
                    "break", "case", "continue", "default", "do", "else", "for", "goto", "if", "return", "sizeof",
                    "switch", "while", "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic",
                    "_Imaginary", "_Noreturn", "_Static_assert", "_Thread_local",
                }),
                declarations = makeSet({
                    "auto", "char", "const", "double", "enum", "extern", "float", "inline", "int", "long", "register",
                    "restrict", "short", "signed", "static", "struct", "typedef", "union", "unsigned", "void", "volatile",
                }),
                identifiers = {},
                isPunctuation = isCStylePunctuation,
                getIdentifier = getCStyleIdentifier,
                getNumber = getCStyleNumber,
            }
        end
        return cLanguage
    end

    function Language.Cpp()
        if not cppLanguage then
            cppLanguage = {
                name = "C++",
                caseSensitive = true,
                preprocess = string.byte("#"),
                singleLineComment = "//",
                commentStart = "/*",
                commentEnd = "*/",
                hasSingleQuotedStrings = true,
                hasDoubleQuotedStrings = true,
                stringEscape = string.byte("\\"),
                keywords = makeSet({
                    "alignas", "alignof", "and", "and_eq", "asm", "atomic_cancel", "atomic_commit", "atomic_noexcept",
                    "bitand", "bitor", "break", "case", "catch", "compl", "const_cast", "continue", "default", "delete",
                    "do", "dynamic_cast", "else", "explicit", "export", "extern", "false", "for", "goto", "if", "import",
                    "new", "noexcept", "not", "not_eq", "nullptr", "operator", "or", "or_eq", "reinterpret_cast", "requires",
                    "return", "sizeof", "static_assert", "static_cast", "switch", "synchronized", "this", "thread_local",
                    "throw", "true", "try", "while", "xor", "xor_eq",
                }),
                declarations = makeSet({
                    "auto", "bool", "char", "char8_t", "char16_t", "char32_t", "class", "concept", "const", "constexpr", "decltype",
                    "double", "explicit", "export", "extern", "enum", "extern", "float", "friend", "inline", "int", "long",
                    "module", "mutable", "namespace", "private", "protected", "public", "register", "restrict", "short",
                    "signed", "static", "struct", "template", "typedef", "typeid", "typename", "union", "using", "unsigned",
                    "virtual", "void", "volatile", "wchar_t",
                }),
                identifiers = {},
                isPunctuation = isCStylePunctuation,
                getIdentifier = getCStyleIdentifier,
                getNumber = getCStyleNumber,
            }
        end
        return cppLanguage
    end

    function Language.Lua()
        if not luaLanguage then
            luaLanguage = {
                name = "Lua",
                caseSensitive = true,
                singleLineComment = "--",
                commentLevelStart = luaCommentLevelStart,
                commentLevelEnd = luaCommentLevelEnd,
                hasSingleQuotedStrings = true,
                hasDoubleQuotedStrings = true,
                stringLevelStart = luaStringLevelStart,
                stringLevelEnd = luaStringLevelEnd,
                stringEscape = string.byte("\\"),
                keywords = makeSet({
                    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil",
                    "not", "or", "repeat", "return", "then", "true", "until", "while",
                }),
                declarations = {},
                identifiers = makeSet({
                    "_G", "_VERSION", "abs", "acos", "asin", "assert", "atan", "atan2", "byte", "ceil", "char", "clock", "close",
                    "collectgarbage", "concat", "coroutine", "cos", "cosh", "cpath", "create", "date", "debug", "deg", "difftime",
                    "dofile", "dump", "error", "execute", "exit", "exp", "find", "floor", "flush", "fmod", "format", "frexp", "getenv",
                    "getfenv", "gethook", "getinfo", "getlocal", "getmetatable", "getregistry", "getupvalue", "gmatch", "gsub", "huge",
                    "input", "insert", "io", "ipairs", "ldexp", "len", "lines", "load", "loaded", "loaders", "loadfile", "loadlib",
                    "loadstring", "log", "log10", "lower", "match", "math", "max", "maxn", "min", "modf", "module", "next", "open",
                    "os", "output", "package", "pairs", "path", "pcall", "pi", "popen", "pow", "preload", "print", "rad", "random",
                    "randomseed", "rawequal", "rawget", "rawset", "read", "remove", "rename", "rep", "require", "resume", "reverse",
                    "running", "seeall", "seek", "select", "setfenv", "sethook", "setlocal", "setlocale", "setmetatable", "setupvalue",
                    "setvbuf", "sin", "sinh", "sort", "sqrt", "status", "stderr", "stdin", "stdout", "string", "sub", "table", "tan",
                    "tanh", "time", "tmpfile", "tmpname", "tonumber", "tostring", "traceback", "type", "unpack", "upper", "wrap",
                    "write", "xpcall", "yield",
                }),
                isPunctuation = isLuaStylePunctuation,
                getIdentifier = getCStyleIdentifier,
                getNumber = getLuaStyleNumber,
            }
        end
        return luaLanguage
    end

    -- [Port] TODO: Cs, AngelScript, Python, Glsl, Hlsl, Json, Markdown, Sql

    --
    -- Colorizer: overlay to colorize text (based on language tokenizing)
    --

    local Colorizer = {}
    Colorizer.__index = Colorizer

    function Colorizer.new()
        return setmetatable({ language = nil }, Colorizer)
    end

    -- set color for specified range of glyphs (1-based, end exclusive)
    local function setColor(line, s, e, color)
        for i = s, e - 1 do
            line[i].color = color
        end
    end

    -- [Port] encode a line as one byte per glyph so Luau patterns can scan it (see Language notes)
    local function lineToText(line)
        local bytes = table.create(#line)
        for i, glyph in ipairs(line) do
            local cp = glyph.codepoint
            if cp >= 128 then cp = 128 end
            bytes[i] = string.char(cp)
        end
        return table.concat(bytes)
    end

    -- see if text at glyph i matches provided string
    local function matches(text, i, str)
        return string.sub(text, i, i + #str - 1) == str
    end

    -- update color in a single line
    function Colorizer:updateLine(line)
        -- initialize local variables
        local language = self.language
        local state = line.state
        local nonWhiteSpace = false
        local text = lineToText(line)
        local glyph = 1
        local e = #line + 1
        local isWhiteSpace = CodePoint.isWhiteSpace

        -- process all glyphs on this line
        while glyph < e do
            -- start parsing glyphs
            local start = glyph
            local codepoint = line[glyph].codepoint

            if state == LineState.inText then
                -- special handling for preprocessor lines
                if not nonWhiteSpace and language.preprocess and codepoint ~= language.preprocess and not isWhiteSpace(codepoint) then
                    nonWhiteSpace = true
                end

                -- are we starting a multilevel, multiline comment
                if language.commentLevelStart then
                    local tokenEnd, level = language.commentLevelStart(text, glyph)
                    if tokenEnd ~= glyph then
                        state = commentLevelToLineState(math.min(level, maxCommentLevel))
                        setColor(line, glyph, tokenEnd, Color.comment)
                        glyph = tokenEnd
                    end
                end

                -- are we starting a multilevel, multiline string
                if glyph == start and language.stringLevelStart then
                    local tokenEnd, level = language.stringLevelStart(text, glyph)
                    if tokenEnd ~= glyph then
                        state = stringLevelToLineState(math.min(level, maxStringLevel))
                        setColor(line, glyph, tokenEnd, Color.string)
                        glyph = tokenEnd
                    end
                end

                if glyph == start then
                    local commentStart = language.commentStart
                    local singleLineComment = language.singleLineComment
                    local singleLineCommentAlt = language.singleLineCommentAlt
                    local otherStringStart = language.otherStringStart
                    local otherStringAltStart = language.otherStringAltStart

                    -- mark whitespace characters
                    if isWhiteSpace(codepoint) then
                        line[glyph].color = Color.whitespace
                        glyph = glyph + 1

                    -- are we starting a multiline comment
                    elseif commentStart and #commentStart > 0 and matches(text, glyph, commentStart) then
                        state = LineState.inComment
                        setColor(line, glyph, glyph + #commentStart, Color.comment)
                        glyph = glyph + #commentStart

                    -- handle single line comments
                    elseif singleLineComment and #singleLineComment > 0 and matches(text, glyph, singleLineComment) then
                        setColor(line, glyph, e, Color.comment)
                        glyph = e

                    elseif singleLineCommentAlt and #singleLineCommentAlt > 0 and matches(text, glyph, singleLineCommentAlt) then
                        setColor(line, glyph, e, Color.comment)
                        glyph = e

                    -- are we starting a special string
                    elseif otherStringStart and #otherStringStart > 0 and matches(text, glyph, otherStringStart) then
                        state = LineState.inOtherString
                        setColor(line, glyph, glyph + #otherStringStart, Color.string)
                        glyph = glyph + #otherStringStart

                    elseif otherStringAltStart and #otherStringAltStart > 0 and matches(text, glyph, otherStringAltStart) then
                        state = LineState.inOtherStringAlt
                        setColor(line, glyph, glyph + #otherStringAltStart, Color.string)
                        glyph = glyph + #otherStringAltStart

                    -- are we starting a single quoted string
                    elseif language.hasSingleQuotedStrings and codepoint == 39 then
                        state = LineState.inSingleQuotedString
                        line[glyph].color = Color.string
                        glyph = glyph + 1

                    -- are we starting a double quoted string
                    elseif language.hasDoubleQuotedStrings and codepoint == 34 then
                        state = LineState.inDoubleQuotedString
                        line[glyph].color = Color.string
                        glyph = glyph + 1

                    -- is this a preprocessor line
                    elseif language.preprocess and not nonWhiteSpace and codepoint == language.preprocess then
                        setColor(line, 1, e, Color.preprocessor)
                        glyph = e
                    end
                end

                if glyph == start then
                    -- nothing worked so far so it's time to do some tokenizing
                    local tokenEnd, color = glyph, nil
                    if language.customTokenizer then
                        tokenEnd, color = language.customTokenizer(text, glyph)
                    end

                    -- handle custom tokenizer (if we have one)
                    if tokenEnd ~= glyph then
                        setColor(line, glyph, tokenEnd, color)
                        glyph = tokenEnd
                    else
                        if language.getIdentifier then
                            tokenEnd = language.getIdentifier(text, glyph)
                        end

                        -- do we have an identifier
                        if tokenEnd ~= glyph then
                            -- determine identifier text and color
                            local parts = {}
                            for i = glyph, tokenEnd - 1 do
                                parts[#parts + 1] = utf8.char(line[i].codepoint)
                            end
                            local identifier = table.concat(parts)
                            if language.caseSensitive == false then
                                identifier = string.lower(identifier)
                            end

                            color = Color.identifier
                            if language.keywords and language.keywords[identifier] then
                                color = Color.keyword
                            elseif language.declarations and language.declarations[identifier] then
                                color = Color.declaration
                            elseif language.identifiers and language.identifiers[identifier] then
                                color = Color.knownIdentifier
                            end

                            -- colorize identifier and move on
                            setColor(line, glyph, tokenEnd, color)
                            glyph = tokenEnd
                        else
                            if language.getNumber then
                                tokenEnd = language.getNumber(text, glyph)
                            end

                            -- do we have a number
                            if tokenEnd ~= glyph then
                                setColor(line, glyph, tokenEnd, Color.number)
                                glyph = tokenEnd

                            -- is this punctuation
                            elseif language.isPunctuation and language.isPunctuation(codepoint) then
                                line[glyph].color = Color.punctuation
                                glyph = glyph + 1

                            else
                                -- I guess we don't know what this character is
                                line[glyph].color = Color.text
                                glyph = glyph + 1
                            end
                        end
                    end
                end

            elseif lineStateInComment(state) then
                -- stay in comment state until we see the end sequence
                local commentEnd = language.commentEnd
                if commentEnd and #commentEnd > 0 and matches(text, glyph, commentEnd) then
                    setColor(line, glyph, glyph + #commentEnd, Color.comment)
                    glyph = glyph + #commentEnd
                    state = LineState.inText

                elseif language.commentLevelEnd then
                    local tokenEnd, level = language.commentLevelEnd(text, glyph)
                    if tokenEnd ~= glyph and state == commentLevelToLineState(math.min(level, maxCommentLevel)) then
                        setColor(line, glyph, tokenEnd, Color.comment)
                        glyph = tokenEnd
                        state = LineState.inText
                    end
                end

                -- [Port] bounds guard: a level end token at end of line would otherwise index past it
                if lineStateInComment(state) and glyph < e then
                    line[glyph].color = Color.comment
                    glyph = glyph + 1
                end

            elseif lineStateInStringLevel(state) then
                -- stay in string level until matching closing is detected
                local tokenEnd, level = language.stringLevelEnd(text, glyph)
                if tokenEnd ~= glyph and state == stringLevelToLineState(math.min(level, maxStringLevel)) then
                    setColor(line, glyph, tokenEnd, Color.string)
                    glyph = tokenEnd
                    state = LineState.inText
                else
                    line[glyph].color = Color.string
                    glyph = glyph + 1
                end

            else
                -- inOtherString, inOtherStringAlt, inSingleQuotedString or inDoubleQuotedString
                -- stay in string state until we see the end sequence, skip escaped characters
                local endString
                if state == LineState.inOtherString then
                    endString = language.otherStringEnd
                elseif state == LineState.inOtherStringAlt then
                    endString = language.otherStringAltEnd
                elseif state == LineState.inSingleQuotedString then
                    endString = "'"
                else
                    endString = '"'
                end

                if codepoint == language.stringEscape then
                    line[glyph].color = Color.string
                    glyph = glyph + 1
                    if glyph < e then
                        line[glyph].color = Color.string
                        glyph = glyph + 1
                    end

                elseif matches(text, glyph, endString) then
                    setColor(line, glyph, glyph + #endString, Color.string)
                    glyph = glyph + #endString
                    state = LineState.inText

                else
                    line[glyph].color = Color.string
                    glyph = glyph + 1
                end
            end
        end

        return state
    end

    -- update state (if required)
    function Colorizer:update(config, document)
        -- update all lines on configuration change
        local configChanged = self.language ~= config.language
        local lines = document.lines
        local n = #lines

        if configChanged then
            self.language = config.language
            for l = 1, n do
                local line = lines[l]
                if self.language then
                    local state = self:updateLine(line)
                    if l < n then lines[l + 1].state = state end
                else
                    for _, glyph in ipairs(line) do glyph.color = Color.text end
                    line.state = LineState.inText
                end
                line.needsColorizing = false
            end

        -- update changed lines when document is updated
        elseif document.updated then
            for l = 1, n do
                local line = lines[l]
                if line.needsColorizing then
                    if self.language then
                        local state = self:updateLine(line)
                        line.needsColorizing = false
                        local nextLine = lines[l + 1]
                        if nextLine and nextLine.state ~= state then
                            nextLine.state = state
                            nextLine.needsColorizing = true
                        end
                    else
                        for _, glyph in ipairs(line) do glyph.color = Color.text end
                        line.state = LineState.inText
                        line.needsColorizing = false
                    end
                end
            end
        end

        -- return status
        return configChanged
    end

    --
    -- Bracketeer: overlay to manage details about bracketed text
    -- a BracketPair is { startChar, start = DocPos, endChar, ["end"] = DocPos, level, visible }
    --

    local openers = { [40] = 41, [123] = 125, [91] = 93 } -- ( { [
    local closers = { [41] = 40, [125] = 123, [93] = 91 } -- ) } ]

    local function isBracketCandidate(glyph)
        local color = glyph.color
        return color == Color.punctuation or color == Color.matchingBracketLevel1 or color == Color.matchingBracketLevel2
            or color == Color.matchingBracketLevel3 or color == Color.matchingBracketError
    end

    local function bracketIsAfter(pair, location) return pair.start > location end
    local function bracketIsAround(pair, location) return pair.start < location and pair["end"] >= location end

    local Bracketeer = {}
    Bracketeer.__index = Bracketeer

    function Bracketeer.new()
        return setmetatable({ list = {}, showMatchingBrackets = false, language = nil, updated = false }, Bracketeer)
    end

    local bracketColors = { Color.matchingBracketLevel1, Color.matchingBracketLevel2, Color.matchingBracketLevel3 }

    -- [Port] invisible (indentation based) blocks are not generated yet (no language uses indentationForBlocks)
    function Bracketeer:update(config, document)
        -- see if the configuration changed
        local configChanged = self.showMatchingBrackets ~= config.showMatchingBrackets or self.language ~= config.language
        self.showMatchingBrackets = config.showMatchingBrackets
        self.language = config.language

        if configChanged and not self.showMatchingBrackets then
            -- if configuration changed, clear the bracket pair list and reset glyph colors
            table.clear(self.list)
            for _, line in ipairs(document.lines) do
                for _, glyph in ipairs(line) do
                    local color = glyph.color
                    if color == Color.matchingBracketLevel1 or color == Color.matchingBracketLevel2
                        or color == Color.matchingBracketLevel3 or color == Color.matchingBracketError then
                        glyph.color = Color.punctuation
                    end
                end
            end

        elseif self.showMatchingBrackets and (configChanged or document.updated) then
            -- if configuration or document changed, recalculate bracket pair list
            local previous = self.list
            local list = {}
            local levels = {}
            local level = 0

            -- process all the glyphs
            for l, line in ipairs(document.lines) do
                for i, glyph in ipairs(line) do
                    -- handle a "bracket opener" that is not in a comment, string or preprocessor statement
                    if isBracketCandidate(glyph) and openers[glyph.codepoint] then
                        -- start a new level
                        list[#list + 1] = { startChar = glyph.codepoint, start = newDocPos(l - 1, i - 1), endChar = 0, ["end"] = newDocPos(0, 0), level = level, visible = true }
                        levels[#levels + 1] = #list
                        glyph.color = bracketColors[level % 3 + 1]
                        level = level + 1

                    -- handle a "bracket closer" that is not in a comment, string or preprocessor statement
                    elseif isBracketCandidate(glyph) and closers[glyph.codepoint] then
                        if #levels > 0 then
                            local lastBracket = list[table.remove(levels)]
                            level = level - 1

                            if lastBracket.startChar == closers[glyph.codepoint] then
                                -- handle matching bracket
                                glyph.color = bracketColors[level % 3 + 1]
                                lastBracket.endChar = glyph.codepoint
                                lastBracket["end"] = newDocPos(l - 1, i - 1)
                            else
                                -- no matching bracket, mark brackets as errors
                                glyph.color = Color.matchingBracketError
                                document:at(lastBracket.start.line)[lastBracket.start.index + 1].color = Color.matchingBracketError
                                table.remove(list)
                            end

                        -- this is a closer without an opener
                        else
                            glyph.color = Color.matchingBracketError
                        end
                    end
                end
            end

            -- handle levels left open and mark them as errors
            for j = #levels, 1, -1 do
                local s = list[levels[j]].start
                document:at(s.line)[s.index + 1].color = Color.matchingBracketError
                table.remove(list, levels[j])
            end

            self.list = list

            -- see if things have changed
            local changed = #previous ~= #list
            for j = 1, #list do
                if changed then break end
                changed = previous[j].start ~= list[j].start or previous[j]["end"] ~= list[j]["end"]
            end
            self.updated = changed
        end
    end

    -- find relevant brackets (returns a BracketPair or nil)
    function Bracketeer:getEnclosingBrackets(first, last)
        last = last or first
        local brackets = nil
        for _, pair in ipairs(self.list) do
            -- brackets are sorted so no need to go past specified location
            if bracketIsAfter(pair, first) then
                break
            elseif bracketIsAround(pair, first) and bracketIsAround(pair, last) then
                -- this could be what we're looking for
                brackets = pair
            end
        end
        return brackets
    end

    function Bracketeer:getInnerBrackets(first, last)
        local list = self.list
        local outer = self:getEnclosingBrackets(first, last)
        if outer then
            local start = table.find(list, outer)
            for j = start + 1, #list do
                local pair = list[j]
                if pair.level <= outer.level then
                    break
                elseif pair.level == outer.level + 1 and pair.start > first and pair["end"] < last then
                    return pair
                end
            end
        end
        return nil
    end

    function Bracketeer:isUpdated() return self.updated end
    function Bracketeer:resetUpdated() self.updated = false end

    TextEditor.Colorizer = Colorizer
    TextEditor.Bracketeer = Bracketeer

    --
    -- TextEditor
    --

    -- constructor
    function TextEditor.new()
        local self = setmetatable({}, TextEditor)
        self.config = { tabSize = 4, insertSpacesOnTabs = false, readOnly = false, showMatchingBrackets = true, language = nil }
        self.document = Document.new()
        self.cursors = Cursors.new()
        self.transactions = Transactions.new()
        self.colorizer = Colorizer.new()
        self.bracketeer = Bracketeer.new()
        self:SetPalette(defaultPalette)
        return self
    end

    function TextEditor:reset()
        self.document = Document.new()
        -- [Port] a fresh document needs a full recolor/rebracket
        self.colorizer.language = nil
        self.bracketeer.language = nil
        self.transactions:reset()
        self.cursors:clearAll()
        -- [Port] markers, squiggles and scrolling not ported yet
    end

    -- [Port] normalize helpers accept DocPos or any { line, index } table
    function TextEditor:normalizePos(pos) return self.document:normalizePos(pos) end
    function TextEditor:normalizeLine(line) return self.document:normalizeLine(line) end

    -- configuration
    function TextEditor:SetTabSize(value) self.config.tabSize = value end
    function TextEditor:GetTabSize() return self.config.tabSize end
    function TextEditor:SetInsertSpacesOnTabs(value) self.config.insertSpacesOnTabs = value end
    function TextEditor:IsInsertSpacesOnTabs() return self.config.insertSpacesOnTabs end
    function TextEditor:SetReadOnlyEnabled(value) self.config.readOnly = value end
    function TextEditor:IsReadOnlyEnabled() return self.config.readOnly end
    -- [Port] short aliases
    TextEditor.SetReadOnly = TextEditor.SetReadOnlyEnabled
    TextEditor.IsReadOnly = TextEditor.IsReadOnlyEnabled

    function TextEditor:SetShowMatchingBrackets(value) self.config.showMatchingBrackets = value end
    function TextEditor:IsShowingMatchingBrackets() return self.config.showMatchingBrackets end

    -- color palette support
    -- [Port] no style alpha is applied yet (updatePalettes is part of rendering)
    function TextEditor:SetPalette(newPalette) self.paletteBase = table.clone(newPalette) end
    function TextEditor:GetPalette() return self.paletteBase end

    -- language support
    function TextEditor:SetLanguage(language)
        self.config.language = language
        if self.languageChangeCallback then
            self.languageChangeCallback()
        end
    end
    function TextEditor:GetLanguage() return self.config.language end
    function TextEditor:HasLanguage() return self.config.language ~= nil end
    function TextEditor:GetLanguageName()
        if self.config.language == nil then return "None" end
        return self.config.language.name
    end
    function TextEditor:SetLanguageChangeCallback(callback) self.languageChangeCallback = callback end
    -- [Port] classic API alias
    TextEditor.SetLanguageDefinition = TextEditor.SetLanguage

    -- [Port] color of glyph at position (upstream's Document::getColor); runs updateState first
    function TextEditor:GetGlyphColor(pos)
        self:updateState()
        return self.document:getColor(self:normalizePos(pos))
    end

    function TextEditor:SelectToBrackets(includeBrackets)
        if includeBrackets == nil then includeBrackets = true end
        self:selectToBrackets(includeBrackets)
    end

    -- set/get editor text (UTF-8 encoded)
    -- [Port] a table of lines is accepted too (upstream's std::vector overload)
    function TextEditor:SetText(text)
        self:reset()
        if type(text) == "table" then
            text = table.concat(text, "\n")
        end
        self.document:setUtf8Text(self.config, text)
    end
    function TextEditor:GetText() return self.document:getUtf8Text() end

    -- get part of text from editor as UTF-8 encoded strings
    function TextEditor:GetSectionText(s, e)
        if e == nil then s, e = s.start, s["end"] end
        return self.document:getSectionText(self:normalizePos(s), self:normalizePos(e))
    end
    function TextEditor:GetCursorText(cursor)
        if cursor < self.cursors:size() then
            local c = self.cursors:at(cursor)
            return self.document:getSectionText(c:getSelectionStart(), c:getSelectionEnd())
        end
        return ""
    end
    function TextEditor:GetLineText(line)
        if line < self.document:size() then
            return self.document:getLineText(line)
        end
        return ""
    end
    -- [Port] convenience: text of the current cursor's selection
    function TextEditor:GetSelectedText() return self:GetCursorText(self.cursors:getCurrentIndex()) end

    function TextEditor:ReplaceSectionText(s, e, text)
        if text == nil then text = e; s, e = s.start, s["end"] end
        if not self.config.readOnly then
            self:replaceSectionText(self:normalizePos(s), self:normalizePos(e), text)
        end
    end

    function TextEditor:ClearText() self:SetText("") end
    function TextEditor:IsEmpty() return self.document:isEmpty() end
    function TextEditor:GetLineCount() return self.document:size() end

    -- clipboard-free editing operations
    function TextEditor:Undo() if not self.config.readOnly then self:undo() end end
    function TextEditor:Redo() if not self.config.readOnly then self:redo() end end
    function TextEditor:CanUndo() return not self.config.readOnly and self.transactions:canUndo() end
    function TextEditor:CanRedo() return not self.config.readOnly and self.transactions:canRedo() end
    function TextEditor:GetUndoIndex() return self.transactions:getUndoIndex() end

    -- manage cursors and selections
    function TextEditor:SelectAll() self:selectAll() end
    function TextEditor:SelectLine(line) self:selectLine(self:normalizeLine(line)) end
    function TextEditor:SelectLines(s, e)
        if e < self.document:size() and s <= e then self:selectLines(s, e) end
    end
    function TextEditor:SelectRegion(s, e) self:selectRegion(self:normalizePos(s), self:normalizePos(e)) end
    function TextEditor:AnyCursorHasSelection() return self.cursors:anyHasSelection() end
    function TextEditor:AllCursorsHaveSelection() return self.cursors:allHaveSelection() end
    function TextEditor:CursorHasSelection(cursor) return self.cursors:cursorHasSelection(cursor) end
    function TextEditor:MainCursorHasSelection() return self.cursors:mainCursorHasSelection() end
    function TextEditor:CurrentCursorHasSelection() return self.cursors:currentCursorHasSelection() end
    -- [Port] convenience alias
    TextEditor.HasSelection = TextEditor.AnyCursorHasSelection
    function TextEditor:ClearCursors() self.cursors:clearAll() end
    -- [Port] upstream adds cursors via mouse/keyboard only; exposed here for multi-cursor scripting
    function TextEditor:AddCursor(s, e)
        s = self:normalizePos(s)
        if e == nil then e = s else e = self:normalizePos(e) end
        self.cursors:addCursor(s, e)
        self.cursors:update(self.document)
    end

    -- get cursor positions
    function TextEditor:GetNumberOfCursors() return self.cursors:size() end
    function TextEditor:GetCursorPosition(cursor) return self:getCursorPosition(cursor) end
    function TextEditor:GetMainCursorPosition() return self:getCursorPosition(self.cursors:getMainIndex()) end
    function TextEditor:GetCurrentCursorPosition() return self:getCursorPosition(self.cursors:getCurrentIndex()) end
    function TextEditor:GetCursorSelection(cursor) return self:getCursorSelection(cursor) end
    function TextEditor:GetMainCursorSelection() return self:getCursorSelection(self.cursors:getMainIndex()) end
    function TextEditor:GetCurrentCursorSelection() return self:getCursorSelection(self.cursors:getCurrentIndex()) end

    -- specify a new cursor position
    function TextEditor:SetCursor(pos) self:setCursor(self:normalizePos(pos)) end

    -- word boundaries
    function TextEditor:FindWordStart(pos, wholeWord) return self.document:findWordStart(self:normalizePos(pos), wholeWord) end
    function TextEditor:FindWordEnd(pos, wholeWord) return self.document:findWordEnd(self:normalizePos(pos), wholeWord) end

    function TextEditor:ReplaceTextInCurrentCursor(text) if not self.config.readOnly then self:replaceTextInCurrentCursor(text) end end
    function TextEditor:ReplaceTextInAllCursors(text) if not self.config.readOnly then self:replaceTextInAllCursors(text) end end

    -- specify a transaction callback: callback(changes), change = { insert, start, end, text }
    function TextEditor:SetTransactionCallback(callback) self.transactions.callback = callback end
    function TextEditor:ClearTransactionCallback() self.transactions.callback = nil end
    function TextEditor:HasTransactionCallback() return self.transactions.callback ~= nil end

    --
    -- private implementation
    --

    function TextEditor:selectAll()
        self:moveTo(self.document:getTop(), false)
        self:moveTo(self.document:getBottom(), true)
    end

    function TextEditor:selectLine(line)
        self:moveTo(newDocPos(line, 0), false)
        self:moveTo(self:normalizePos(newDocPos(line + 1, 0)), true)
    end

    function TextEditor:selectLines(startLine, endLine)
        self:moveTo(newDocPos(startLine, 0), false)
        self:moveTo(newDocPos(endLine, 0), true)
    end

    function TextEditor:selectRegion(s, e)
        if e < s then s, e = e, s end
        self.cursors:setCursor(s, e)
    end

    -- handle possible changes caused by the API or user interactions
    -- [Port] called by render upstream; until rendering is ported call it (or GetGlyphColor) to update overlays
    function TextEditor:updateState()
        self.colorizer:update(self.config, self.document)
        self.bracketeer:update(self.config, self.document)
        self.cursors:update(self.document)
        local documentChanged = self.document.updated
        self.document.updated = false
        self.bracketeer:resetUpdated()
        return documentChanged
    end

    function TextEditor:selectToBrackets(includeBrackets)
        self:updateState()
        for _, cursor in ipairs(self.cursors.list) do
            local bracket = self.bracketeer:getEnclosingBrackets(cursor:getSelectionStart())
            if bracket then
                if includeBrackets then
                    cursor:update(bracket.start, self.document:getRight(bracket["end"]))
                else
                    cursor:update(self.document:getRight(bracket.start), bracket["end"])
                end
            end
        end
    end

    function TextEditor:moveTo(coordinate, select)
        self.cursors:clearAdditional()
        self.cursors:updateCurrentCursor(coordinate, select and true or false)
    end

    function TextEditor:undo()
        if self.transactions:canUndo() then
            self.transactions:undo(self.config, self.document, self)
        end
    end

    function TextEditor:redo()
        if self.transactions:canRedo() then
            self.transactions:redo(self.config, self.document, self)
        end
    end

    function TextEditor:getCursorPosition(cursor)
        cursor = math.min(cursor or 0, self.cursors:size() - 1)
        return self.cursors:at(cursor):getInteractiveEnd()
    end

    function TextEditor:getCursorSelection(cursor)
        cursor = math.min(cursor or 0, self.cursors:size() - 1)
        local c = self.cursors:at(cursor)
        return newDocSelection(c:getSelectionStart(), c:getSelectionEnd())
    end

    function TextEditor:setCursor(pos)
        self.cursors:setCursor(pos)
    end

    function TextEditor:startTransaction()
        local transaction = Transaction.new()
        transaction:setBeforeState(self.cursors)
        return transaction
    end

    function TextEditor:endTransaction(transaction)
        if transaction:size() > 0 then
            self.cursors:update(self.document)
            transaction:setAfterState(self.cursors)
            self.transactions:add(transaction)
            return true
        end
        return false
    end

    function TextEditor:insertTextIntoAllCursors(transaction, text)
        -- delete any selection content first
        self:deleteTextFromAllCursors(transaction)

        -- insert the text
        local cursors = self.cursors
        for c = 0, cursors:size() - 1 do
            local cursor = cursors:at(c)
            local s = cursor:getSelectionStart()
            local e = self:insertText(transaction, s, text)
            cursor:update(e, false)
            cursors:adjustForInsert(c, s, e)
        end
    end

    function TextEditor:deleteTextFromAllCursors(transaction)
        local cursors = self.cursors
        for c = 0, cursors:size() - 1 do
            local cursor = cursors:at(c)
            if cursor:hasSelection() then
                local s = cursor:getSelectionStart()
                local e = cursor:getSelectionEnd()
                self:deleteText(transaction, s, e)
                cursor:update(s, false)
                cursors:adjustForDelete(c, s, e)
            end
        end
    end

    -- update document, add transaction and return position of end of insert
    -- this function does not change the cursors
    function TextEditor:insertText(transaction, s, text)
        local e = self.document:insertText(self.config, s, text)
        transaction:addInsert(s, e, text)
        return e
    end

    -- update document and add transaction
    -- this function does not change the cursors
    function TextEditor:deleteText(transaction, s, e)
        local text = self.document:getSectionText(s, e)
        self.document:deleteText(self.config, s, e)
        transaction:addDelete(s, e, text)
    end

    function TextEditor:replaceTextInCurrentCursor(text)
        local transaction = self:startTransaction()

        -- first delete old text
        local index = self.cursors:getCurrentIndex()
        local cursor = self.cursors:getCurrent()
        local s = cursor:getSelectionStart()
        local e = cursor:getSelectionEnd()
        self:deleteText(transaction, s, e)
        self.cursors:adjustForDelete(index, s, e)

        -- now insert new text
        local newEnd = self:insertText(transaction, s, text)
        cursor:update(newEnd, false)
        self.cursors:adjustForInsert(index, s, newEnd)

        self:endTransaction(transaction)
    end

    function TextEditor:replaceTextInAllCursors(text)
        local transaction = self:startTransaction()
        self:insertTextIntoAllCursors(transaction, text)
        self:endTransaction(transaction)
    end

    function TextEditor:replaceSectionText(s, e, text)
        local transaction = self:startTransaction()
        self:deleteText(transaction, s, e)
        local newEnd = self:insertText(transaction, s, text)
        self.cursors:clearAdditional()
        self.cursors:getMain():update(newEnd, newEnd)
        self:endTransaction(transaction)
    end

    return TextEditor
end
