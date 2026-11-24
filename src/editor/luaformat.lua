local ide = ide
local client = ide:GetPackage("core.luals")
local frame = ide:GetMainFrame()

local function mapPosition(pos, edits, afterInsertion)
  local shift = 0
  for _, edit in ipairs(edits) do
    if pos < edit.start or pos == edit.start and edit.start == edit.finish and not afterInsertion then break end
    if pos < edit.finish then
      return edit.start + shift + (afterInsertion and #edit.text or 0)
    end
    shift = shift + #edit.text - (edit.finish - edit.start)
  end
  return pos + shift
end

local function format(editor, selection)
  if not client:Format(editor, selection, function(edits, err)
    if err then ide:SetStatusFor(err, 5); return end
    if #edits == 0 then ide:SetStatusFor(TR("LuaLS returned no formatting changes.")); return end

    local anchor, caret = editor:GetAnchor(), editor:GetCurrentPos()
    local restoreSelection = not editor:SelectionIsRectangle()
      and (ide.wxver < "2.9.5" or editor:GetSelections() == 1)
    local first = math.min(anchor, caret)
    local startsAtLine = first == editor:PositionFromLine(editor:LineFromPosition(first))
    local ok, problem = client:ApplyTextEdits(editor, edits)
    if not ok then
      ide:Print(problem)
      ide:SetStatusFor(TR("Could not apply Lua formatting."), 5)
      return
    end
    if restoreSelection then
      editor:SetCurrentPos(mapPosition(caret, edits, caret >= anchor or not startsAtLine))
      editor:SetAnchor(mapPosition(anchor, edits, anchor >= caret or not startsAtLine))
    end
    ide:SetStatusFor(selection and TR("Formatted Lua selection.") or TR("Formatted Lua file."))
  end) then return end
  ide:SetStatusFor(TR("Formatting Lua code..."), 5)
end

local function currentEditor() return ide:GetEditorWithFocus() or ide:GetEditor() end
local menu = ide:FindMenuItem(ID.SOURCE):GetSubMenu()
local function addCommand(id, label, shortcut, selection)
  if not ide.config.keymap[id] and not ide:GetHotKey(shortcut) then ide.config.keymap[id] = shortcut end
  menu:Append(id, TR(label)..KSC(id))
  frame:Connect(id, wx.wxEVT_COMMAND_MENU_SELECTED, function() format(currentEditor(), selection) end)
  frame:Connect(id, wx.wxEVT_UPDATE_UI, function(event) event:Enable(client:CanFormat(currentEditor(), selection)) end)
end

menu:AppendSeparator()
addCommand(ID("edit.luals.formatfile"), "Format Lua File", "Alt-Shift-F", false)
addCommand(ID("edit.luals.formatselection"), "Format Lua Selection", "Alt-Shift-L", true)
