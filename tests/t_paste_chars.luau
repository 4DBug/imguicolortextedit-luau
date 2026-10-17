local RS = game:GetService("ReplicatedStorage")
local G = require(RS:WaitForChild("ImGui"))
local TextEditor = require(RS:WaitForChild("TextEditor"))(G)
local ImGui = G.ImGui
ImGui.CreateContext(); G.ImGui_ImplRoblox.Init()
local io = ImGui.GetIO()
io.DisplaySize = G.ImVec2(800, 600)
local ed = TextEditor.new()
ed:SetLanguage(TextEditor.Language.Lua())
ed:SetText("")
for f = 1, 6 do
    io.DeltaTime = 1 / 60
    if f == 2 then io:AddMousePosEvent(200, 100); io:AddMouseButtonEvent(0, true) end
    if f == 3 then io:AddMouseButtonEvent(0, false) end
    if f == 4 then for _, c in utf8.codes("local x = 1\nprint(x)\n  ddd") do io:AddInputCharacter(c) end end
    ImGui.NewFrame()
    ImGui.SetNextWindowPos(G.ImVec2(0, 0)); ImGui.SetNextWindowSize(G.ImVec2(800, 600))
    ImGui.Begin("w"); ed:Render("ed"); ImGui.End()
    ImGui.Render()
end
local t = ed:GetText()
assert(t == "local x = 1\nprint(x)\n  ddd\n" or t == "local x = 1\nprint(x)\n  ddd", ("paste as chars: %q"):format(t))
print("OK")
