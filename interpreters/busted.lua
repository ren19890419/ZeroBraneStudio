-- Copyright 2011-13 Paul Kulchenko, ZeroBrane LLC

local pathcache
local win = ide.osname == "Windows"

local function getExecutable()
  if ide.config.path.busted then return ide.config.path.busted end
  if pathcache and wx.wxFileExists(pathcache) then return pathcache end
  local sep = win and ";" or ":"
  local default = win and GenerateProgramFilesPath('LuaRocks\\systree\\bin', sep)..sep or ""
  local paths = default..(os.getenv("PATH") or "")..sep..(os.getenv("HOME") and os.getenv("HOME").."/bin" or "")
  local names = win and {"busted.bat", "busted.cmd", "busted.exe"} or {"busted"}
  for path in paths:gmatch("[^"..sep.."]+") do
    for _, name in ipairs(names) do
      local match = GetFullPathIfExists(path, name)
      if match then pathcache = match; return match end
    end
  end
  return nil, paths
end

local function getRunOptions(self, default)
  local options = ide.config.busted and ide.config.busted.options or default or ""
  local params = self:GetCommandLineArg()
  if params and params ~= "" then options = options.." "..params end
  return options
end

return {
  name = "Busted",
  description = "Busted Lua testing",
  api = {"baselib"},
  GetExecutable = getExecutable,
  GetRunOptions = getRunOptions,
  frun = function(self,wfilename,rundebug)
    local busted, paths = getExecutable()
    if not busted then
      ide:Print("Can't find busted executable in any of the folders in PATH: "..paths:gsub(win and ";" or ":", ", "))
      return
    end

    local file = wfilename:GetFullPath()
    local helper
    if rundebug then
      -- start running the application right away
      ide:GetDebugger():SetOptions({runstart = ide.config.debugger.runonstart ~= false})
      local tmpfile = wx.wxFileName()
      tmpfile:AssignTempFileName(".")
      helper = tmpfile:GetFullPath()..".lua" -- busted likes .lua files more than .tmp files
      local f = io.open(helper, "w")
      if not f then
        ide:Print("Can't open temporary file '"..helper.."' for writing.")
        return 
      end
      f:write("require('mobdebug').start()")
      f:close()
    end

    local options = getRunOptions(self, "--output=TAP")
    local cmd = ('"%s" %s %s "%s"'):format(busted, helper and "--helper="..helper or "", options, file)
     -- CommandLineRun(cmd,wdir,tooutput,nohide,stringcallback,uid,endcallback)
    return CommandLineRun(cmd,self:fworkdir(wfilename),true,false,nil,nil,
      function() if helper then wx.wxRemoveFile(helper) end end)
  end,
  hasdebugger = true,
  takeparameters = true,
}
