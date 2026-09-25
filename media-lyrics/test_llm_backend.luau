local root = ...
local function module(name) return assert(loadfile(root .. "/" .. name))() end
local backend = module("llm_backend.luau")
local lyricsLib = module("lyrics_lib.luau")
local function eq(actual, expected)
  assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function contains(actual, expected)
  assert(actual and actual:find(expected, 1, true), tostring(actual) .. " lacks " .. expected)
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = copy(v) end
  return result
end
for _, raw in ipairs({ "[00:00.000] 纯音乐，请欣赏", "暂无歌词", "纯 音 乐， 请 欣 赏！", "纯音乐，请欣赏，谢谢" }) do
  eq(lyricsLib.isPlaceholderLyrics(raw), true)
end
for _, raw in ipairs({ "", "[00:01.00]Ordinary song lyrics", string.rep("A long verse with ordinary words\n", 10000),
  "含有纯字但这是一段真正的长歌词，不是占位内容", "暂时的告别只是歌词中的一句话，后面还有很多故事" }) do
  eq(lyricsLib.isPlaceholderLyrics(raw), false)
end
-- JSON itself is a host primitive; these fixtures preserve encoded value
-- boundaries while exercising the actual adapters and service callbacks.
local encoded, serial = {}, 0
local json = {
  encode = function(value)
    serial = serial + 1
    local key = "fixture-" .. serial
    encoded[key] = copy(value)
    return key
  end,
  decode = function(value) return encoded[value] end,
}
local identity = { result_id = 123 }
local function success(provider, value)
  if provider.id == "anthropic" then
    return { ok = true, status = 200, body = json.encode({ stop_reason = "end_turn",
      content = { { type = "text", text = json.encode(value or identity) } } }) }
  end
  return { ok = true, status = 200, body = json.encode({ choices = {
    { finish_reason = "stop", message = { content = json.encode(value or identity) } },
  } }) }
end
local function failure(code, message)
  return { ok = false, status = code, body = json.encode({ error = { message = message } }) }
end

local function toolCall(provider, args, id)
  if provider.id == "anthropic" then
    return { ok = true, status = 200, body = json.encode({ stop_reason = "tool_use", content = {
      { type = "tool_use", id = id or "query-1", name = "search_lyrics", input = args } } }) }
  end
  return { ok = true, status = 200, body = json.encode({ choices = {
    { finish_reason = "tool_calls", message = { tool_calls = { { id = id or "query-1", type = "function",
      ["function"] = { name = "search_lyrics", arguments = json.encode(args) } } } } } } }) }
end

local function emitEvent(line, value)
  line("data: " .. json.encode(value))
  line("")
end
local function emitResponse(response, line, close)
  local body = json.decode(response.body)
  if body and body.choices then
    local choice = body.choices[1]
    emitEvent(line, { choices = { { delta = choice.message, finish_reason = choice.finish_reason } } })
    line("data: [DONE]")
    line("")
  else line(response.body or "") end
  close({ ok = response.ok, status = response.status, error = response.error })
end

eq(backend.select({ llm_backend = "none", openrouter_api_key = "saved" }), nil)
eq(backend.select({}).id, "openrouter")
eq(backend.select({}).model, "~google/gemini-flash-latest")
eq(backend.select({ llm_max_tokens = " 65536 " }).maxTokens, 65536)
eq(backend.select({ llm_max_tokens = 65536 }).maxTokens, 65536)
for _, invalid in ipairs({ "", "text", "0", "-5", "1.5", "1e5", "999999999999999999999999" }) do
  local _, err = backend.request(backend.select({ openrouter_api_key = "test", llm_max_tokens = invalid }), "prompt")
  eq(err, "LLM output token limit must be a positive whole number")
end
local keys = { llm_backend = "openai", openrouter_api_key = "last", openai_api_key = "middle", ollama_api_key = "first" }
eq(backend.select(keys).id, "openai")
keys.openai_api_key = ""
eq(backend.select(keys).id, "openai")
local _, noKey = backend.request(backend.select(keys), "prompt")
eq(noKey, "No API key configured")
keys.llm_backend = "openrouter"
eq(backend.select(keys).id, "openrouter")
keys.llm_backend = "ollama"
keys.ollama_api_key = " \n "
eq(backend.select(keys).key, "ollama")
for _, definition in ipairs(backend.providers) do
  local settings = { llm_backend = definition.id, [definition.id .. "_api_key"] = "secret", [definition.id .. "_model"] = definition.model ~= "" and definition.model or "local-model" }
  local provider = backend.select(settings)
  local request = assert(backend.request(provider, string.rep("long title ", 5000)))
  eq(request.body.max_tokens or request.body.max_completion_tokens, 32768)
  eq(request.body.stream, true)
  eq(definition.id == "anthropic" and request.body.tools[1].name or request.body.tools[1]["function"].name, "search_lyrics")
  eq(#request.body.messages[1].content, 55000)
  local match, err = backend.parse(provider, success(provider), json)
  eq(err, nil)
  eq(match.result_id, 123)
  local _, bad = backend.parse(provider, failure(401, "Invalid key: secret"), json)
  contains(bad, "HTTP 401")
  contains(bad, "[redacted]")
  assert(not bad:find("secret", 1, true))
end
local router = backend.select({ llm_backend = "openrouter", openrouter_api_key = "test" })
eq(backend.request(router, "prompt").body.tools[2].type, "openrouter:web_search")
local openai = backend.select({ llm_backend = "openai", openai_api_key = "test", llm_max_tokens = 65536 })
eq(backend.request(openai, "prompt").body.max_completion_tokens, 65536)
local localOpenai = backend.select({ llm_backend = "openai", openai_api_key = "ollama", openai_model = "local",
  openai_endpoint = "http://localhost:11434/v1/chat/completions/" })
local localRequest = backend.request(localOpenai, "prompt")
eq(localRequest.url, "http://localhost:11434/v1/chat/completions")
eq(localRequest.body.max_tokens, 32768)
eq(localRequest.body.tools[1]["function"].name, "search_lyrics")
local _, missingModel = backend.request(backend.select({ llm_backend = "ollama" }), "prompt")
eq(missingModel, "No model configured")
local _, truncated = backend.parse(openai, { ok = true, status = 200,
  body = json.encode({ choices = { { finish_reason = "length", message = {} } } }) }, json)
contains(truncated, "Output token limit reached (65536)")
local _, empty = backend.parse(openai, { ok = true, status = 200,
  body = json.encode({ choices = { { message = {} } } }) }, json)
contains(empty, "Empty response")
local _, malformed = backend.parse(openai, { ok = true, status = 200, body = "invalid" }, json)
eq(malformed, "Invalid JSON response")
local _, network = backend.parse(openai, { ok = false, status = 0, error = "Connection refused" }, json)
eq(network, "Connection refused")
local noMatch = backend.parse(openai, success(openai, { result_id = 0 }), json)
eq(noMatch.result_id, 0)
for _, provider in ipairs({ openai, backend.select({ llm_backend = "anthropic", anthropic_api_key = "test" }) }) do
  local rejected, err = backend.parse(provider, success(provider, { not_a_song = true }), json)
  eq(err, nil)
  eq(rejected.not_a_song, true)
end
local _, conflicting = backend.parse(openai, success(openai, { not_a_song = true, result_id = 123 }), json)
contains(conflicting, "cannot both reject")
local _, badFields = backend.parse(openai, success(openai, { artist = "Guessed", title = "Song" }), json)
contains(badFields, "must contain result_id")
local callbacks = 0
backend.identify(openai, "prompt", { json = json, httpStream = function() return nil end }, function(_, err)
  callbacks = callbacks + 1
  eq(err, "Could not start request")
end)
eq(callbacks, 1)
backend.identify(openai, "prompt", { json = json, httpStream = function() error("Connection refused") end }, function(_, err)
  contains(err, "Connection refused")
end)
backend.identify(openai, "prompt", { json = json, httpStream = function(_, _, close) close(nil) return {} end }, function(_, err)
  eq(err, "Malformed provider response")
end)

-- Real SSE framing: keepalive comments, split content, terminal marker,
-- Anthropic events, partial responses and errors arriving with HTTP 200.
for _, definition in ipairs(backend.providers) do
  local provider = backend.select({ llm_backend = definition.id, [definition.id .. "_api_key"] = "test",
    [definition.id .. "_model"] = "fixture-model" })
  backend.identify(provider, "prompt", { json = json, httpStream = function(_, line, close)
    line(": OPENROUTER PROCESSING")
    line("")
    local content = json.encode(identity)
    if provider.id == "anthropic" then
      line("event: content_block_delta")
      emitEvent(line, { type = "content_block_delta", delta = { type = "text_delta", text = content } })
      emitEvent(line, { type = "message_delta", delta = { stop_reason = "end_turn" } })
      emitEvent(line, { type = "message_stop" })
    else
      emitEvent(line, { choices = { { delta = { content = content:sub(1, 3) } } } })
      emitEvent(line, { choices = { { delta = { content = content:sub(4) }, finish_reason = "stop" } } })
      line("data: [DONE]")
      line("")
    end
    close({ ok = true, status = 200 })
    return {}
  end }, function(match, err)
    eq(err, nil)
    eq(match.result_id, identity.result_id)
  end)
end
for _, case in ipairs({
  { chunk = { error = { message = "Provider failed" } }, error = "Provider failed" },
  { chunk = { choices = { { delta = { content = "partial" } } } }, error = "Stream ended before" },
  { chunk = { choices = { { delta = {}, finish_reason = "length" } } }, error = "Output token limit reached" },
  { chunk = { choices = { { delta = { content = json.encode(identity) }, finish_reason = "error" } } },
    error = "Provider ended the response with an error" },
}) do
  backend.identify(openai, "prompt", { json = json, httpStream = function(_, line, close)
    emitEvent(line, case.chunk)
    close({ ok = true, status = 200 })
    return {}
  end }, function(_, err) contains(err, case.error) end)
end

-- Streamed tool arguments may span events. Replay the assistant call and
-- provider-specific result envelopes, including Gemini reasoning signatures.
for _, id in ipairs({ "openrouter", "anthropic" }) do
  local provider = backend.select({ llm_backend = id, [id .. "_api_key"] = "test" })
  local requests, finished, result = {}, false, nil
  local host = { json = json, httpStream = function(req, line, close)
    requests[#requests + 1] = { body = json.decode(req.body), line = line, close = close,
      respond = function(response) emitResponse(response, line, close) end }
    return { stop = function() end }
  end }
  backend.resolve(provider, "prompt", host, function(args, cb)
    eq(args.title, "Sisters")
    cb({ { id = 456, title = "Sisters", artist = "Frost Children", album = "", duration = 224,
      synced = "[00:00]Fixture", plain = "" } })
  end, function(match, err) eq(err, nil) finished = true result = match end)
  local first = requests[1]
  local args = json.encode({ title = "Sisters", artist = "Frost Children" })
  if id == "anthropic" then
    emitEvent(first.line, { type = "content_block_start", index = 0,
      content_block = { type = "tool_use", id = "query-1", name = "search_lyrics", input = {} } })
    emitEvent(first.line, { type = "content_block_delta", index = 0,
      delta = { type = "input_json_delta", partial_json = args:sub(1, 3) } })
    emitEvent(first.line, { type = "content_block_delta", index = 0,
      delta = { type = "input_json_delta", partial_json = args:sub(4) } })
    emitEvent(first.line, { type = "message_delta", delta = { stop_reason = "tool_use" } })
    emitEvent(first.line, { type = "message_stop" })
  else
    emitEvent(first.line, { choices = { { delta = { tool_calls = { { index = 0, id = "query-1",
      ["function"] = { name = "search_lyrics", arguments = args:sub(1, 3) } } },
      reasoning_details = { { index = 0, type = "reasoning.encrypted", data = "opaque-signature" } } } } } })
    emitEvent(first.line, { choices = { { delta = { tool_calls = { { index = 0,
      ["function"] = { arguments = args:sub(4) } } } }, finish_reason = "tool_calls" } } })
    first.line("data: [DONE]") first.line("")
  end
  first.close({ ok = true, status = 200 })
  eq(#requests, 2)
  local messages = requests[2].body.messages
  if id == "anthropic" then
    eq(messages[2].content[1].input.title, "Sisters")
    eq(messages[3].content[1].type, "tool_result")
    eq(messages[3].content[1].tool_use_id, "query-1")
  else
    eq(messages[2].reasoning_details[1].data, "opaque-signature")
    eq(messages[3].tool_call_id, "query-1")
  end
  requests[2].respond(success(provider, { result_id = 456 }))
  eq(finished, true)
  eq(result.title, "Sisters")
end

local function resolverFixture()
  local requests, completed, errorText, queryCount = {}, false, nil, 0
  local handle = backend.resolve(openai, "prompt", { json = json, httpStream = function(req, line, close)
    requests[#requests + 1] = function(response) emitResponse(response, line, close) end
    return { stop = function() end }
  end }, function(_, cb) queryCount = queryCount + 1 cb({}) end, function(_, err) completed = true errorText = err end)
  return { requests = requests, handle = handle, done = function() return completed, errorText end,
    queryCount = function() return queryCount end }
end
local rejected = resolverFixture()
rejected.requests[1](success(openai, { not_a_song = true }))
local rejectionDone, rejectionError = rejected.done()
eq(rejectionDone, true)
eq(rejectionError, nil)
eq(rejected.queryCount(), 0)
eq(#rejected.requests, 1)
local invented = resolverFixture()
invented.requests[1](success(openai, { result_id = 999 }))
local _, inventedError = invented.done()
contains(inventedError, "not returned by search_lyrics")
local limited = resolverFixture()
for i = 1, 5 do limited.requests[i](toolCall(openai, { title = "Guess", artist = "" }, "query-" .. i)) end
local _, limitError = limited.done()
contains(limitError, "4 queries")
eq(#limited.requests, 5)
local cancelled = resolverFixture()
cancelled.handle.stop()
cancelled.requests[1](toolCall(openai, { title = "Guess", artist = "" }))
eq(#cancelled.requests, 1)
eq(cancelled.done(), false)

-- Execute the real service with asynchronous HTTP and deterministic lyric
-- misses. No credentials, processes, files, or network are used by this host.
local function service(options)
  options = options or {}
  local settings = { llm_backend = "openai", openai_api_key = "test", youtube_fallback = false, use_cache = false }
  if options.chapters or options.video then settings.youtube_fallback = true end
  if options.router then settings.llm_backend = "openrouter" settings.openrouter_api_key = "test" end
  local watchers, requests, states, pendingLyrics, metadataRequests = {}, {}, {}, {}, {}
  local searchResults
  local title = "Ninajirachi - iPod Touch (Official Video)"
  local function fields()
    local f = {}
    for k, v in pairs({ title = title, artists = "", album = "", identity = "Firefox", bus_name = "test.player",
      source_url = (options.chapters or options.video) and "https://www.youtube.com/watch?v=chapter-test" or "https://example.com/track",
      playback_status = "Playing" }) do f[k] = { type = "s", data = v } end
    f.length_us = { type = "x", data = 240000000 }
    f.position_us = { type = "x", data = 90000000 }
    return f
  end
  local host = {
    getConfig = function(k) return settings[k] end,
    string = { trim = function(s) return s:match("^%s*(.-)%s*$") end, urlEncode = function(s) return s end },
    json = json, tr = function(s) return s end,
    pluginDataDir = function() return "/fake" end,
    pluginDir = function() return "/fake/plugin" end,
    expandPath = function(s) return s end, readFile = function(path)
      if options.pendingMetadata then return nil end
      if options.video and path:find("chapters-chapter-test.json", 1, true) then
        return json.encode({ title = title, uploader = "Channel", duration = 240, chapters = {} })
      elseif options.chapters and path:find("chapters-chapter-test.json", 1, true) then
        return json.encode({ title = "Frost Children - Full Album", uploader = "Channel", duration = 240,
          description = "Album credits: Frost Children. The chapter labels only contain song names.",
          artist = "Frost Children", channel = "Upload channel",
          chapters = { { title = "03. Sisters (guest appearance)", start = 30, ["end"] = 240 } } })
      end
      return nil
    end,
    mkdirAll = function() end, writeFile = function() end, log = function() end,
    nowMs = function() return 1000 end, setUpdateInterval = function() end,
    state = { watch = function(k, cb) watchers[k] = cb end,
      set = function(k, v) states[k] = copy(v) end },
    httpStream = function(req, line, close)
      local request = { request = req, stopped = false, callback = function(response)
        emitResponse(response, line, close)
      end }
      requests[#requests + 1] = request
      return { stop = function() request.stopped = true end }
    end,
    runAsync = function(args, cb)
      if args[#args] == "GetActivePlayer" then
        cb({ exitCode = 0, stdout = json.encode({ data = { true, fields() } }) })
      elseif args[1] == "python3" then
        metadataRequests[#metadataRequests + 1] = cb
      elseif args[1] == "curl" then
        if searchResults and args[#args]:find("lrclib.net/api/search", 1, true) then
          cb({ exitCode = 0, stdout = json.encode(searchResults) })
          return true
        end
        if options.delayLyrics then pendingLyrics[#pendingLyrics + 1] = cb return true end
        cb({ exitCode = 0, stdout = json.encode(options.lyricHit and
          { syncedLyrics = "[00:00.00]Fixture lyric" } or {}) })
      else cb({ exitCode = 0, stdout = "" }) end
      return true
    end,
  }
  local env = setmetatable({ noctalia = host, require = function(name)
    local value = module(name:gsub("^./", ""))
    if options.failResultProcessing and name == "./lyrics_lib.luau" then
      value.isPlaceholderLyrics = function() error("simulated callback CPU budget exceeded") end
    end
    return value
  end }, { __index = _G })
  assert(loadfile(root .. "/service.luau", "t", env))()
  env.onEnable()
  return { env = env, states = states, requests = requests, settings = settings, watchers = watchers,
    pendingLyrics = pendingLyrics,
    metadataRequests = metadataRequests,
    setSearchResults = function(value) searchResults = value end,
    setTitle = function(value) title = value env.update() end }
end
local s = service()
eq(#s.requests, 1)
eq(s.states.media.lyricsStatus, "empty")
eq(s.states.media.llmStatus, "pending")
local spoken = service({ video = true })
eq(spoken.states.media.llmStatus, "pending")
local spokenPrompt = json.decode(spoken.requests[1].request.body).messages[1].content
contains(spokenPrompt, 'immediately return {"not_a_song": true} without calling any tools')
contains(spokenPrompt, "immediately call search_lyrics with that guess")
assert(not spokenPrompt:lower():find("web search", 1, true))
spoken.requests[1].callback(success(openai, { not_a_song = true }))
spoken.env.update()
spoken.env.update()
eq(#spoken.requests, 1)
eq(spoken.states.media.lyricsStatus, "empty")
eq(spoken.states.media.llmError, nil)
eq(spoken.states.media.llmStatus, "not_song")
spoken.watchers.panel_req({ action = "reloadLyrics" })
eq(spoken.states.media.llmStatus, "pending")
eq(#spoken.requests, 2)
s.requests[1].callback(failure(401, "Invalid API key"))
eq(s.states.media.llmError.provider, "OpenAI")
contains(s.states.media.llmError.message, "Invalid API key")
eq(s.states.media.llmStatus, "error")
s.env.update()
eq(#s.requests, 1) -- no repeated requests or fallback to another provider
eq(backend.noLyricsMessage("No lyrics found", s.states.media.llmError),
  "No lyrics found (LLM backend for OpenAI returned error: HTTP 401: Invalid API key)")
s.watchers.panel_req({ action = "reloadLyrics" })
eq(#s.requests, 2)
eq(s.states.media.llmError, nil)
eq(s.states.media.llmStatus, "pending")
s.setTitle("Another track")
eq(#s.requests, 3)
s.requests[2].callback(failure(403, "Old track failure"))
eq(s.states.media.llmError, nil)
eq(s.states.media.llmStatus, "pending")
s.requests[3].callback(failure(429, "Rate limit"))
contains(s.states.media.llmError.message, "Rate limit")
s.settings.llm_backend = "ollama"
s.settings.ollama_api_key = "ollama"
s.settings.ollama_model = "local-model"
s.env.onConfigChanged()
eq(s.states.media.llmError, nil)
eq(s.requests[3].stopped, true)
eq(#s.requests, 4)
contains(s.requests[4].request.url, "localhost:11434")
s.requests[3].callback(failure(401, "Old settings failure"))
eq(s.states.media.llmError, nil)
s.requests[4].callback(success({ id = "ollama" }, { result_id = 0 }))
eq(s.states.media.title, "Another track")
eq(s.states.media.llmError, nil)
s.settings.llm_backend = "none"
s.env.onConfigChanged()
eq(#s.requests, 4)
eq(s.states.media.llmError, nil)
eq(s.states.media.llmStatus, "idle")

local chapterHit = service({ chapters = true, lyricHit = true })
eq(chapterHit.states.media.lyricsStatus, "ready")
eq(chapterHit.states.media.title, "03. Sisters (guest appearance)")
eq(chapterHit.states.media.artist, "") -- no artist guessed from video title
chapterHit.env.update()
eq(#chapterHit.requests, 0) -- literal chapter hit skips the LLM
local chapter = service({ chapters = true })
eq(chapter.states.media.lyricsStatus, "empty")
eq(#chapter.requests, 1)
local chapterPrompt = json.decode(chapter.requests[1].request.body).messages[1].content
contains(chapterPrompt, "Chapter labels are hints, not verified song titles")
local chapterContext = json.decode(chapterPrompt:match("(fixture%-%d+)$"))
eq(chapterContext.chapter_title, "03. Sisters (guest appearance)")
eq(chapterContext.chapter_duration_seconds, 210)
eq(chapterContext.active_chapter_index, 1)
eq(chapterContext.chapter_start_seconds, 30)
eq(chapterContext.chapter_end_seconds, 240)
eq(chapterContext.mpris_title, "Ninajirachi - iPod Touch (Official Video)")
eq(chapterContext.video_metadata.channel, "Upload channel")
eq(chapterContext.video_metadata.artist, "Frost Children")
contains(chapterContext.video_metadata.description, "Album credits")
eq(chapterContext.video_metadata.chapters[1].title, "03. Sisters (guest appearance)")
contains(chapterPrompt, "No field is authoritative on its own")
chapter.env.update()
eq(#chapter.requests, 1)

local fast = service({ video = true, lyricHit = true })
eq(fast.states.media.title, "Ninajirachi - iPod Touch (Official Video)")
eq(fast.states.media.artist, "")
eq(fast.states.media.lyricsStatus, "ready")
eq(#fast.requests, 0)
eq(#fast.metadataRequests, 0) -- cached metadata does not spawn yt-dlp
local background = service({ video = true, pendingMetadata = true, router = true })
eq(#background.metadataRequests, 1)
eq(#background.requests, 1) -- title parsing starts while yt-dlp is still pending
eq(background.states.media.llmStatus, "pending")
eq(json.decode(background.requests[1].request.body).tools[2].type, "openrouter:web_search")
background.env.update()
background.env.update()
eq(#background.metadataRequests, 1) -- no extraction on every player poll
eq(#background.requests, 1)
background.metadataRequests[1]({ exitCode = 0,
  stdout = json.encode({ title = "Video title", uploader = "Channel",
    description = "Newly available credits", duration = 240, chapters = {} }) })
background.env.update()
eq(#background.metadataRequests, 1)
eq(#background.requests, 2) -- restart the pending guess with the new context
eq(background.requests[1].stopped, true)
local enrichedPrompt = json.decode(background.requests[2].request.body).messages[1].content
local enrichedContext = json.decode(enrichedPrompt:match("(fixture%-%d+)$"))
eq(enrichedContext.video_metadata.description, "Newly available credits")
local waiting = service({ chapters = true, delayLyrics = true })
eq(waiting.states.media.lyricsStatus, "loading")
waiting.env.update()
eq(#waiting.requests, 0) -- no eager LLM call while the literal lookup is pending
waiting.pendingLyrics[1]({ exitCode = 0, stdout = json.encode({ syncedLyrics = "[00:00.00]Fixture lyric" }) })
waiting.env.update()
eq(waiting.states.media.lyricsStatus, "ready")
eq(#waiting.requests, 0)
local fallback = service({ video = true, router = true })
eq(#fallback.requests, 1)
eq(json.decode(fallback.requests[1].request.body).tools[1]["function"].name, "search_lyrics")
eq(json.decode(fallback.requests[1].request.body).tools[2].type, "openrouter:web_search")
fallback.requests[1].callback(toolCall(router, { title = "Wrong guess", artist = "Unknown" }))
eq(#fallback.requests, 2)
local retryMessages = json.decode(fallback.requests[2].request.body).messages
eq(retryMessages[3].role, "tool")
eq(#json.decode(retryMessages[3].content).results, 0)
fallback.setSearchResults({ { id = 123, artistName = "Ninajirachi", trackName = "iPod Touch", albumName = "",
  duration = 240, syncedLyrics = "[00:00.00]Selected lyrics" } })
fallback.requests[2].callback(toolCall(router, { title = "iPod Touch", artist = "Ninajirachi" }, "query-2"))
eq(#fallback.requests, 3)
local selectedMessages = json.decode(fallback.requests[3].request.body).messages
local found = json.decode(selectedMessages[5].content).results[1]
eq(found.result_id, 123)
eq(found.title, "iPod Touch")
fallback.requests[3].callback(success(router))
fallback.env.update()
eq(#fallback.requests, 3)
eq(fallback.states.media.title, "iPod Touch")
eq(fallback.states.media.lyricsStatus, "ready")
eq(fallback.states.media.llmStatus, "done")
eq(fallback.states.media.lyrics[1].text, "Selected lyrics")
local failed = service({ router = true })
failed.requests[1].callback(failure(401, "Invalid key"))
eq(#failed.requests, 1) -- errors are surfaced, not retried with search
contains(failed.states.media.llmError.message, "Invalid key")
local processingFailure = service({ router = true, failResultProcessing = true })
processingFailure.setSearchResults({ { id = 123, artistName = "Artist", trackName = "Song", plainLyrics = "Words" } })
processingFailure.requests[1].callback(toolCall(router, { title = "Song", artist = "Artist" }))
eq(#processingFailure.requests, 2) -- processing error is returned to the model, never abandoned
local processingMessages = json.decode(processingFailure.requests[2].request.body).messages
contains(json.decode(processingMessages[3].content).error, "Could not process LRCLIB results")
processingFailure.requests[2].callback(success(router, { result_id = 0 }))
eq(processingFailure.states.media.llmStatus, "done")
chapter.setSearchResults({ { id = 123, artistName = "Frost Children", trackName = "Sisters", albumName = "",
  syncedLyrics = "[00:00.00]Chapter lyrics" } })
chapter.requests[1].callback(toolCall(openai, { title = "Sisters", artist = "Frost Children" }))
chapter.requests[2].callback(success(openai))
eq(chapter.states.media.title, "Sisters")
eq(chapter.states.media.posSec, 60) -- preserve chapter-relative timing
eq(#chapter.requests, 2)

-- Render the actual panel trees and check the requested user-facing text.
local function panelText(file, overrides)
  local watch, tree
  local ui = setmetatable({}, { __index = function(_, kind)
    return function(props, children) return { kind = kind, props = props, children = children } end
  end })
  local host = { getConfig = function() return "medium" end, nowMs = function() return 1000 end,
    tr = function(key) return ({ ["panel.no-lyrics"] = "No lyrics found",
      ["panel.waiting-for-ai"] = "Waiting for AI...",
      ["panel.ai-not-song"] = "Classified as not a song by AI",
      ["panel.loading-lyrics"] = "Loading lyrics…" })[key] or key end,
    state = { watch = function(_, cb) watch = cb end },
  }
  local env = setmetatable({ noctalia = host, ui = ui,
    panel = setmetatable({ render = function(value) tree = value end }, { __index = function() return function() end end }),
    require = function(name) return module(name:gsub("^./", "")) end }, { __index = _G })
  assert(loadfile(root .. "/" .. file, "t", env))()
  local state = { hasPlayer = true, title = "Song", artist = "Artist", album = "", artUrl = "", lyrics = {},
    lyricsStatus = "empty", lyricsProvider = "", lengthSec = 240, posSec = 0 }
  for k, v in pairs(overrides or { llmError = { provider = "OpenAI", message = "HTTP 401: Invalid API key" } }) do
    state[k] = v
  end
  watch(state)
  local labels = {}
  local function walk(node)
    if type(node) ~= "table" then return end
    if node.kind == "label" and node.props.text then labels[#labels + 1] = node.props.text:gsub("\n", " ") end
    for _, child in ipairs(node.children or {}) do walk(child) end
  end
  walk(tree)
  return table.concat(labels, "\n")
end
for _, file in ipairs({ "panel.luau", "panel-mini.luau" }) do
  contains(panelText(file), "No lyrics found (LLM backend for OpenAI returned error: HTTP 401: Invalid API key)")
  for _, status in ipairs({ "loading", "empty" }) do
    local pending = panelText(file, { llmStatus = "pending", lyricsStatus = status })
    contains(pending, "Waiting for AI...")
    assert(not pending:find("Loading lyrics", 1, true))
  end
  contains(panelText(file, { llmStatus = "not_song" }), "Classified as not a song by AI")
  contains(panelText(file, { llmStatus = "idle", lyricsStatus = "loading" }), "Loading lyrics…")
end
print("Provider adapters, service lifecycle, and both panel error messages passed")
