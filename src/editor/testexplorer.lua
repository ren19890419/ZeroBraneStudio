local ide = ide
local json = require "dkjson"
local frame = ide:GetMainFrame()
local notebook = ide:GetOutputNotebook()
local title = TR("Test Explorer")
local viewId = ID("view.testexplorer")
local runId, rerunId = ID("project.test.runfile"), ID("project.test.rerun")
local panel = wx.wxPanel(notebook, wx.wxID_ANY)
local runButton = wx.wxButton(panel, runId, TR("Run Current Test File"))
local rerunButton = wx.wxButton(panel, rerunId, TR("Rerun Failed Tests"))
local summary = wx.wxStaticText(panel, wx.wxID_ANY, "")
local actions = wx.wxBoxSizer(wx.wxHORIZONTAL)
actions:Add(runButton, 0, wx.wxRIGHT, 6)
actions:Add(rerunButton, 0, wx.wxRIGHT, 10)
actions:Add(summary, 1, wx.wxALIGN_CENTER_VERTICAL)

local list = wx.wxListCtrl(panel, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize,
  wx.wxLC_REPORT + wx.wxLC_SINGLE_SEL)
list:SetName(title)
local columns = {{TR("Result"), 100}, {TR("Test"), 255}, {TR("Location"), 200}, {TR("Message"), 420}}
for index, column in ipairs(columns) do
  list:InsertColumn(index - 1, column[1])
  list:SetColumnWidth(index - 1, column[2])
end
local layout = wx.wxBoxSizer(wx.wxVERTICAL)
layout:Add(actions, 0, wx.wxALL + wx.wxEXPAND, 5)
layout:Add(list, 1, wx.wxEXPAND)
panel:SetSizer(layout)
ide:AddPanelDocked(notebook, panel, "testexplorerpanel", title, nil, false)

local active, last, message
local labels = {failed = TR("Failed"), error = TR("Error"), passed = TR("Passed"), pending = TR("Pending")}
local function failed(row) return row.status == "failed" or row.status == "error" end

local function currentFile()
  local editor = ide:GetEditor()
  local document = editor and ide:GetDocument(editor)
  if document and editor.spec and editor.spec.apitype == "lua" then return document:GetFilePath() end
end

local function canRerun()
  if active or not last then return false end
  for _, row in ipairs(last.rows) do if failed(row) then return true end end
  return false
end

local function singleLine(text)
  local line = FixUTF8((text:gsub("[%z\r\n]+", " ")), "\239\191\189")
  return line
end

local function render()
  list:Freeze()
  list:DeleteAllItems()
  local counts = {passed = 0, failed = 0, pending = 0}
  for index, row in ipairs(last and last.rows or {}) do
    local location = wx.wxFileName(row.path)
    if last.cwd then location:MakeRelativeTo(last.cwd) end
    local display = location:GetFullPath()..(row.line > 0 and ":"..row.line or "")
    list:InsertItem(index - 1, labels[row.status])
    list:SetItem(index - 1, 1, singleLine(row.name))
    list:SetItem(index - 1, 2, display)
    list:SetItem(index - 1, 3, singleLine(row.message))
    local count = failed(row) and "failed" or row.status
    counts[count] = counts[count] + 1
  end
  list:Thaw()
  summary:SetLabel(active and TR("Running tests...") or message or
    (last and TR("%d passed, %d failed, %d pending"):format(counts.passed, counts.failed, counts.pending))
    or TR("Run the current Lua test file."))
  panel:Layout()
end

local function resolvedFile(path, cwd)
  if type(path) ~= "string" or path == "" or path:find("[%z\r\n]") then return end
  local file = wx.wxFileName(path)
  file:Normalize(wx.wxPATH_NORM_ABSOLUTE + wx.wxPATH_NORM_DOTS, cwd)
  path = file:GetFullPath()
  if wx.wxFileExists(path) then return path end
end

local function readResults(job)
  local data = FileRead(job.request..".results")
  if not data then return end
  local rows
  for line in data:gmatch("[^\r\n]+") do
    local report = json.decode(line)
    if type(report) == "table" and type(report.rows) == "table" then
      rows = rows or {}
      local cwd = type(report.cwd) == "string" and wx.wxDirExists(report.cwd) and report.cwd or job.cwd
      for _, row in ipairs(report.rows) do
        if type(row) == "table" and labels[row.status] and type(row.name) == "string" then
          row.message = type(row.message) == "string" and row.message or ""
          local mentioned, lineNumber = row.message:match("^([^\r\n]-):(%d+):")
          local path = failed(row) and resolvedFile(mentioned, cwd)
          local line = path and tonumber(lineNumber) or nil
          if not path then path, line = resolvedFile(row.file, cwd), tonumber(row.line) end
          if not path then path, line = resolvedFile(row.definitionFile, cwd), tonumber(row.definitionLine) end
          row.path, row.line = path or job.path, line and math.max(0, math.floor(line)) or 0
          rows[#rows + 1] = row
        end
      end
    end
  end
  return rows
end

local function cleanup(job)
  FileRemove(job.request)
  FileRemove(job.request..".results")
end

local function finish(job, code)
  if active ~= job then cleanup(job); return end
  local rows = code ~= nil and readResults(job)
  cleanup(job)
  active = nil
  local anyFailure = false
  for _, row in ipairs(rows or {}) do if failed(row) then anyFailure = true; break end end
  if not rows or code ~= 0 and not anyFailure then
    message = TR("Busted did not finish reporting tests. See Output for details.")
  else
    local combined = {}
    if job.names and last then
      for _, row in ipairs(last.rows) do
        if not job.names[row.name] then combined[#combined + 1] = row end
      end
    end
    for _, row in ipairs(rows) do combined[#combined + 1] = row end
    last = {path = job.path, cwd = job.cwd, rows = combined}
    message = #rows == 0 and TR("No matching tests ran.") or nil
  end
  render()
end

local function reportError(text)
  message = text
  ide:GetOutput():Error(text)
  render()
end

local function quote(value)
  if ide.osname ~= "Windows" then value = value:gsub('[\\"]', '\\%0') end
  return '"'..value..'"'
end

local function start(path, names, cwd)
  if active or not path then return false end
  ide:ActivateNotebookPage(panel)
  local interpreter = ide:GetInterpreter("busted")
  local executable = interpreter and interpreter:GetExecutable()
  if not executable then
    reportError(TR("Busted was not found. Install Busted or set path.busted in user.lua."))
    return false
  end
  local document = ide:FindDocument(path)
  if document and document:IsModified() and not document:Save() then return false end
  if not wx.wxFileExists(path) then
    reportError(TR("The test file no longer exists."))
    return false
  end
  local temporary = wx.wxFile()
  local request = wx.wxFileName.CreateTempFileName("zbs-busted", temporary)
  if not request or request == "" then
    reportError(TR("Could not create the Busted test report."))
    return false
  end
  temporary:Close()
  local filename = wx.wxFileName(path)
  local job = {request = request, path = path, cwd = cwd or interpreter:fworkdir(filename), names = names}
  if not FileWrite(request, json.encode({names = names})) then
    cleanup(job)
    reportError(TR("Could not create the Busted test report."))
    return false
  end
  local token = request:gsub(".", function(char) return ("%02x"):format(char:byte()) end)
  local reporter = ide:GetRootPath("lualibs/bustedoutput.lua")
  local cmd = table.concat({quote(executable), interpreter:GetRunOptions(),
    "--output="..quote(reporter), "-Xoutput", token, quote(path)}, " ")
  active, message = job, nil
  if not cwd then last = nil end
  local function log(data) if active == job then return data end end
  local pid, err = ide:ExecuteCommand(cmd, job.cwd, log, function(_, code) finish(job, code) end, {group = true})
  if not pid then
    cleanup(job)
    active = nil
    reportError(TR("Could not start Busted: %s"):format(err or executable))
    return false
  end
  job.pid = pid
  render()
  return true
end

local function reset()
  local job = active
  active, last, message = nil, nil, nil
  if job then
    if wx.wxProcess.Exists(job.pid) then wx.wxProcess.Kill(job.pid, wx.wxSIGKILL, wx.wxKILL_CHILDREN) end
    cleanup(job)
  end
end

local tests = ide:AddPackage("core.testexplorer", {
  GetResults = function() return last and last.rows or {} end,
  IsRunning = function() return active ~= nil end,
  Show = function() ide:ActivateNotebookPage(panel) end,
  RunCurrent = function() return start(currentFile()) end,
  RerunFailures = function()
    if not canRerun() then return false end
    local names = {}
    for _, row in ipairs(last.rows) do
      if failed(row) then
        -- A file load or setup failure has no test name to filter on.
        if not row.test then names = nil; break end
        names[row.name] = true
      end
    end
    return start(last.path, names, last.cwd)
  end,
  onProjectClose = function() reset(); render() end,
  onProjectLoad = function() reset(); render() end,
  onAppClose = reset,
})

list:Connect(wx.wxEVT_COMMAND_LIST_ITEM_ACTIVATED, function(event)
  local index = event:GetIndex()
  if index < 0 then index = list:GetNextItem(-1, wx.wxLIST_NEXT_ALL, wx.wxLIST_STATE_SELECTED) end
  local row = last and last.rows[index + 1]
  if not row then return end
  local editor = ide:LoadFile(row.path, nil, true)
  if not editor then return end
  local line = math.min(math.max(0, row.line - 1), editor:GetLineCount() - 1)
  editor:GotoPosDelayed(editor:PositionFromLine(line))
end)

ide:FindTopMenu("&View"):Append(viewId, title)
local menu = ide:FindTopMenu("&Project")
menu:Append(runId, TR("Run Current Test File"))
menu:Append(rerunId, TR("Rerun Failed Tests"))
frame:Connect(viewId, wx.wxEVT_COMMAND_MENU_SELECTED, function() tests:Show() end)
frame:Connect(runId, wx.wxEVT_COMMAND_MENU_SELECTED, function() tests:RunCurrent() end)
frame:Connect(rerunId, wx.wxEVT_COMMAND_MENU_SELECTED, function() tests:RerunFailures() end)
frame:Connect(runId, wx.wxEVT_UPDATE_UI, function(event) event:Enable(not active and currentFile() ~= nil) end)
frame:Connect(rerunId, wx.wxEVT_UPDATE_UI, function(event) event:Enable(canRerun()) end)
panel:Connect(runId, wx.wxEVT_COMMAND_BUTTON_CLICKED, function() tests:RunCurrent() end)
panel:Connect(rerunId, wx.wxEVT_COMMAND_BUTTON_CLICKED, function() tests:RerunFailures() end)
panel:Connect(runId, wx.wxEVT_UPDATE_UI, function(event) event:Enable(not active and currentFile() ~= nil) end)
panel:Connect(rerunId, wx.wxEVT_UPDATE_UI, function(event) event:Enable(canRerun()) end)
render()
