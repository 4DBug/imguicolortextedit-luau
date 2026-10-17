-- Renders an editor in a window and drives it with mouse/keyboard events through the core's IO queue.
local RS = game:GetService("ReplicatedStorage")
local G = require(RS:WaitForChild("ImGui"))
local TextEditor = require(RS:WaitForChild("TextEditor"))(G)
local ImGui, ImVec2, Key = G.ImGui, G.ImVec2, G.ImGuiKey
ImGui.CreateContext()
G.ImGui_ImplRoblox.Init()
local io = ImGui.GetIO()

local function eq(a, b, msg)
    assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local editor = TextEditor.new()
editor:SetLanguage(TextEditor.Language.Lua())
editor:SetText("local x = 1")

local function key(k) io:AddKeyEvent(k, true); io:AddKeyEvent(k, false) end
local function ctrl(k) io:AddKeyEvent(G.ImGuiMod_Ctrl, true); key(k); io:AddKeyEvent(G.ImGuiMod_Ctrl, false) end

-- one input step per frame; `check` steps run after the frame was rendered
local steps = {
    [5] = function() io:AddMousePosEvent(400, 60) end,
    [6] = function() io:AddMouseButtonEvent(0, true) end,
    [7] = function() io:AddMouseButtonEvent(0, false) end,
    [10] = function() io:AddInputCharacter(string.byte("!")) end,
    [12] = function() key(Key.Enter) end,
    [14] = function() io:AddInputCharactersUTF8("y") end,
    [16] = function() key(Key.Backspace) end,
    [18] = function() io:AddInputCharactersUTF8("z") end,
    [20] = function() ctrl(Key.Z) end,
    [24] = function() ctrl(Key.A) end,
    [26] = function() ctrl(Key.C) end,
    [28] = function() key(Key.End) end,
    [30] = function() ctrl(Key.V) end,
    -- ctrl+click adds a second cursor at the start of line 0 (line numbers end ~40px in)
    [34] = function() io:AddMousePosEvent(60, 30) end,
    [35] = function() io:AddKeyEvent(G.ImGuiMod_Ctrl, true); io:AddMouseButtonEvent(0, true) end,
    [36] = function() io:AddMouseButtonEvent(0, false); io:AddKeyEvent(G.ImGuiMod_Ctrl, false) end,
}

local checks = {
    [8] = function() eq(editor:GetCursorPosition(0), TextEditor.DocPos.new(0, 11), "click at end of line") end,
    [11] = function() eq(editor:GetText(), "local x = 1!\n", "typed char") end,
    [13] = function() eq(editor:GetText(), "local x = 1!\n", "enter"); eq(editor:GetLineCount(), 2, "enter lines"); eq(editor:GetCursorPosition(0), TextEditor.DocPos.new(1, 0), "enter cursor") end,
    [15] = function() eq(editor:GetText(), "local x = 1!\ny\n", "typed after enter") end,
    [17] = function() eq(editor:GetText(), "local x = 1!\n", "backspace") end,
    [19] = function() eq(editor:GetText(), "local x = 1!\nz\n", "typed z") end,
    [21] = function() eq(editor:GetText(), "local x = 1!\n", "ctrl+z undoes z") end,
    [25] = function() assert(editor:AnyCursorHasSelection(), "ctrl+a selects") end,
    [27] = function() eq(ImGui.GetClipboardText(), "local x = 1!\n", "ctrl+c") end,
    [31] = function() eq(editor:GetText(), "local x = 1!\nlocal x = 1!\n", "ctrl+v") end,
    [37] = function() eq(editor:GetNumberOfCursors(), 2, "ctrl+click adds cursor") end,
}

local frame = 0
game:GetService("RunService").Stepped:Connect(function()
    frame += 1
    if frame > 50 then return end
    G.ImGui_ImplRoblox.NewFrame()
    io.DeltaTime = 1 / 60
    if steps[frame] then steps[frame]() end
    ImGui.NewFrame()
    ImGui.SetNextWindowPos(ImVec2(0, 0))
    ImGui.SetNextWindowSize(ImVec2(600, 400))
    ImGui.Begin("Editor")
    editor:Render("##editor")
    ImGui.End()
    ImGui.Render()
    G.ImGui_ImplRoblox.RenderDrawData(ImGui.GetDrawData())
    if checks[frame] then checks[frame]() end
    if frame == 50 then print("OK") end
end)
