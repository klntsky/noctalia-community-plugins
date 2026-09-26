-- Runs the production service with explicit input and an isolated host.
local root = replay_bridge("root")
local callbacks, streams, modules, watchers = {}, {}, {}, {}
local serial = 0
local function nextId()
  serial = serial + 1
  return serial
end
function require(name)
  if not modules[name] then modules[name] = assert(loadfile(root .. "/" .. name))() end
  return modules[name]
end
noctalia = {
  getConfig = function(key) return replay_bridge("setting", key) end,
  json = {
    encode = function(value) return replay_bridge("encode", value) end,
    decode = function(value) return replay_bridge("decode", value) end,
  },
  string = {
    trim = function(value) return value:match("^%s*(.-)%s*$") end,
    urlEncode = function(value) return replay_bridge("urlEncode", value) end,
  },
  pluginDir = function() return root end,
  pluginDataDir = function() return "/replay-data" end,
  expandPath = function(path) return path end,
  readFile = function(path) return replay_bridge("readFile", path) end,
  writeFile = function(path, value) replay_bridge("writeFile", { path, value }) end,
  mkdirAll = function() end,
  nowMs = function() return replay_bridge("nowMs") end,
  log = function(value) replay_bridge("log", value) end,
  tr = function(key) return key end,
  setUpdateInterval = function() end,
  state = {
    set = function(key, value) replay_bridge("state", { key, value }) end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  runAsync = function(argv, callback, timeout)
    local id = nextId()
    callbacks[id] = callback
    replay_bridge("command", { id = id, argv = argv, timeout = timeout or 5000 })
    return true
  end,
  httpStream = function(request, line, close)
    local id = nextId()
    streams[id] = { line = line, close = close }
    replay_bridge("http", { id = id, request = request })
    return { stop = function() streams[id] = nil end }
  end,
}
function replay_dispatch(kind, id, value)
  if kind == "state" then
    if watchers[id] then watchers[id](value) end
  elseif kind == "command" then
    local callback = callbacks[id]
    callbacks[id] = nil
    if callback then callback(value) end
  elseif streams[id] then
    local stream = streams[id]
    if kind == "close" then streams[id] = nil end
    stream[kind](value)
  end
end
assert(loadfile(root .. "/service.luau"))()
onEnable()
