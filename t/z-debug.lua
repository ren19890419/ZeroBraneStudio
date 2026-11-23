local pkg = ...
local unpack = table.unpack or unpack
-- save a test file and then load it
local tempFile = wx.wxFile()
local tempPath = wx.wxFileName.CreateTempFileName("zbs-debug", tempFile)
tempFile:Close()
FileRemove(tempPath)
local debugfile = tempPath..".lua"
FileWrite(debugfile, table.concat({
  "#!/usr/bin/env lua",
  "-- Debugger entry",
  "",
  "local a = 1+2",
  "a = 2+3",
  "local function add()",
  "  a = a + 1",
  "end",
  "add()",
  "a = 5+6",
  "a = a + 1",
  "a = a + 1",
}, "\n"))
pkg.onAppClose = function() FileRemove(debugfile) end
ok(wx.wxFileExists(debugfile), "File created before starting debugging.")
local editor = ide:ActivateFile(debugfile)
local breakpointLine = 10
local nextBreakpointLine = 12
editor:BreakpointToggle(breakpointLine - 1, true)

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
local function dispatch(id)
  frame:ProcessEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED, id))
end
local function runToCursor(line)
  ide:GetDocument(editor):SetActive()
  editor:GotoLine(line - 1)
  dispatch(ID.RUNTO)
end
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
  {debugfile, 5, "RunTo", {9}},
  {debugfile, 9, "Over"},
  {debugfile, breakpointLine, "Restart"},
  {debugfile, breakpointLine, "StartRunTo"},
  {debugfile, 5, "StartF5"},
  {debugfile, breakpointLine, "Continue"},
  {debugfile, nextBreakpointLine, "Stop"},
}
local command = 1
local restarting, startingDebug, othereditor

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
    local item = locals:GetFirstChild(locals:GetRootItem())
    ok(item:IsOk() and locals:GetItemText(item) == "a = 3",
      "Locals shows the paused frame's variable value.")
    if item:IsOk() then
      local prompt = ide.GetTextFromUser
      local prompted = false
      ide.GetTextFromUser = function() prompted = true end
      local function editValue()
        locals:SelectItem(item)
        local event = wx.wxTreeEvent(wx.wxEVT_COMMAND_TREE_ITEM_ACTIVATED, locals:GetId())
        event:SetEventObject(locals)
        locals:ProcessEvent(event)
        local input = locals:FindFocus()
        if input and input:GetParent() and input:GetParent():GetId() == locals:GetId()
        and input:GetClassInfo():GetClassName() == "wxTextCtrl" then
          return input:DynamicCast("wxTextCtrl")
        end
      end
      local input = editValue()
      ok(not prompted and input ~= nil and input:GetValue() == "3", "Activating a local opens its value inline.")
      if input then
        local rect = wx.wxRect()
        local labelWidth = locals:GetTextExtent("a = ")
        ok(locals:GetBoundingRect(item, rect, true)
          and input:GetPosition():GetX() == rect:GetX() + labelWidth
          and input:GetPosition():GetY() == rect:GetY(), "The editor starts at the local value.")
        input:SetValue("100")
        input:ProcessEvent(wx.wxFocusEvent(wx.wxEVT_KILL_FOCUS))
        ok(not input:IsShown() and locals:GetItemText(item) == "a = 3", "Leaving the inline editor discards its draft.")
        input = editValue()
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
          input:SetValue("a + 4")
          enter()
          local updated = locals:GetFirstChild(locals:GetRootItem())
          ok(updated:IsOk() and locals:GetItemText(updated) == "a = 7", "Enter commits the local edit.")
        end
      end
      ide.GetTextFromUser = prompt
    end
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
