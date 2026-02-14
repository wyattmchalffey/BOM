package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local function scan_file(path)
  local f = io.open(path, "r")
  if not f then
    return false, "open_failed"
  end

  local line_no = 0
  for line in f:lines() do
    line_no = line_no + 1
    if line:match("^<<<<<<<") or line:match("^=======") or line:match("^>>>>>>>") then
      f:close()
      return false, string.format("merge_marker:%s:%d", path, line_no)
    end
  end

  f:close()
  return true
end

local function walk(dir, out)
  local p = io.popen(string.format("find %q -type f", dir))
  if not p then
    return
  end

  for file in p:lines() do
    if file:match("%.lua$") or file:match("%.md$") then
      out[#out + 1] = file
    end
  end

  p:close()
end

local files = {}
walk("love2d", files)

for _, file in ipairs(files) do
  local ok, err = scan_file(file)
  if not ok then
    error("Conflict marker smoke test failed: " .. err)
  end
end

print("Conflict marker smoke test passed")
