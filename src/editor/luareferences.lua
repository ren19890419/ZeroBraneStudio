local lsp = require "lsp"
local ide = ide
local client = ide:GetPackage("core.luals")
local findId, contextId, viewId = ID("search.luals.references"), ID("editor.luals.references"),
  ID("view.luals.references")
local title, findLabel = TR("Lua References"), TR("Find All Lua References")
local empty = TR("Place the cursor on a Lua symbol and choose Find All Lua References.")
local notebook = ide:GetOutputNotebook()
local panel = wx.wxPanel(notebook, wx.wxID_ANY)
local summary = wx.wxStaticText(panel, wx.wxID_ANY, empty)
local list = wx.wxListCtrl(panel, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize,
  wx.wxLC_REPORT + wx.wxLC_SINGLE_SEL)
list:SetName(title)
local sizer = wx.wxBoxSizer(wx.wxVERTICAL)
sizer:Add(summary, 0, wx.wxEXPAND + wx.wxALL, 5)
sizer:Add(list, 1, wx.wxEXPAND)
panel:SetSizer(sizer)
local widths = {360, 70, 75}
for index, heading in ipairs({TR("File"), TR("Line"), TR("Column")}) do
  list:InsertColumn(index - 1, heading)
  list:SetColumnWidth(index - 1, widths[index])
end
ide:AddPanelDocked(notebook, panel, "luareferencespanel", title, nil, false)

local locations = {}
local function render(status, results)
  locations = results or {}
  local project = ide:GetProject()
  list:Freeze()
  list:DeleteAllItems()
  for index, location in ipairs(locations) do
    local file = wx.wxFileName(location.path)
    if project then file:MakeRelativeTo(project) end
    local row = list:InsertItem(index - 1, file:GetFullPath())
    list:SetItem(row, 1, tostring(location.line + 1))
    list:SetItem(row, 2, tostring(location.character + 1))
  end
  list:Thaw()
  summary:SetLabel(status)
end

local function find(editor, pos)
  if not client:CanFindReferences(editor) then return end
  if not client:FindReferences(editor, pos or editor:GetCurrentPos(), function(results, err)
    if err then
      render((err:gsub("[\r\n]+", " ")))
    else
      render(#results == 0 and TR("No Lua references found.")
        or TR("Lua references found: %d"):format(#results), results)
    end
  end) then return end
  render(TR("Finding Lua references..."))
  ide:ActivateNotebookPage(panel)
end

list:Connect(wx.wxEVT_COMMAND_LIST_ITEM_ACTIVATED, function(event)
  local index = event:GetIndex()
  if index < 0 then index = list:GetNextItem(-1, wx.wxLIST_NEXT_ALL, wx.wxLIST_STATE_SELECTED) end
  local location = locations[index + 1]
  if not location then return end
  local editor = ide:LoadFile(location.path, nil, true)
  if not ide:IsValidCtrl(editor) then return end
  local line = math.min(location.line, editor:GetLineCount() - 1)
  local start = editor:PositionFromLine(line)
  local text = editor:GetTextRangeDyn(start, editor:GetLineEndPosition(line))
  editor:GotoPosDelayed(start + lsp.byteOffset(text, location.character, location.encoding))
end)

ide:AddPackage("core.luareferences", {
  onLuaLSStop = function() render(empty) end,
  onMenuEditor = function(self, menu, editor, event)
    if not client:CanFindReferences(editor) then return end
    local point = event:GetPosition()
    local pos
    if point.x ~= -1 or point.y ~= -1 then
      point = editor:ScreenToClient(point)
      pos = editor:PositionFromPointClose(point.x, point.y)
      if pos == wxstc.wxSTC_INVALID_POSITION then pos = nil end
    end
    menu:AppendSeparator()
    menu:Append(contextId, findLabel)
    menu:Connect(contextId, wx.wxEVT_COMMAND_MENU_SELECTED, function() find(editor, pos) end)
  end,
})

local frame = ide:GetMainFrame()
local function currentEditor() return ide:GetEditorWithFocus() or ide:GetEditor() end
local shortcut = "Alt-Shift-F12"
if not ide.config.keymap[findId] and not ide:GetHotKey(shortcut) then
  ide.config.keymap[findId] = shortcut
end
ide:FindTopMenu("&Search"):Append(findId, findLabel..KSC(findId))
ide:FindTopMenu("&View"):Append(viewId, title)
frame:Connect(findId, wx.wxEVT_COMMAND_MENU_SELECTED, function() find(currentEditor()) end)
frame:Connect(findId, wx.wxEVT_UPDATE_UI, function(event) event:Enable(client:CanFindReferences(currentEditor())) end)
frame:Connect(viewId, wx.wxEVT_COMMAND_MENU_SELECTED, function() ide:ActivateNotebookPage(panel) end)
