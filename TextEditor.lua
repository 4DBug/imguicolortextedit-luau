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
-- text get/set, insert/delete and word boundaries. Rendering, languages/colorizer, bracketeer, folding,
-- typesetting, markers, squiggles and find/replace are not ported yet.
return function(G)
    local ImGui, ImVec2, ImVec4 = G.ImGui, G.ImVec2, G.ImVec4
    local TextEditor = {}
    TextEditor.__index = TextEditor

    -- [Port] subset of upstream's Color enum (only what the data layer needs)
    local Color = { text = 1 }
    TextEditor.Color = Color

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

    function Document:appendLine()
        self.lines[#self.lines + 1] = {}
    end

    function Document:insertLine(offset)
        table.insert(self.lines, offset + 1, {})
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

        self.updated = true

        -- determine end of insert
        return newDocPos(lineNo, index)
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
    -- TextEditor
    --

    -- constructor
    function TextEditor.new()
        local self = setmetatable({}, TextEditor)
        self.config = { tabSize = 4, insertSpacesOnTabs = false, readOnly = false }
        self.document = Document.new()
        self.cursors = Cursors.new()
        self.transactions = Transactions.new()
        return self
    end

    function TextEditor:reset()
        self.document = Document.new()
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
