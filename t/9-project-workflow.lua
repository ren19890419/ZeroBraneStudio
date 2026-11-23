local problems = ide:GetPackage("core.problems")
ok(problems ~= nil, "The IDE has a Problems panel.")
local projectPackage = ide:GetPackage("core.project")
ok(type(projectPackage.SaveRunProfile) == "function", "Projects can save named run and debug profiles.")

if problems then
  local entries = ide:AnalyzeDiagnostics("local value =\n", "C:/project with spaces/broken.lua")
  is(entries[1] and entries[1].severity, "error", "Syntax errors are reported as structured diagnostics.")
  is(entries[1] and entries[1].file, "C:/project with spaces/broken.lua", "Diagnostics preserve absolute paths.")
  entries = ide:AnalyzeDiagnostics("local unused = 1\n", "C:/project/example.lua")
  is(entries[1] and entries[1].severity, "warning", "The existing analyzer supplies Problems warnings.")
end

if type(projectPackage.SaveRunProfile) == "function" then
  local root = wx.wxFileName.DirName(wx.wxGetCwd()):GetFullPath()
  local entry = ide:MergePath(root, "t/test.lua")
  local original = projectPackage:GetSettings()
  local interpreter = ide:GetInterpreter():GetFileName()
  ok(projectPackage:SaveRunProfile(root, {name = "Development", mode = "launch",
    entry = "t/test.lua", cwd = "t", interpreter = interpreter, args = "--dev"}),
    "A local profile accepts a project-relative entry and working directory.")
  ok(projectPackage:SaveRunProfile(root, {name = "Attach", mode = "attach", entry = entry,
    cwd = "", interpreter = interpreter, args = ""}), "A project can also store a remote attach profile.")
  projectPackage:SelectRunProfile(root, "Development")
  local selected = projectPackage:GetActiveRunProfile(root)
  is(selected and selected.args, "--dev", "The named profile supplies its saved arguments.")
  local resolved = selected and ide:ResolveRunProfile(root, selected)
  ok(resolved and wx.wxFileName(resolved.entry):SameAs(wx.wxFileName(entry)) or false,
    "The profile entry resolves relative to its project.")
  ok(resolved and ide:IsSameDirectoryPath(resolved.cwd, ide:MergePath(root, "t/")) or false,
    "The profile working directory resolves relative to its project.")
  ok(not projectPackage:SaveRunProfile(root, {name = "Invalid", mode = "launch",
    entry = "missing-entry.lua", cwd = "", interpreter = interpreter, args = ""}),
    "A profile cannot save a missing entry or overwrite the active selection.")
  is(projectPackage:GetActiveRunProfile(root).name, "Development", "An invalid profile keeps the previous selection.")
  projectPackage:SelectRunProfile(root, "Attach")
  selected = projectPackage:GetActiveRunProfile(root)
  is(selected and selected.mode, "attach", "Switching profiles selects the stored remote mode.")
  projectPackage:SelectRunProfile(root)
  ok(projectPackage:GetActiveRunProfile(root) == nil, "The default run behavior is selectable.")
  projectPackage:SetSettings(original)
end
