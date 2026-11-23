local pkg = ...
local unpack = table.unpack or unpack
local debugger = ide:GetDebugger()
-- start debugger server
debugger:Listen()
-- save a test file and then load it
local debugfile = MergeFullPath(wx.wxStandardPaths.Get():GetTempDir(), "debug.lua")
FileWrite(debugfile, "local a = 1+2\na = 2+3\na = 3+4\na = 4+5\na = 5+6")
ok(wx.wxFileExists(debugfile), "File created before starting debugging.")
local editor = ide:ActivateFile(debugfile)
editor:BreakpointToggle(4)

ide:GetMenuBar():Check(ID.CLEAROUTPUTENABLE, false)
local firstpid = ProjectDebug()

local commands = {
  {debugfile, 1, "Step"},
  {debugfile, 2, "RunTo", {editor, 4}},
  {debugfile, 4, "Run"},
  {debugfile, 5, "Restart"},
  {debugfile, 1, "Stop"},
}
local command = 1
local restarting, othereditor

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
    debugger[cmd](debugger, unpack(args or {}))
  end
end
pkg.onDebuggerClose = function()
  if restarting then return end
  local otherdoc = ide:IsValidCtrl(othereditor) and ide:GetDocument(othereditor)
  if otherdoc then otherdoc:Close() end
  local doc = ide:IsValidCtrl(editor) and ide:GetDocument(editor)
  if doc then doc:Close() end

  pkg.onDebuggerActivate = nil
  pkg.onDebuggerClose = nil
  pkg:report()
end
pkg.onAppClose = function() FileRemove(debugfile) end
