local lsp = require "lsp"
local ide = ide
local client = ide:GetPackage("core.luals")
local commandId, contextId = ID("search.luals.rename"), ID("editor.luals.rename")
local title, command = TR("Lua Rename Preview"), TR("Rename Lua Symbol...")
local hint = TR("Choose Rename Lua Symbol to preview a cross-file rename.")
local changed = TR("A file changed. Preview the rename again.")
local unavailable = TR("Cannot edit %s.")
local notebook = ide:GetOutputNotebook()
local panel = wx.wxPanel(notebook, wx.wxID_ANY)
local nameLabel = wx.wxStaticText(panel, wx.wxID_ANY, TR("New Name"))
local name = wx.wxTextCtrl(panel, wx.wxID_ANY, "", wx.wxDefaultPosition, wx.wxDefaultSize, wx.wxTE_PROCESS_ENTER)
local previewButton = wx.wxButton(panel, wx.wxID_ANY, TR("Preview Changes"))
local summary = wx.wxStaticText(panel, wx.wxID_ANY, hint)
local list = wx.wxListCtrl(panel, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize,
  wx.wxLC_REPORT + wx.wxLC_SINGLE_SEL)
local applyButton = wx.wxButton(panel, wx.wxID_ANY, TR("Apply Changes"))
local cancelButton = wx.wxButton(panel, wx.wxID_ANY, TR("Cancel"))
name:SetName(TR("New Name"))
list:SetName(title)
local input, actions = wx.wxBoxSizer(wx.wxHORIZONTAL), wx.wxBoxSizer(wx.wxHORIZONTAL)
input:Add(nameLabel, 0, wx.wxALIGN_CENTER_VERTICAL + wx.wxRIGHT, 6)
input:Add(name, 1, wx.wxRIGHT, 6)
input:Add(previewButton, 0, wx.wxALIGN_CENTER_VERTICAL)
actions:Add(applyButton, 0, wx.wxRIGHT, 6)
actions:Add(cancelButton, 0)
local layout = wx.wxBoxSizer(wx.wxVERTICAL)
layout:Add(input, 0, wx.wxEXPAND + wx.wxALL, 5)
layout:Add(summary, 0, wx.wxEXPAND + wx.wxLEFT + wx.wxRIGHT + wx.wxBOTTOM, 5)
layout:Add(list, 1, wx.wxEXPAND)
layout:Add(actions, 0, wx.wxALIGN_RIGHT + wx.wxALL, 5)
panel:SetSizer(layout)
local widths = {200, 65, 300, 300}
for index, heading in ipairs({TR("File"), TR("Line"), TR("Before"), TR("After")}) do
  list:InsertColumn(index - 1, heading)
  list:SetColumnWidth(index - 1, widths[index])
end
ide:AddPanelDocked(notebook, panel, "luarenamepanel", title, nil, false)

local keywords = {}
for word in (ide.specs.lua.keywords[1].." false nil true"):gmatch("%S+") do keywords[word] = true end
local target, plan, rows = nil, nil, {}

local function oneLine(text)
  return (text:gsub("\r\n", "\\n"):gsub("[\r\n]", "\\n"):gsub("\t", "    "))
end

local function render(status, files)
  plan, rows = files, {}
  list:Freeze()
  list:DeleteAllItems()
  local project = ide:GetProject()
  for _, file in ipairs(files or {}) do
    local filename = wx.wxFileName(file.path)
    if project then filename:MakeRelativeTo(project) end
    for _, edit in ipairs(file.edits) do
      local row = list:InsertItem(#rows, filename:GetFullPath())
      rows[row + 1] = {file = file, edit = edit}
      local before = file.text:sub(edit.contextStart, edit.contextEnd)
      local after = file.text:sub(edit.contextStart, edit.start)..edit.text
        ..file.text:sub(edit.finish + 1, edit.contextEnd)
      list:SetItem(row, 1, tostring(edit.line + 1))
      list:SetItem(row, 2, oneLine(before))
      list:SetItem(row, 3, oneLine(after))
    end
  end
  list:Thaw()
  summary:SetLabel(status and oneLine(status) or TR("%d replacements in %d files"):format(#rows, #files))
  name:Enable(target ~= nil)
  previewButton:Enable(target ~= nil)
  applyButton:Enable(#rows > 0)
  cancelButton:Enable(target ~= nil)
end

local function reset(status)
  client:CancelRename()
  target = nil
  name:ChangeValue("")
  render(status or hint)
end

local function diskText(raw)
  return (raw:gsub("^\239\187\191", "")) -- LoadFile keeps a UTF-8 BOM outside the editor text.
end

local function readFile(path)
  local doc = ide:FindDocument(path)
  local editor = doc and doc:GetEditor()
  local disk = FileRead(path)
  if not disk then return end
  local text = editor and editor:GetTextDyn() or diskText(disk)
  return text, disk, editor
end

local function buildPreview(files)
  local result = {}
  for _, file in ipairs(files) do
    local text, disk, editor = readFile(file.path)
    if not text or editor and editor:GetReadOnly() then return nil, unavailable:format(file.path) end
    local edits = lsp.textEdits(text, file.edits, file.encoding)
    if not edits then return nil, TR("LuaLS returned invalid or overlapping rename ranges.") end
    if #edits > 0 then result[#result + 1] = {path = file.path, text = text, disk = disk, edits = edits} end
  end
  return result
end

local function targetIsCurrent()
  return target and ide:IsValidCtrl(target.editor) and client:CanRename(target.editor)
    and ide:GetDocument(target.editor):GetFilePath() == target.path
    and target.editor:GetTextDyn() == target.text
end

local function preview()
  if not targetIsCurrent() then reset(TR("The source changed. Choose Rename Lua Symbol again.")); return end
  local newName = name:GetValue()
  if not newName:match("^[A-Za-z_][A-Za-z0-9_]*$") or keywords[newName] then
    render(TR("Enter a valid Lua identifier."))
    return
  end
  if newName == target.original then render(TR("Enter a different name.")); return end
  local current = target
  if client:RenameSymbol(target.editor, target.pos, newName, function(files, err)
    if target ~= current then return end
    if err then render(err); return end
    local result, problem = buildPreview(files)
    if problem then render(problem)
    elseif #result == 0 then render(TR("LuaLS found no changes for this symbol."))
    else render(nil, result) end
  end) then
    render(TR("Preparing Lua rename preview..."))
  end
end

local function apply()
  if not plan then return end
  if not targetIsCurrent() then reset(TR("The source changed. Choose Rename Lua Symbol again.")); return end
  local editors = {}
  for i, file in ipairs(plan) do
    local text, disk, editor = readFile(file.path)
    if text ~= file.text or disk ~= file.disk then render(changed); return end
    if editor and editor:GetReadOnly() then render(unavailable:format(file.path)); return end
    editors[i] = editor or false
  end

  -- Load all affected buffers before replacing text in any of them.
  for i, file in ipairs(plan) do
    local editor = editors[i] or ide:LoadFile(file.path, nil, true, true)
    if not editor or editor:GetReadOnly() then render(unavailable:format(file.path)); return end
    editors[i] = editor
  end
  for i, file in ipairs(plan) do
    if editors[i]:GetTextDyn() ~= file.text then render(changed); return end
  end

  for i, file in ipairs(plan) do
    local editor = editors[i]
    editor:BeginUndoAction()
    local ok, err = pcall(function()
      for index = #file.edits, 1, -1 do
        local edit = file.edits[index]
        editor:SetTargetStart(edit.start)
        editor:SetTargetEnd(edit.finish)
        editor:ReplaceTargetDyn(edit.text)
      end
    end)
    editor:EndUndoAction()
    if not ok then
      for applied = i, 1, -1 do
        if editors[applied]:GetTextDyn() ~= plan[applied].text then editors[applied]:Undo() end
      end
      ide:Print(err)
      render(TR("Could not apply the Lua rename."))
      return
    end
  end
  reset(TR("Renamed in %d files. Save the affected files to write the changes to disk."):format(#plan))
end

local function begin(editor, pos)
  if not client:CanRename(editor) then return end
  client:CancelRename()
  pos = pos or editor:GetCurrentPos()
  local start, finish = editor:WordStartPosition(pos, true), editor:WordEndPosition(pos, true)
  local original = editor:GetTextRangeDyn(start, finish)
  target = {editor = editor, pos = pos, text = editor:GetTextDyn(), original = original,
    path = ide:GetDocument(editor):GetFilePath()}
  name:ChangeValue(original)
  render(TR("Enter a new name, then preview the changes."))
  ide:ActivateNotebookPage(panel)
  name:SetFocus()
  name:SetSelection(-1, -1)
end

name:Connect(wx.wxEVT_COMMAND_TEXT_UPDATED, function()
  if not target then return end
  client:CancelRename()
  render(TR("Enter a new name, then preview the changes."))
end)
name:Connect(wx.wxEVT_COMMAND_TEXT_ENTER, preview)
previewButton:Connect(wx.wxEVT_COMMAND_BUTTON_CLICKED, preview)
applyButton:Connect(wx.wxEVT_COMMAND_BUTTON_CLICKED, apply)
cancelButton:Connect(wx.wxEVT_COMMAND_BUTTON_CLICKED, function() reset(hint) end)
list:Connect(wx.wxEVT_COMMAND_LIST_ITEM_ACTIVATED, function(event)
  local index = event:GetIndex()
  if index < 0 then index = list:GetNextItem(-1, wx.wxLIST_NEXT_ALL, wx.wxLIST_STATE_SELECTED) end
  local row = rows[index + 1]
  if not row then return end
  local editor = ide:LoadFile(row.file.path, nil, true)
  if editor and editor:GetTextDyn() == row.file.text then editor:GotoPosDelayed(row.edit.start)
  else render(changed) end
end)

ide:AddPackage("core.luarename", {
  onLuaLSStop = function() reset(hint) end,
  onMenuEditor = function(self, menu, editor, event)
    if not client:CanRename(editor) then return end
    local point = event:GetPosition()
    local pos
    if point.x ~= -1 or point.y ~= -1 then
      point = editor:ScreenToClient(point)
      pos = editor:PositionFromPointClose(point.x, point.y)
      if pos == wxstc.wxSTC_INVALID_POSITION then pos = nil end
    end
    menu:Append(contextId, command)
    menu:Connect(contextId, wx.wxEVT_COMMAND_MENU_SELECTED, function() begin(editor, pos) end)
  end,
})

local frame = ide:GetMainFrame()
local function currentEditor() return ide:GetEditorWithFocus() or ide:GetEditor() end
local shortcut = "Alt-Shift-R"
if not ide.config.keymap[commandId] and not ide:GetHotKey(shortcut) then
  ide.config.keymap[commandId] = shortcut
end
ide:FindTopMenu("&Search"):Append(commandId, command..KSC(commandId))
frame:Connect(commandId, wx.wxEVT_COMMAND_MENU_SELECTED, function() begin(currentEditor()) end)
frame:Connect(commandId, wx.wxEVT_UPDATE_UI, function(event) event:Enable(client:CanRename(currentEditor())) end)
reset(hint)
