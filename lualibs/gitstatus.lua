local gitstatus = {}
local fields = {["1"] = 6, ["2"] = 7, u = 8}

function gitstatus.parse(data)
  local snapshot, position = {rows = {}}, 1
  local function record()
    local last = data:find("\0", position, true)
    if not last then return end
    local value = data:sub(position, last - 1)
    position = last + 1
    return value
  end
  local function add(path, code, area, oldPath)
    snapshot.rows[#snapshot.rows + 1] = {path = path, code = code, area = area, oldPath = oldPath}
  end

  while position <= #data do
    local value = record()
    if not value then return end
    local kind = value:sub(1, 1)
    if kind == "#" then
      local name, field = value:match("^# ([^ ]+) (.+)$")
      if name == "branch.head" then snapshot.branch = field end
      if name == "branch.oid" then snapshot.oid = field end
    elseif fields[kind] then
      local index, worktree, path = value:match("^"..kind.." (%S)(%S)"..(" [^ ]+"):rep(fields[kind]).." (.+)$")
      if not path then return end
      local oldPath = kind == "2" and record() or nil
      if kind == "2" and (not oldPath or oldPath == "") then return end
      if kind == "u" then
        add(path, "U", "conflict")
      else
        if index ~= "." then add(path, index, "staged", oldPath) end
        if worktree ~= "." then add(path, worktree, "unstaged", oldPath) end
      end
    elseif kind == "?" then
      if #value < 3 then return end
      add(value:sub(3), "?", "untracked")
    elseif kind ~= "!" then
      return
    end
  end
  if snapshot.branch then return snapshot end
end

function gitstatus.pathsToUpdate(rows, stage)
  local paths, seen = {}, {}
  local function add(path)
    if path and not seen[path] then
      paths[#paths + 1] = path
      seen[path] = true
    end
  end
  for _, row in ipairs(rows) do
    if stage ~= (row.area == "staged") then
      add(row.path)
      -- Undo or stage a move as a pair. A copy leaves its source alone.
      if row.code == "R" then add(row.oldPath) end
    end
  end
  return paths
end

return gitstatus
