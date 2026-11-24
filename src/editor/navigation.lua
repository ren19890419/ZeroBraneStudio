local ide = ide
local frame = ide:GetMainFrame()
local entries, selected = {}, nil
local jumps, jumpIndex = {}, 0
local histories = {entries, jumps}
local historyLimit = 100
local menuLimit = 20
local previewBytes = 96

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

local function newLocation(editor, pos)
  local entry = {path = ide:GetDocument(editor):GetFilePath()}
  keepPosition(entry, editor, pos)
  return entry
end

local function previewCode(entry)
  local editor = entry.editor
  local first = editor:PositionFromLine(entry.line)
  local last = editor:GetLineEndPosition(entry.line)
  local start = first
  -- Keep the jump in view on long lines while bounding the text read for a menu row.
  if last - first > previewBytes and entry.position - first >= previewBytes then
    start = math.min(entry.position - previewBytes / 2, last - previewBytes)
    start = editor:PositionBefore(editor:PositionAfter(start))
  end
  local finish = math.min(last, start + previewBytes)
  if finish < last then finish = editor:PositionBefore(editor:PositionAfter(finish)) end
  local text = editor:GetTextRangeDyn(start, finish):gsub("%c", " "):match("^%s*(.-)%s*$")
  if text == "" then return end
  return (start > first and "…" or "")..FixUTF8(text, "\239\191\189")..(finish < last and "…" or "")
end

local function newJump(editor, pos)
  local entry = newLocation(editor, pos)
  entry.preview = previewCode(entry)
  return entry
end

local function attach(entry, editor)
  local line = math.min(entry.line, editor:GetLineCount() - 1)
  keepPosition(entry, editor, editor:FindColumn(line, entry.column))
end

local function removeEdit(index)
  if entries[index] == selected then selected = nil end
  table.remove(entries, index)
end

local function editCandidate(direction)
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

local function visit(entry)
  local editor = entry.editor
  local doc = editor and ide:IsValidCtrl(editor) and ide:GetDocument(editor)
  if doc then
    doc:SetActive()
  else
    editor = entry.path and ide:LoadFile(entry.path, nil, true)
    if not editor then return false end
    if entry.editor ~= editor then attach(entry, editor) end
  end
  editor:GotoPosDelayed(entry.position)
  return true
end

local function navigateEdit(direction)
  local index = editCandidate(direction)
  while index do
    local entry = entries[index]
    if visit(entry) then
      selected = entry
      return
    end
    removeEdit(index)
    index = editCandidate(direction)
  end
end

local function jumpCandidate(direction, from)
  local index = (from or jumpIndex) + direction
  while jumps[index] do
    local entry = jumps[index]
    if entry.editor or entry.path then return index end
    index = index + direction
  end
end

local function jumpTo(index, entry)
  if not entry or jumps[index] ~= entry then return false end
  if visit(entry) then
    jumpIndex = index
    return true
  end
  -- The file has disappeared. Leave the other jump indices in place.
  entry.editor, entry.path = nil, nil
  return false
end

local function navigateJump(direction)
  local index = jumpCandidate(direction)
  while index do
    if jumpTo(index, jumps[index]) then return end
    index = jumpCandidate(direction, index)
  end
end

local function createJumpHistoryMenu(direction)
  local locations, names = {}, {}
  local index = jumpCandidate(direction)
  while index and #locations < menuLimit do
    local entry = jumps[index]
    local doc = entry.editor and ide:IsValidCtrl(entry.editor) and ide:GetDocument(entry.editor)
    local path = doc and doc:GetFilePath() or entry.path
    if path or doc then
      local name = path and wx.wxFileName(path):GetFullName() or doc:GetFileName() or ide:GetDefaultFileName()
      local key, identity = fileKey(name), fileKey(path) or entry.editor
      local sameName = names[key]
      if sameName then
        sameName.ambiguous = sameName.ambiguous or sameName.identity ~= identity
      else
        names[key] = {identity = identity}
      end
      local preview = entry.preview
      if doc then preview = previewCode(entry) end
      locations[#locations + 1] = {index = index, entry = entry, path = path, name = name, key = key,
        preview = preview}
    end
    index = jumpCandidate(direction, index)
  end
  if #locations == 0 then return end

  local menu = wx.wxMenu()
  local project = ide:GetProject()
  for row, location in ipairs(locations) do
    local name = location.name
    if location.path and names[location.key].ambiguous then
      local file = wx.wxFileName(location.path)
      if project then file:MakeRelativeTo(project) end
      name = file:GetFullPath()
    end
    local id = ID("navigation.jump.history."..row)
    local label = ("%s:%d"):format(name:gsub("[\t\r\n]", " "), location.entry.line + 1)
    if location.preview then label = label.."    "..location.preview end
    menu:Append(id, (label:gsub("&", "&&")), location.path or "")
    menu:Connect(id, wx.wxEVT_COMMAND_MENU_SELECTED, function()
      if not jumpTo(location.index, location.entry) then
        ide:SetStatusFor(TR("This jump location is no longer available."))
      end
    end)
  end
  return menu
end

local navigation = ide:AddPackage("core.navigation", {
  CreateJumpHistoryMenu = function(self, direction) return createJumpHistoryMenu(direction) end,
  RecordJump = function(self, editor, position, target, targetPosition)
    if editor == target and position == targetPosition then return end
    for index = #jumps, jumpIndex + 1, -1 do jumps[index] = nil end
    local current = jumps[jumpIndex]
    if not current or current.editor ~= editor or current.position ~= position then
      jumps[#jumps + 1] = newJump(editor, position)
    end
    jumps[#jumps + 1] = newJump(target, targetPosition)
    while #jumps > historyLimit do table.remove(jumps, 1) end
    jumpIndex = #jumps
  end,
  onEditorChange = function(self, editor, pos, length, inserted, modification)
    if not pos or length == 0 or editor.loadingFile then return end
    local document = ide:GetDocument(editor)
    if not document then return end
    local latest = entries[#entries]
    local previous = latest and latest.editor == editor and latest.position

    for _, history in ipairs(histories) do
      for _, entry in ipairs(history) do
        if entry.editor == editor and entry.position >= pos then
          local adjusted = inserted and entry.position + length or math.max(pos, entry.position - length)
          keepPosition(entry, editor, adjusted)
        end
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
      local entry = newLocation(editor, at)
      entry.time = time
      entries[#entries + 1] = entry
      if #entries > historyLimit then removeEdit(1) end
    end
  end,
  onEditorLoad = function(self, editor)
    local key = fileKey(ide:GetDocument(editor):GetFilePath())
    for _, history in ipairs(histories) do
      for index = #history, 1, -1 do
        local entry = history[index]
        if key and fileKey(entry.path) == key then
          attach(entry, editor)
        elseif entry.editor == editor then
          entry.editor = nil
          if history == entries and not entry.path then removeEdit(index) end
        end
      end
    end
  end,
  onEditorSave = function(self, editor)
    local path = ide:GetDocument(editor):GetFilePath()
    for _, history in ipairs(histories) do
      for _, entry in ipairs(history) do
        if entry.editor == editor then entry.path = path end
      end
    end
  end,
  onEditorClose = function(self, editor)
    local path = ide:GetDocument(editor):GetFilePath()
    for _, history in ipairs(histories) do
      for index = #history, 1, -1 do
        local entry = history[index]
        if entry.editor == editor then
          if history == jumps and path then entry.preview = previewCode(entry) end
          entry.editor, entry.path = nil, path
          if history == entries and not path then removeEdit(index) end
        end
      end
    end
  end,
})

local menu = ide:MakeMenu {
  {ID.GOTODEFINITION, TR("Go To Definition")..KSC(ID.GOTODEFINITION)},
  {},
  {ID.JUMPBACK, TR("Navigate Back")..KSC(ID.JUMPBACK)},
  {ID.JUMPFORWARD, TR("Navigate Forward")..KSC(ID.JUMPFORWARD)},
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
  frame:Connect(id, wx.wxEVT_COMMAND_MENU_SELECTED, function() navigateEdit(direction) end)
  frame:Connect(id, wx.wxEVT_UPDATE_UI, function(event) event:Enable(editCandidate(direction) ~= nil) end)
end

local toolbar = ide:GetToolBar()
for _, id in ipairs({ID.JUMPBACK, ID.JUMPFORWARD}) do
  local direction = id == ID.JUMPBACK and -1 or 1
  frame:Connect(id, wx.wxEVT_COMMAND_MENU_SELECTED, function() navigateJump(direction) end)
  frame:Connect(id, wx.wxEVT_UPDATE_UI, function(event) event:Enable(jumpCandidate(direction) ~= nil) end)
  toolbar:Connect(id, wxaui.wxEVT_COMMAND_AUITOOLBAR_TOOL_DROPDOWN, function(event)
    if not event:IsDropDownClicked() then event:Skip(); return end
    local popup = navigation:CreateJumpHistoryMenu(direction)
    if not popup then return end
    toolbar:PopupMenu(popup, toolbar:GetToolRect(id):GetBottomLeft())
    popup:delete()
  end)
end
