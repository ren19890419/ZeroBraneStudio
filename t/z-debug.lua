local pkg = ...
local unpack = table.unpack or unpack
local mobdebug = require "mobdebug"
local function breakpointRequest(answer)
  local peer = {send = function(self, data) self.data = data end, receive = function() return answer end}
  local _, _, err = mobdebug.handle("setx "..mobdebug.line({
    file = "breakpoint options.lua", line = 3, condition = "index == 2", hitCount = 2,
    log = "index={index}",
  }, {comment = false}), peer, {verbose = false})
  return peer.data, err
end
local request = breakpointRequest("200 OK")
ok(request and request:match("^SETX ") and request:find("breakpoint options.lua", 1, true),
  "Advanced breakpoint requests preserve the path and options.")
local _, unsupported = breakpointRequest("400 Bad Request")
ok(unsupported and unsupported:find("does not support", 1, true),
  "Older debug clients report unsupported breakpoint settings.")
-- save a test file and then load it
local tempFile = wx.wxFile()
local tempPath = wx.wxFileName.CreateTempFileName("zbs-debug", tempFile)
tempFile:Close()
FileRemove(tempPath)
local debugfile = tempPath..".lua"
local fields = {"count = 10", '[1] = 31', '[false] = 25', '["a.b"] = 12', '["end"] = 15'}
for index = 1, 45 do fields[#fields + 1] = ("field%02d = %d"):format(index, index) end
FileWrite(debugfile, table.concat({
  "#!/usr/bin/env lua",
  "-- Debugger entry",
  "",
  "local a, data, stable = 1+2, {handle = io.stdout, item = {" .. table.concat(fields, ", ") .. "}}, 42",
  "a = 2+3; data.item.count = 11; data.item.added = true; data.item.field20 = 99",
  "local function add(a)",
  "  return a + 1",
  "end; data.item.field20 = nil",
  "a = a + add(90) - 90",
  "a = 5+6",
  "a = a + 1",
  "for i = 1, 5 do",
  "  a = a + i",
  "end",
}, "\n"))
pkg.onAppClose = function() FileRemove(debugfile) end
ok(wx.wxFileExists(debugfile), "File created before starting debugging.")
local editor = ide:ActivateFile(debugfile)
local breakpointLine = 10
local nextBreakpointLine = 13
editor:BreakpointToggle(breakpointLine - 1, true)
local debugger = ide:GetDebugger()
local logpointLine = 9
editor:BreakpointToggle(logpointLine - 1, true)
debugger:SetBreakpointOptions(editor, logpointLine - 1, {log = "Advanced breakpoint: a={a}"})
editor:BreakpointToggle(3, true)
debugger:SetBreakpointOptions(editor, 3, {log = "Entry breakpoint output"})
ok(debugger:GetBreakpointOptions(editor, logpointLine - 1) ~= nil, "The logpoint is attached to its breakpoint marker.")
editor:InsertText(0, "-- marker movement\n")
ok(debugger:GetBreakpointOptions(editor, logpointLine) ~= nil, "The logpoint follows its marker after inserting a line.")
editor:Undo()

ide:GetMenuBar():Check(ID.CLEAROUTPUTENABLE, false)
local runonstart = ide.config.debugger.runonstart
ide.config.debugger.runonstart = true
local frame = ide:GetMainFrame()
local function isEnabled(id)
  local event = wx.wxUpdateUIEvent(id)
  frame:ProcessEvent(event)
  return event:GetEnabled()
end
ok(isEnabled(ID.STEP), "Step Into is enabled before debugging starts.")
ok(isEnabled(ID.STEPOVER), "Step Over is enabled before debugging starts.")
ok(isEnabled(ID.RUNTO), "Run To Cursor is enabled before debugging starts.")
editor:GotoLine(logpointLine - 1)
ok(isEnabled(ID.BREAKPOINTOPTIONS), "Breakpoint Settings is enabled on an existing breakpoint.")
editor:GotoLine(0)
local function dispatch(id)
  frame:ProcessEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED, id))
end
local function runToCursor(line)
  ide:GetDocument(editor):SetActive()
  editor:GotoLine(line - 1)
  dispatch(ID.RUNTO)
end
local function localIsRed(locals, row, column)
  local colour = locals:GetCellTextColour(row, column or 1)
  return colour:Red() > colour:Green() and colour:Red() > colour:Blue()
end
local function findLocalRow(locals, name)
  for row = 0, locals:GetNumberRows() - 1 do
    local label = locals:GetCellValue(row, 0):gsub("^%s*", ""):gsub("^▾ ", ""):gsub("^▸ ", "")
    if label == name then return row end
  end
end
local function localCellY(locals, row)
  local rect = locals:BlockToDeviceRect(wx.wxGridCellCoords(row, 0), wx.wxGridCellCoords(row, 2))
  if rect:GetHeight() > 0 then return rect:GetY() end
end
local function scrollLocals(locals, axis, position)
  local event = wx.wxScrollWinEvent(wx.wxEVT_SCROLLWIN_THUMBTRACK, position, axis)
  event:SetEventObject(locals)
  locals:GetEventHandler():ProcessEvent(event)
end
local oldClient = {send = function() end, receive = function() return "400 Bad Request" end}
local _, _, frameError = require("mobdebug").handle("evalframe a -- {stack = 2}", oldClient, {verbose = false})
is(frameError, "The debug client does not support evaluating the selected stack frame.",
  "An older client reports unsupported caller-frame evaluation.")
dispatch(ID.STEP)
local firstpid = ide:GetLaunchedProcess()
ok(firstpid ~= nil, "Step Into launches a debug process.")
if not firstpid then
  ide.config.debugger.runonstart = runonstart
  pkg.onIdleOnce = function() pkg:report() end
  return
end

local commands = {
  {debugfile, 4, "Step"},
  {debugfile, 5, "Over"},
  {debugfile, 8, "RunTo", {9}},
  {debugfile, 9, "Step"},
  {debugfile, 7, "WatchFrames"},
  {debugfile, breakpointLine, "Restart"},
  {debugfile, breakpointLine, "StartRunTo"},
  {debugfile, 5, "StartF5"},
  {debugfile, breakpointLine, "Continue"},
  {debugfile, nextBreakpointLine, "Stop"},
}
local command = 1
local restarting, startingDebug, othereditor
local inspectedRow, inspectedY, inspectedUnit, savedViewX

-- wait for the connection to be initiated
pkg.onDebuggerActivate = function(self, debugger, file, line)
  if not commands[command] then
    debugger:Step()
    return
  end
  local afile, aline, cmd, args = unpack(commands[command])
  ok(wx.wxFileName(file):SameAs(wx.wxFileName(afile)), "Filename is reported as expected after debugger activation ("..command.."/"..#commands..").")
  is(line, aline, "Line number is reported as expected after debugger activation ("..command.."/"..#commands..").")
  if debugger:IsRunning() then debugger:Wait() end
  if command == 4 then
    ok(debugger:GetBreakpointOptions(editor, logpointLine - 1) ~= nil,
      "Run To Cursor at a logpoint keeps the breakpoint settings.")
    ok(ide:GetOutput():GetText():find("Advanced breakpoint: a=", 1, true) ~= nil,
      "An interpolated logpoint message appears in the Output window.")
  elseif command == 9 then
    ok(ide:GetOutput():GetText():find("Entry breakpoint output", 1, true) ~= nil,
      "F5 reports an entry logpoint without stopping there.")
  elseif command == 10 then
    debugger:EvalAsync("i", function(value)
      is(value, "3", "The hit threshold counts only visits that pass the condition.")
    end)
    debugger:Wait()
  end
  if command == 1 then
    ok(isEnabled(ID.STARTDEBUG) and isEnabled(ID.STEP) and isEnabled(ID.RUNTO)
      and isEnabled(ID.STOPDEBUG) and not isEnabled(ID.BREAK), "Debug actions reflect a paused session.")
    local debugMenu = ide:FindTopMenu("&Debug")
    if debugMenu then
      is(debugMenu:FindItem(ID.STARTDEBUG):GetItemLabelText(), wx.wxMenuItem.GetLabelText(TR("Co&ntinue")),
        "Debug menu shows Continue when the debugger is attached.")
      if ID.DEBUGWATCHWINDOW and ID.DEBUGCALLSTACK then
        ok(isEnabled(ID.DEBUGWATCHWINDOW) and isEnabled(ID.DEBUGCALLSTACK),
          "Debug menu can open Watch Window and Call Stack when the debugger is attached.")
      end
    end
    debugger:EvalAsync("a == nil", function(val)
        is(val, "true", "Step Into stops before executing the first statement.")
      end)
    debugger:Wait()
    debugger:EvalAsync("1+2", function(val)
        is(val, "3", "Asynchronous expression evaluation in debugger returns expected result.")
      end)
    debugger:Wait()
  elseif command == 2 and ID.DEBUGLOCALS then
    dispatch(ID.DEBUGLOCALS)
    debugger:Wait()
    local locals = ide:GetLocals()
    local grid = locals:GetClassInfo():GetClassName() == "wxGrid"
    ok(grid and locals:GetNumberCols() == 3
      and locals:GetColLabelValue(0) == TR("Name") and locals:GetColLabelValue(1) == TR("Value")
      and locals:GetColLabelValue(2) == TR("Type"), "Locals has Name, Value and Type columns.")
    if grid then
      is(locals:GetCellValue(0, 0), "a", "Locals shows the variable name.")
      is(locals:GetCellValue(0, 1), "3", "Locals shows the paused variable value.")
      is(locals:GetCellValue(0, 2), "number", "Locals shows the Lua type.")
      ok(not localIsRed(locals, 0), "A newly visible local starts without a change highlight.")
      locals:ToggleLocal(1)
      is(locals:GetCellValue(2, 2), "userdata", "Expanded fields show their original Lua type.")
      locals:ToggleLocal(1)
      local prompt = ide.GetTextFromUser
      local prompted = false
      ide.GetTextFromUser = function() prompted = true end
      local function editValue(column)
        locals:EditLocal(0, column)
        local input = locals:FindFocus()
        if input and input:GetParent() and input:GetParent():GetId() == locals:GetGridWindow():GetId()
        and input:GetClassInfo():GetClassName() == "wxTextCtrl" then
          return input:DynamicCast("wxTextCtrl")
        end
      end
      ok(not editValue(0) and not editValue(2), "The Name and Type columns are read-only.")
      local input = editValue(1)
      ok(not prompted and input ~= nil and input:GetValue() == "3", "Activating a local opens its value inline.")
      if input then
        local cell = wx.wxGridCellCoords(0, 1)
        local rect = locals:BlockToDeviceRect(cell, cell)
        ok(input:GetPosition():GetX() == rect:GetX() and input:GetPosition():GetY() == rect:GetY()
          and input:GetSize():GetWidth() == rect:GetWidth(), "The editor is contained in the Value cell.")
        input:SetValue("100")
        input:ProcessEvent(wx.wxFocusEvent(wx.wxEVT_KILL_FOCUS))
        ok(not input:IsShown() and locals:GetCellValue(0, 1) == "3", "Leaving the inline editor discards its draft.")
        input = editValue(1)
        ok(input ~= nil, "The local value can be edited again.")
        if input then
          local function enter()
            input:ProcessEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_TEXT_ENTER, input:GetId()))
            debugger:Wait()
          end
          input:SetValue("a +")
          enter()
          ok(input:IsShown() and input:IsEditable() and input:GetValue() == "a +",
            "An invalid expression stays in the inline editor for correction.")
          input:SetValue('"7"')
          enter()
          is(locals:GetCellValue(0, 1), '"7"', "Enter commits the local edit.")
          is(locals:GetCellValue(0, 2), "string", "Editing a value refreshes its type.")
        end
      end
      ide.GetTextFromUser = prompt
      local data = findLocalRow(locals, "data")
      if data then locals:ToggleLocal(data) end
      local item = findLocalRow(locals, "item")
      if item then locals:ToggleLocal(item) end
      local count = findLocalRow(locals, "count")
      ok(count ~= nil and locals:GetCellValue(count, 1) == "10", "The nested table is expanded before stepping.")
      inspectedRow = findLocalRow(locals, "field20")
      if inspectedRow then
        local rect = locals:CellToRect(inspectedRow, 1)
        locals:SetColSize(2, locals:GetColSize(2) + locals:GetClientSize():GetWidth())
        locals:SetGridCursor(inspectedRow, 1)
        scrollLocals(locals, wx.wxHORIZONTAL, 1)
        scrollLocals(locals, wx.wxVERTICAL, 1)
        local unit = locals:CellToRect(2, 1):GetY() - (localCellY(locals, 2) or 0)
        if unit > 0 then
          scrollLocals(locals, wx.wxVERTICAL, math.floor((rect:GetY() - 2 * rect:GetHeight()) / unit))
        end
        local scrollX, scrollY = locals:GetScrollPos(wx.wxHORIZONTAL), locals:GetScrollPos(wx.wxVERTICAL)
        savedViewX, inspectedY, inspectedUnit = scrollX, localCellY(locals, inspectedRow), unit
        ok(scrollX > 0 and scrollY > 0 and inspectedY ~= nil, "The selected field is in a scrolled Locals viewport.")
      end
    end
  elseif command == 3 and ID.DEBUGLOCALS then
    dispatch(ID.DEBUGLOCALS)
    debugger:Wait()
    local locals = ide:GetLocals()
    ok(locals:GetCellValue(0, 1) == "5" and localIsRed(locals, 0),
      "Step Over highlights a changed local value in red.")
    local stable = findLocalRow(locals, "stable")
    ok(stable ~= nil and not localIsRed(locals, 0, 0) and not localIsRed(locals, 0, 2)
      and not localIsRed(locals, stable),
      "Only the Value cell of each changed local is highlighted.")
    ok(localIsRed(locals, 1), "Changes to a nested field highlight its parent table.")
    local count = findLocalRow(locals, "count")
    ok(count ~= nil and locals:GetCellValue(count, 1) == "11" and localIsRed(locals, count),
      "Step Over keeps nested tables expanded and shows the changed field in red.")
    local inspected = findLocalRow(locals, "field20")
    ok(inspected ~= nil and inspected ~= inspectedRow and locals:GetCellValue(inspected, 1) == "99"
      and locals:GetGridCursorRow() == inspected and locals:GetGridCursorCol() == 1,
      "Step Over keeps the same nested Value cell selected when its row moves.")
    local y = inspected and localCellY(locals, inspected)
    ok(y ~= nil and inspectedY ~= nil and math.abs(y - inspectedY) < inspectedUnit
      and locals:GetScrollPos(wx.wxHORIZONTAL) == savedViewX, "Step Over restores the Locals scroll position.")
    dispatch(ID.DEBUGLOCALS)
    debugger:Wait()
    ok(localIsRed(locals, 0), "Refreshing Locals at the same pause keeps its highlight.")
    count = findLocalRow(locals, "count")
    ok(count ~= nil and localIsRed(locals, count), "Refreshing Locals keeps expanded fields visible.")
  elseif command == 4 and ID.DEBUGLOCALS then
    dispatch(ID.DEBUGLOCALS)
    debugger:Wait()
    local locals = ide:GetLocals()
    ok(locals:GetCellValue(0, 1) == "5" and not localIsRed(locals, 0) and not localIsRed(locals, 1),
      "At the next pause unchanged values return to their normal colour.")
    local count = findLocalRow(locals, "count")
    ok(count ~= nil and locals:GetCellValue(count, 1) == "11" and not localIsRed(locals, count),
      "An unchanged field stays visible in its expanded table at the next pause.")
    local item = findLocalRow(locals, "item")
    ok(item ~= nil and not findLocalRow(locals, "field20") and locals:GetGridCursorRow() == item,
      "Removing the selected field selects its remaining parent.")
    if item then locals:ToggleLocal(item) end
  elseif cmd == "WatchFrames" then
    dispatch(ID.DEBUGWATCHWINDOW)
    debugger:Wait()
    local watch = ide:GetWatch()
    local value = ide:AddWatch("a")
    local expression = ide:AddWatch("a * 2")
    debugger:Wait()
    is(watch:GetItemText(value), "a = 90", "Watch evaluates in the innermost frame initially.")
    dispatch(ID.DEBUGCALLSTACK)
    debugger:Wait()
    local stack = ide:GetStack()
    local inner = stack:GetFirstChild(stack:GetRootItem())
    local caller = stack:GetNextSibling(inner)
    ok(caller:IsOk(), "The call stack contains the caller of the paused function.")
    if caller:IsOk() then
      local function selectFrame(item)
        stack:SelectItem(item)
        ide:ActivateNotebookPage(watch)
        watch:SetFocus()
        debugger:Wait()
      end
      selectFrame(caller)
      is(watch:GetItemText(value), "a = 5", "Selecting the caller automatically refreshes its shadowed local in Watch.")
      is(watch:GetItemText(expression), "a * 2 = 10", "Watch reevaluates full expressions in the selected caller.")
      selectFrame(inner)
      is(watch:GetItemText(value), "a = 90", "Returning to the innermost frame refreshes Watch again.")
    end
  elseif cmd == "Restart" and ID.DEBUGLOCALS then
    dispatch(ID.DEBUGLOCALS)
    debugger:Wait()
    local locals = ide:GetLocals()
    local item = findLocalRow(locals, "item")
    ok(item ~= nil and not findLocalRow(locals, "count"), "A manually collapsed table stays closed after stepping.")
    if item then locals:ToggleLocal(item) end
    ok(ID.ADDLOCALTOWATCH ~= nil, "Locals provides an Add to Watch menu command.")
    if ID.ADDLOCALTOWATCH then
      local watch = ide:GetWatch()
      local function addWatch(name)
        dispatch(ID.DEBUGLOCALS)
        debugger:Wait()
        local row = findLocalRow(locals, name)
        if row == nil then return end
        locals:SetGridCursor(row, 1)
        locals:ProcessEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED, ID.ADDLOCALTOWATCH))
        debugger:Wait()
        local selected = watch:GetSelection()
        return selected:IsOk() and watch:GetItemText(selected) or nil
      end
      is(addWatch("a"), "a = 6", "The Locals command adds a variable and evaluates it in Watch.")
      is(addWatch("count"), "data.item.count = 11", "The Locals command adds a nested field using its full path.")
      is(addWatch("1"), "data.item[1] = 31", "The Locals command preserves a numeric table key.")
      is(addWatch("false"), "data.item[false] = 25", "The Locals command preserves a boolean table key.")
      is(addWatch("a.b"), 'data.item["a.b"] = 12', "The Locals command quotes a key containing punctuation.")
      is(addWatch("end"), 'data.item["end"] = 15', "The Locals command quotes a Lua keyword used as a key.")
      local before = watch:GetChildrenCount(watch:GetRootItem(), false)
      is(addWatch("a"), "a = 6", "Adding an existing watch selects that entry.")
      is(watch:GetChildrenCount(watch:GetRootItem(), false), before, "Adding an existing watch does not duplicate it.")
      ok(ide:IsWindowShown(watch), "The Watch window is displayed after adding an expression.")
    end
  elseif cmd == "StartRunTo" and ID.DEBUGLOCALS then
    dispatch(ID.DEBUGLOCALS)
    debugger:Wait()
    local locals = ide:GetLocals()
    ok(locals:GetCellValue(0, 1) == "6" and not localIsRed(locals, 0),
      "Restarting debugging clears local change history.")
    ok(not findLocalRow(locals, "item"), "A fresh debugging session starts with its tables collapsed.")
  end
  command = command + 1
  if cmd == "Restart" then
    local item = ID.RESTARTDEBUG and ide:FindMenuItem(ID.RESTARTDEBUG)
    ok(item ~= nil, "Restart Debugging is available from the menu bar.")
    if not item then
      debugger:Stop()
      return
    end
    local shortcut = wx.wxAcceleratorEntry()
    shortcut:FromString("Ctrl-Shift-F5")
    local accel = item:GetAccel()
    ok(accel and accel:GetFlags() == shortcut:GetFlags() and accel:GetKeyCode() == shortcut:GetKeyCode(),
      "Ctrl+Shift+F5 invokes Restart Debugging.")
    restarting = true
    ide:DoWhenIdle(function()
      othereditor = ide:LoadFile("t/test.lua")
      dispatch(ID.RESTARTDEBUG)
    end)
  else
    if restarting then
      restarting = false
      local pid = ide:GetLaunchedProcess()
      ok(pid and pid ~= firstpid, "Restart starts a new process for the original entry file.")
      ok(not wx.wxProcess.Exists(firstpid), "The old debug process exits before the new session starts.")
    end
    if cmd == "Step" then
      dispatch(ID.STEP)
    elseif cmd == "Over" then
      dispatch(ID.STEPOVER)
    elseif cmd == "RunTo" then
      runToCursor(unpack(args))
    elseif cmd == "WatchFrames" then
      debugger:Run()
    elseif cmd == "Continue" then
      dispatch(ID.STARTDEBUG)
    elseif cmd == "StartRunTo" or cmd == "StartF5" then
      startingDebug = true
      ide:GetOutput():AfterProcessExit(ide:GetLaunchedProcess(), function()
        startingDebug = false
        ide.config.debugger.runonstart = false
        if cmd == "StartRunTo" then
          runToCursor(5)
        else
          editor:BreakpointToggle(nextBreakpointLine - 1, true)
          ide:GetDebugger():SetBreakpointOptions(editor, nextBreakpointLine - 1, {condition = "i >= 2", hitCount = 2})
          dispatch(ID.STARTDEBUG)
        end
        local started = ide:GetLaunchedProcess() ~= nil
        ok(started, (cmd == "StartRunTo" and "Run To Cursor" or "Start Debugging").." launches a new debug process.")
        if started and cmd == "StartRunTo" then
          editor:GotoLine(breakpointLine - 1)
        elseif not started then
          pkg.onDebuggerClose()
        end
      end)
      debugger:Stop()
    else
      debugger[cmd](debugger, unpack(args or {}))
    end
  end
end
pkg.onDebuggerClose = function()
  if restarting or startingDebug then return end
  local otherdoc = ide:IsValidCtrl(othereditor) and ide:GetDocument(othereditor)
  if otherdoc then otherdoc:Close() end
  local doc = ide:IsValidCtrl(editor) and ide:GetDocument(editor)
  if doc then doc:Close() end

  pkg.onDebuggerActivate = nil
  pkg.onDebuggerClose = nil
  ide.config.debugger.runonstart = runonstart
  pkg:report()
end
