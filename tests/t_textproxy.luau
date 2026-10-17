-- Roblox text proxy: the editor's selection is mirrored into the proxy TextBox, and proxy typing is inserted.
local RS = game:GetService("ReplicatedStorage")
local G = require(RS:WaitForChild("ImGui"))
local TextEditor = require(RS:WaitForChild("TextEditor"))(G)
local ImGui, ImVec2 = G.ImGui, G.ImVec2
ImGui.CreateContext()
G.ImGui_ImplRoblox.Init()
G.ImGui_ImplRoblox.SetTextProxy(true)
local io = ImGui.GetIO()

local editor = TextEditor.new()
editor:SetText("hello world")

local proxy
local frame = 0
game:GetService("RunService").Stepped:Connect(function()
    frame += 1
    if frame > 30 then return end
    G.ImGui_ImplRoblox.NewFrame()
    io.DeltaTime = 1 / 60
    proxy = proxy or game:GetService("Players").LocalPlayer.PlayerGui.ImGui.TextProxy
    if frame == 5 then io:AddMousePosEvent(400, 60) end
    if frame == 6 then io:AddMouseButtonEvent(0, true) end
    if frame == 7 then io:AddMouseButtonEvent(0, false) end
    if frame == 9 then editor:SelectAll() end
    if frame == 16 then proxy.Text = "bye" end
    ImGui.NewFrame()
    ImGui.SetNextWindowPos(ImVec2(0, 0))
    ImGui.SetNextWindowSize(ImVec2(600, 400))
    ImGui.Begin("Editor")
    editor:Render("##editor")
    ImGui.End()
    ImGui.Render()
    G.ImGui_ImplRoblox.RenderDrawData(ImGui.GetDrawData())
    if frame == 14 then assert(proxy.Text == "hello world", "mirror: " .. proxy.Text) end
    if frame == 25 then
        assert(editor:GetText() == "bye\n", "inserted: " .. editor:GetText())
        print("OK")
    end
end)
