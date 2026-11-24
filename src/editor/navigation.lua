local ide = ide
local frame = ide:GetMainFrame()
local entries, selected = {}, nil

local function fileKey(path)
  if not path then return end
  path = path:gsub("\\", "/")
  return ide.osname == "Windows" and path:lower() or path
end

local function keepPosition(entry, editor, pos)
  entry.editor = editor
  entry.position = math.max(0, math.min(pos, editor:GetLength()))
  entry.line = editor:LineFromPosition(entry.position)
  entry.column = editor:GetColumn(entry.position)
end

local function attach(entry, editor)
  local line = math.min(entry.line, editor:GetLineCount() - 1)
  keepPosition(entry, editor, editor:FindColumn(line, entry.column))
end

local function remove(index)
  if entries[index] == selected then selected = nil end
  table.remove(entries, index)
end

local function candidate(direction)
  local index = #entries
  if selected then
    while index > 0 and entries[index] ~= selected do index = index - 1 end
    index = index + direction
  elseif direction > 0 then return end

  local editor = ide:GetEditor()
  local pos = editor and editor:GetCurrentPos()
  while entries[index] do
    local entry = entries[index]
    if not editor or entry.editor ~= editor or entry.position ~= pos then return index end
    index = index + direction
  end
end

local function navigate(direction)
  local index = candidate(direction)
  while index do
    local entry = entries[index]
    local editor = entry.editor
    if editor and ide:IsValidCtrl(editor) and ide:GetDocument(editor) then
      ide:GetDocument(editor):SetActive()
    else
      editor = entry.path and ide:LoadFile(entry.path, nil, true)
      if editor and entry.editor ~= editor then attach(entry, editor) end
    end
    if editor then
      selected = entry
      editor:GotoPosDelayed(entry.position)
      return
    end
    remove(index)
    index = candidate(direction)
  end
end

ide:AddPackage("core.navigation", {
  onEditorChange = function(self, editor, pos, length, inserted, modification)
    if not pos or length == 0 or editor.loadingFile then return end
    local document = ide:GetDocument(editor)
    if not document then return end
    local latest = entries[#entries]
    local previous = latest and latest.editor == editor and latest.position

    for _, entry in ipairs(entries) do
      if entry.editor == editor and entry.position >= pos then
        local adjusted = inserted and entry.position + length or math.max(pos, entry.position - length)
        keepPosition(entry, editor, adjusted)
      end
    end
    if editor.applyingTextEdits or bit.band(modification, wxstc.wxSTC_PERFORMED_UNDO + wxstc.wxSTC_PERFORMED_REDO) ~= 0 then return end

    local time = ide:GetTime()
    local at = inserted and pos + length or pos
    if not selected and previous and time - latest.time <= 1
    and latest.line == editor:LineFromPosition(at)
    and previous >= pos - 1 and previous <= pos + (inserted and 1 or length + 1) then
      keepPosition(latest, editor, at)
      latest.time = time
    else
      selected = nil
      local entry = {path = document:GetFilePath(), time = time}
      keepPosition(entry, editor, at)
      entries[#entries + 1] = entry
      if #entries > 100 then remove(1) end
    end
  end,
  onEditorLoad = function(self, editor)
    local key = fileKey(ide:GetDocument(editor):GetFilePath())
    for index = #entries, 1, -1 do
      local entry = entries[index]
      if key and fileKey(entry.path) == key then
        attach(entry, editor)
      elseif entry.editor == editor then
        entry.editor = nil
        if not entry.path then remove(index) end
      end
    end
  end,
  onEditorSave = function(self, editor)
    local path = ide:GetDocument(editor):GetFilePath()
    for _, entry in ipairs(entries) do
      if entry.editor == editor then entry.path = path end
    end
  end,
  onEditorClose = function(self, editor)
    local path = ide:GetDocument(editor):GetFilePath()
    for index = #entries, 1, -1 do
      local entry = entries[index]
      if entry.editor == editor then
        entry.editor, entry.path = nil, path
        if not path then remove(index) end
      end
    end
  end,
})

local menu = ide:MakeMenu {
  {ID.GOTODEFINITION, TR("Go To Definition")..KSC(ID.GOTODEFINITION)},
  {},
  {ID.PREVIOUSEDIT, TR("Previous Edit Position")..KSC(ID.PREVIOUSEDIT)},
  {ID.NEXTEDIT, TR("Next Edit Position")..KSC(ID.NEXTEDIT)},
}
local _, searchIndex = ide:FindTopMenu("&Search")
ide:GetMenuBar():Insert(searchIndex + 1, menu, TR("&Navigate"))

frame:Connect(ID.GOTODEFINITION, wx.wxEVT_COMMAND_MENU_SELECTED, function()
  local editor = ide:GetEditor()
  if editor then ide:RerouteMenuCommand(editor, ID.GOTODEFINITION) end
end)
frame:Connect(ID.GOTODEFINITION, wx.wxEVT_UPDATE_UI, function(event)
  local editor = ide:GetEditor()
  local query = wx.wxUpdateUIEvent(ID.GOTODEFINITION)
  if editor then editor:GetEventHandler():ProcessEvent(query) end
  event:Enable(editor ~= nil and query:GetEnabled())
end)

for _, id in ipairs({ID.PREVIOUSEDIT, ID.NEXTEDIT}) do
  local direction = id == ID.PREVIOUSEDIT and -1 or 1
  frame:Connect(id, wx.wxEVT_COMMAND_MENU_SELECTED, function() navigate(direction) end)
  frame:Connect(id, wx.wxEVT_UPDATE_UI, function(event) event:Enable(candidate(direction) ~= nil) end)
end
