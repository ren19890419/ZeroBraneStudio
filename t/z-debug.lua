local pkg = ...
local unpack = table.unpack or unpack
-- save a test file and then load it
local debugfile = MergeFullPath(wx.wxStandardPaths.Get():GetTempDir(), "debug.lua")
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
}, "\n"))
pkg.onAppClose = function() FileRemove(debugfile) end
ok(wx.wxFileExists(debugfile), "File created before starting debugging.")
local editor = ide:ActivateFile(debugfile)
local breakpointLine = 10
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
local function stepInto()
  frame:ProcessEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED, ID.STEP))
end
local function runToCursor(line)
  ide:GetDocument(editor):SetActive()
  editor:GotoLine(line - 1)
  frame:ProcessEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED, ID.RUNTO))
end
stepInto()
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
  {debugfile, 5, "Stop"},
}
local command = 1
local restarting, startingRunTo, othereditor

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
    debugger:EvalAsync("a == nil", function(val)
        is(val, "true", "Step Into stops before executing the first statement.")
      end)
    debugger:Wait()
    debugger:EvalAsync("1+2", function(val)
        is(val, "3", "Asynchronous expression evaluation in debugger returns expected result.")
      end)
    debugger:Wait()
  end
  command = command + 1
  if cmd == "Restart" then
    local item = ID.RESTARTDEBUG and ide:FindMenuItem(ID.RESTARTDEBUG)
    ok(item ~= nil, "Restart Debugging is available from the Project menu.")
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
      ide:GetMainFrame():ProcessEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED, ID.RESTARTDEBUG))
    end)
  else
    if restarting then
      restarting = false
      local pid = ide:GetLaunchedProcess()
      ok(pid and pid ~= firstpid, "Restart starts a new process for the original entry file.")
      ok(not wx.wxProcess.Exists(firstpid), "The old debug process exits before the new session starts.")
    end
    if cmd == "Step" then
      stepInto()
    elseif cmd == "Over" then
      frame:ProcessEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED, ID.STEPOVER))
    elseif cmd == "RunTo" then
      runToCursor(unpack(args))
    elseif cmd == "StartRunTo" then
      startingRunTo = true
      ide:GetOutput():AfterProcessExit(ide:GetLaunchedProcess(), function()
        startingRunTo = false
        ide.config.debugger.runonstart = false
        runToCursor(5)
        local started = ide:GetLaunchedProcess() ~= nil
        ok(started, "Run To Cursor launches a new debug process.")
        if started then
          editor:GotoLine(breakpointLine - 1)
        else
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
  if restarting or startingRunTo then return end
  local otherdoc = ide:IsValidCtrl(othereditor) and ide:GetDocument(othereditor)
  if otherdoc then otherdoc:Close() end
  local doc = ide:IsValidCtrl(editor) and ide:GetDocument(editor)
  if doc then doc:Close() end

  pkg.onDebuggerActivate = nil
  pkg.onDebuggerClose = nil
  ide.config.debugger.runonstart = runonstart
  pkg:report()
end
