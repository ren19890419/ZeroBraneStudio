local ide = ide
local viewId, scanId = ID("view.problems"), ID("project.analyze")
local name = TR("Problems")
local notebook = ide:GetOutputNotebook()
local panel = wx.wxPanel(notebook, wx.wxID_ANY)
local summary = wx.wxStaticText(panel, wx.wxID_ANY, "")
local list = wx.wxListCtrl(panel, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize,
  wx.wxLC_REPORT + wx.wxLC_SINGLE_SEL)
list:SetName(name)
local sizer = wx.wxBoxSizer(wx.wxVERTICAL)
sizer:Add(summary, 0, wx.wxEXPAND + wx.wxALL, 5)
sizer:Add(list, 1, wx.wxEXPAND)
panel:SetSizer(sizer)
local widths = {90, 220, 60, 480}
for index, heading in ipairs({TR("Severity"), TR("File"), TR("Line"), TR("Message")}) do
  list:InsertColumn(index - 1, heading)
  list:SetColumnWidth(index - 1, widths[index])
end
ide:AddPanelDocked(notebook, panel, "problemspanel", name, nil, false)

local diagnostics, visible, scan = {}, {}, nil
local unsavedByEditor = {}
local analyzed = false
local function fileKey(path)
  return path:gsub("\\", "/")
end

local function render()
  local paths = {}
  for path in pairs(diagnostics) do paths[#paths + 1] = path end
  table.sort(paths)
  local project = ide:GetProject()
  list:Freeze()
  list:DeleteAllItems()
  visible = {}
  local errors, warnings = 0, 0
  for _, path in ipairs(paths) do
    for _, entry in ipairs(diagnostics[path]) do
      local isError = entry.severity == "error"
      if isError then errors = errors + 1 else warnings = warnings + 1 end
      local row = list:InsertItem(#visible, isError and TR("Error") or TR("Warning"))
      visible[row + 1] = entry
      local file = wx.wxFileName(entry.file)
      if project and not entry.editor then file:MakeRelativeTo(project) end
      list:SetItem(row, 1, file:GetFullPath())
      list:SetItem(row, 2, entry.line > 0 and tostring(entry.line) or "")
      list:SetItem(row, 3, ((entry.message or ""):gsub("[\r\n]+", " ")))
    end
  end
  list:Thaw()
  summary:SetLabel(scan and TR("Analyzing project...") or not analyzed and TR("Run Analyze to check Lua files.")
    or TR("%d errors, %d warnings"):format(errors, warnings))
end

local function analyze(source, path)
  local ok, result = pcall(ide.AnalyzeDiagnostics, ide, source, path)
  return ok and result or {{file = path, line = 0, severity = "error", message = tostring(result)}}
end

local problems = ide:AddPackage("core.problems", {
  GetDiagnostics = function(self, path) return diagnostics[fileKey(path)] or {} end,
  Show = function() ide:ActivateNotebookPage(panel) end,
  AnalyzeEditor = function(self, editor, show)
    if not editor or editor.spec.apitype ~= "lua" then return end
    local doc = ide:GetDocument(editor)
    local path = doc:GetFilePath() or doc:GetFileName()
    local key = fileKey(path)
    local previous = unsavedByEditor[editor]
    if previous then diagnostics[previous] = nil end
    local entries = analyze(editor:GetTextDyn(), path)
    if not doc:GetFilePath() then
      unsavedByEditor[editor] = key
      for _, entry in ipairs(entries) do entry.editor = editor end
    else
      unsavedByEditor[editor] = nil
      -- Use the document's spelling to preserve drive letters and spaces.
      for _, entry in ipairs(entries) do entry.file = path end
    end
    diagnostics[key] = entries
    analyzed = true
    render()
    if show then self:Show() end
    return entries
  end,
  ScanProject = function(self)
    local project = ide:GetProject()
    if not project then return end
    local files = ide:GetFileList(project, true, "*.lua;*.wlua", {folder = false, followsymlink = false})
    local pending = {}
    scan = pending
    diagnostics = {}
    analyzed = true
    self:Show()
    render()
    local index = 1
    local function batch()
      if scan ~= pending then return end
      local untilTime = ide:GetTime() + 0.015
      repeat
        local path = files[index]
        if not path then break end
        local doc = ide:FindDocument(path)
        local source = doc and doc:GetEditor():GetTextDyn() or FileRead(path)
        if source then
          local entries = analyze(source, path)
          for _, entry in ipairs(entries) do entry.file = path end
          diagnostics[fileKey(path)] = entries
        end
        index = index + 1
      until ide:GetTime() >= untilTime
      if index <= #files then ide:DoWhenIdle(batch, "core.problems.scan")
      else scan = nil; render() end
    end
    ide:DoWhenIdle(batch, "core.problems.scan")
  end,
  onEditorSave = function(self, editor) self:AnalyzeEditor(editor) end,
  onEditorClose = function(self, editor)
    local key = unsavedByEditor[editor]
    if not key then return end
    unsavedByEditor[editor], diagnostics[key] = nil, nil
    render()
  end,
  onProjectClose = function()
    diagnostics, scan, analyzed = {}, nil, false
    unsavedByEditor = {}
    render()
  end,
})

list:Connect(wx.wxEVT_COMMAND_LIST_ITEM_ACTIVATED, function(event)
  local index = event:GetIndex()
  if index < 0 then index = list:GetNextItem(-1, wx.wxLIST_NEXT_ALL, wx.wxLIST_STATE_SELECTED) end
  local entry = visible[index + 1]
  if not entry then return end
  local editor = entry.editor
  if editor and ide:IsValidCtrl(editor) then ide:GetDocument(editor):SetActive()
  elseif not editor then editor = ide:LoadFile(entry.file, nil, true) end
  if not ide:IsValidCtrl(editor) then return end
  local line = math.min(math.max(0, entry.line - 1), editor:GetLineCount() - 1)
  local position = editor:PositionFromLine(line)
  local endpos = editor:GetLineEndPosition(line)
  for column = 2, entry.column or 1 do
    if position >= endpos then break end
    position = editor:PositionAfter(position)
  end
  editor:GotoPosDelayed(position)
end)

local frame = ide:GetMainFrame()
ide:FindTopMenu("&View"):Append(viewId, name)
ide:FindTopMenu("&Project"):Append(scanId, TR("Analyze Project"))
frame:Connect(viewId, wx.wxEVT_COMMAND_MENU_SELECTED, function() problems:Show() end)
frame:Connect(scanId, wx.wxEVT_COMMAND_MENU_SELECTED, function() problems:ScanProject() end)
frame:Connect(scanId, wx.wxEVT_UPDATE_UI, function(event) event:Enable(ide:GetProject() ~= nil) end)
render()
