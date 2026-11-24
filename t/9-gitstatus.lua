local status = require "gitstatus"
local output = table.concat({
  "# branch.oid 729a3b4c8c",
  "# branch.head feature/file-status",
  "1 MM N... 100644 100644 100644 abc def dir/a b.lua",
  "2 R. N... 100644 100644 100644 abc def R100 new name.lua",
  "old name.lua",
  "u UU N... 100644 100644 100644 100644 aaa bbb ccc merge.lua",
  "?  leading\tname\n.lua", "",
}, "\0")
local model = assert(status.parse(output))
is(model.branch, "feature/file-status", "Git reads the current branch from status.")
is(#model.rows, 5, "Staged and worktree changes on the same file each get a row.")
is(model.rows[1].area, "staged", "The index status remains separate.")
is(model.rows[2].area, "unstaged", "The worktree status remains separate.")
is(model.rows[3].path, "new name.lua", "The new rename path is read first.")
is(model.rows[3].oldPath, "old name.lua", "A rename preserves the original path.")
is(model.rows[4].area, "conflict", "Unmerged paths produce a single conflict row.")
is(model.rows[5].path, " leading\tname\n.lua", "NUL-delimited status preserves unusual path characters.")
local detached = assert(status.parse("# branch.head (detached)\0# branch.oid 91fade7300\0"))
is(detached.oid, "91fade7300", "Detached HEAD retains its commit identity.")
ok(status.parse("# branch.head main\0? partial") == nil, "Incomplete Git snapshots are rejected.")

local mixed = {
  {area = "staged", code = "R", path = "new [name].lua", oldPath = "old name.lua"},
  {area = "unstaged", code = "M", path = "new [name].lua", oldPath = "old name.lua"},
  {area = "untracked", code = "?", path = " leading\tname\n.lua"},
  {area = "staged", code = "C", path = "copy.lua", oldPath = "source.lua"},
  {area = "conflict", code = "U", path = "conflict.lua"},
  {area = "unstaged", code = "D", path = "deleted.lua"},
  {area = "unstaged", code = "M", path = "new [name].lua"},
}
is(table.concat(status.pathsToUpdate(mixed, true), "\0"),
  "new [name].lua\0 leading\tname\n.lua\0conflict.lua\0deleted.lua",
  "Staging uses unique working paths, including deletions and conflict resolutions.")
is(table.concat(status.pathsToUpdate(mixed, false), "\0"), "new [name].lua\0old name.lua\0copy.lua",
  "Unstaging a rename includes both paths, while a copy leaves the source alone.")
is(#status.pathsToUpdate({mixed[1]}, true), 0, "A staged row alone is not a staging target.")
is(#status.pathsToUpdate({mixed[3]}, false), 0, "An untracked row alone is not an unstaging target.")
