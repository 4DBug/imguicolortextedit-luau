-- Text editor demo, modelled on the classic ImGuiColorTextEdit example.
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local G = require(RS:WaitForChild("ImGui"))
local TextEditor = require(RS:WaitForChild("TextEditor"))(G)
local ImGui = G.ImGui

local SampleCode = [==[
-- Sample Lua code
local Players = game:GetService("Players")

local function Greet(name: string): string
	return "Hello, " .. name .. "!"
end

for i = 1, 10 do
	if i % 2 == 0 then
		print(Greet("Player" .. i), 3.14 * i, 0xFF)
	end
end

--[[ block
     comment ]]
local t = { a = 1, b = "two", [3] = true, nil }
]==]

local Editor = TextEditor.new()
Editor:SetLanguage(TextEditor.Language.Lua())
Editor:SetText(SampleCode)
local SavedUndoIndex = Editor:GetUndoIndex()

local function RenderDemo()
	ImGui.SetNextWindowSize(G.ImVec2(800, 600), G.ImGuiCond_FirstUseEver)
	ImGui.Begin("Text Editor Demo", nil, G.ImGuiWindowFlags_MenuBar)

	if ImGui.BeginMenuBar() then
		if ImGui.BeginMenu("File") then
			if ImGui.MenuItem("Save") then
				SavedUndoIndex = Editor:GetUndoIndex() -- stub: nowhere to save to
			end
			if ImGui.MenuItem("Quit", "Alt-F4") then
				-- stub
			end
			ImGui.EndMenu()
		end
		if ImGui.BeginMenu("Edit") then
			local ReadOnly = Editor:IsReadOnlyEnabled()
			if ImGui.MenuItem("Read-only mode", nil, ReadOnly) then
				Editor:SetReadOnlyEnabled(not ReadOnly)
			end
			ImGui.Separator()
			if ImGui.MenuItem("Undo", "Ctrl-Z", nil, Editor:CanUndo()) then Editor:Undo() end
			if ImGui.MenuItem("Redo", "Ctrl-Y", nil, Editor:CanRedo()) then Editor:Redo() end
			ImGui.Separator()
			local HasSelection = Editor:AnyCursorHasSelection()
			if ImGui.MenuItem("Copy", "Ctrl-C", nil, HasSelection) then Editor:Copy() end
			if ImGui.MenuItem("Cut", "Ctrl-X", nil, not ReadOnly and HasSelection) then Editor:Cut() end
			if ImGui.MenuItem("Delete", "Del", nil, not ReadOnly and HasSelection) then
				Editor:ReplaceTextInAllCursors("")
			end
			if ImGui.MenuItem("Paste", "Ctrl-V", nil, not ReadOnly) then Editor:Paste() end
			ImGui.Separator()
			if ImGui.MenuItem("Select all", "Ctrl-A") then Editor:SelectAll() end
			ImGui.EndMenu()
		end
		if ImGui.BeginMenu("View") then
			if ImGui.MenuItem("Dark palette") then Editor:SetPalette(TextEditor.GetDarkPalette()) end
			if ImGui.MenuItem("Light palette") then Editor:SetPalette(TextEditor.GetLightPalette()) end
			ImGui.EndMenu()
		end
		ImGui.EndMenuBar()
	end

	local Pos = Editor:GetMainCursorPosition()
	ImGui.Text(string.format("%d/%d | %d lines | %s | %s | %s",
		Pos.line + 1, Pos.index + 1, Editor:GetLineCount(),
		Editor:IsOverwriteEnabled() and "Ovr" or "Ins",
		Editor:GetUndoIndex() ~= SavedUndoIndex and "*" or " ",
		Editor:GetLanguageName()))

	Editor:Render("TextEditor")
	ImGui.End()
end

ImGui.CreateContext()
G.ImGui_ImplRoblox.Init() -- defaults to LocalPlayer.PlayerGui
RunService.RenderStepped:Connect(function()
	G.ImGui_ImplRoblox.NewFrame()
	ImGui.NewFrame()
	RenderDemo()
	ImGui.Render()
	G.ImGui_ImplRoblox.RenderDrawData(ImGui.GetDrawData())
end)
