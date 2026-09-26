--!nonstrict
-- Album timing is deterministic: preserve order and sum source durations.
local M = {}
local function trim(value)
  return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

function M.duration(value)
  if type(value) == "string" then
    local minutes, seconds = value:match("^(%d+):(%d%d)$")
    if minutes then
      if tonumber(seconds) >= 60 then return nil end
      value = tonumber(minutes) * 60 + tonumber(seconds)
    else
      value = tonumber(value)
    end
  end
  if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then return nil end
  return value
end

function M.build(list)
  if type(list) ~= "table" or type(list.tracks) ~= "table" or #list.tracks == 0 then
    return nil, "Album tracklist must contain at least one track"
  end
  local result = { artist = trim(list.artist), album = trim(list.album), tracks = {}, sources = {} }
  for _, source in ipairs(type(list.sources) == "table" and list.sources or {}) do
    if type(source) == "string" and source:match("^https?://[^/]+") then
      result.sources[#result.sources + 1] = source
    end
  end
  local start = 0
  for i, item in ipairs(list.tracks) do
    if type(item) ~= "table" then return nil, "Invalid album track " .. i end
    local duration = M.duration(item.duration_seconds)
    local artist = trim(item.artist)
    if artist == "" then artist = result.artist end
    local title = trim(item.title)
    if title == "" or artist == "" or not duration then
      return nil, "Album track " .. i .. " needs a title, artist and positive duration"
    end
    if start + duration == math.huge then return nil, "Invalid album duration" end
    result.tracks[i] = { title = title, artist = artist, duration_seconds = duration,
      start = start, ["end"] = start + duration }
    start = start + duration
  end
  result.duration = start
  return result
end

function M.at(timeline, position)
  for i, track in ipairs(timeline.tracks) do
    if position >= track.start and position < track["end"] then return track, i end
  end
  return nil, nil
end

return M
