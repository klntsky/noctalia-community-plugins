--!nonstrict
-- Provider adapters kept independent of the host for request/response tests.
local M = {}

M.providers = {
  { id = "openai", name = "OpenAI", endpoint = "https://api.openai.com/v1", model = "gpt-5.6-luna" },
  { id = "anthropic", name = "Anthropic", endpoint = "https://api.anthropic.com/v1", model = "claude-haiku-4-5" },
  { id = "gemini", name = "Gemini", endpoint = "https://generativelanguage.googleapis.com/v1beta", model = "gemini-flash-latest" },
  { id = "xai", name = "xAI", endpoint = "https://api.x.ai/v1", model = "grok-4.3-latest" },
  { id = "groq", name = "Groq", endpoint = "https://api.groq.com/openai/v1", model = "openai/gpt-oss-120b" },
  { id = "mistral", name = "Mistral", endpoint = "https://api.mistral.ai/v1", model = "mistral-small-latest" },
  { id = "openrouter", name = "OpenRouter", endpoint = "https://openrouter.ai/api/v1", model = "~google/gemini-flash-latest" },
}

local function trim(value)
  return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

local function positiveInteger(value, default)
  local text = trim(tostring(value == nil and default or value))
  local number = text:match("^%d+$") and tonumber(text) or nil
  if number and number >= 1 and number <= 9007199254740991 then return number end
  return nil
end

local function toolLimit(provider, mode)
  if mode == "album" then return provider.albumPageLimit end
  if mode == "lyrics" then return provider.webSearchLimit end
  return provider.databaseSearchLimit
end

function M.select(settings)
  local selected = settings.llm_backend or "openrouter"
  for _, provider in ipairs(M.providers) do
    if provider.id == selected then
      local key = trim(settings[provider.id .. "_api_key"])
      local model = trim(settings[provider.id .. "_model"])
      local endpoint = trim(settings[provider.id .. "_endpoint"])
      -- Text entry avoids the host's range slider. Accept legacy numeric
      -- settings too, but never silently round or replace an invalid value.
      local tokenText = trim(tostring(settings.llm_max_tokens == nil and "32768" or settings.llm_max_tokens))
      local tokens = tokenText:match("^%d+$") and tonumber(tokenText) or nil
      if tokens and (tokens < 1 or tokens > 9007199254740991) then tokens = nil end
      return { id = provider.id, name = provider.name, key = key,
        model = model ~= "" and model or provider.model,
        endpoint = (endpoint ~= "" and endpoint or provider.endpoint):gsub("/+$", ""),
        maxTokens = tokens,
        databaseSearchLimit = positiveInteger(settings.llm_database_search_limit, 4),
        webSearchLimit = positiveInteger(settings.llm_web_search_limit, 4),
        albumPageLimit = positiveInteger(settings.llm_album_page_limit, 4) }
    end
  end
  return nil
end

function M.safeError(provider, message)
  local text = tostring(message or "Unknown error")
  if provider.key and provider.key ~= "" then
    local pattern = provider.key:gsub("([^%w])", "%%%1")
    text = text:gsub(pattern, "[redacted]")
  end
  text = text:gsub("%c", " "):gsub("%s+", " ")
  local ok, ending = pcall(utf8.offset, text, 601)
  return ok and (ending and text:sub(1, ending - 1) or text) or text:sub(1, 600)
end

function M.noLyricsMessage(message, failure)
  if failure then
    return message .. " (LLM backend for " .. failure.provider .. " returned error: " .. failure.message .. ")"
  end
  return message
end

function M.request(provider, prompt, mode)
  if not provider.maxTokens then return nil, "LLM output token limit must be a positive whole number" end
  if not toolLimit(provider, mode) then
    return nil, (mode == "album" and "AI album browsing limit"
      or mode == "lyrics" and "AI web browsing limit" or "AI lyrics database search limit")
      .. " must be a positive whole number"
  end
  if provider.key == "" then return nil, "No API key configured" end
  if provider.model == "" then return nil, "No model configured" end
  if not provider.endpoint:match("^https?://[^/]+") then
    return nil, "Endpoint must be an HTTP or HTTPS URL"
  end
  local body = { model = provider.model, stream = true,
    messages = type(prompt) == "table" and prompt or { { role = "user", content = prompt } } }
  local search = { name = "search_lyrics", description = "Query the plugin's LRCLIB lyrics database. Inspect returned artist, title, album, duration and available lyrics; revise the query if needed.",
    parameters = { type = "object", properties = {
      title = { type = "string", description = "Song title to search for" },
      artist = { type = "string", description = "Artist, or empty to search by title only" },
    }, required = { "title", "artist" }, additionalProperties = false } }
  local browsing = mode == "album" or mode == "lyrics"
  local headers = { "Content-Type: application/json" }
  local endpoint = provider.endpoint
  if provider.id == "anthropic" then
    endpoint = endpoint .. "/messages"
    headers[#headers + 1] = "x-api-key: " .. provider.key
    headers[#headers + 1] = "anthropic-version: 2023-06-01"
    body.max_tokens = provider.maxTokens
    if browsing then
      body.tools = { { type = "web_search_20250305", name = "web_search", max_uses = toolLimit(provider, mode) },
        { type = "web_fetch_20250910", name = "web_fetch", max_uses = toolLimit(provider, mode) } }
    else
      body.tools = { { name = search.name, description = search.description, input_schema = search.parameters } }
    end
  elseif provider.id == "gemini" and browsing then
    endpoint = endpoint .. "/models/" .. provider.model .. ":generateContent"
    headers[#headers + 1] = "x-goog-api-key: " .. provider.key
    body = { contents = { { parts = { { text = prompt } } } },
      tools = { { google_search = {} }, { url_context = {} } },
      generationConfig = { maxOutputTokens = provider.maxTokens } }
  elseif provider.id == "mistral" and browsing then
    endpoint = endpoint .. "/conversations"
    headers[#headers + 1] = "Authorization: Bearer " .. provider.key
    body = { model = provider.model, inputs = prompt, stream = false,
      tools = { { type = "web_search" } }, completion_args = { max_tokens = provider.maxTokens } }
  elseif (provider.id == "openai" or provider.id == "xai") and browsing then
    endpoint = endpoint:gsub("/chat/completions$", "") .. "/responses"
    headers[#headers + 1] = "Authorization: Bearer " .. provider.key
    body = { model = provider.model, input = prompt, stream = false,
      max_output_tokens = provider.maxTokens, tools = { { type = "web_search" } } }
  else
    if provider.id == "gemini" then endpoint = endpoint .. "/openai" end
    if not endpoint:match("/chat/completions$") then endpoint = endpoint .. "/chat/completions" end
    headers[#headers + 1] = "Authorization: Bearer " .. provider.key
    body.tools = browsing and {} or { { type = "function", ["function"] = search } }
    -- OpenAI reasoning models require max_completion_tokens. Other
    -- Chat Completions providers generally accept max_tokens.
    if provider.id == "openai" and endpoint == "https://api.openai.com/v1/chat/completions" then
      body.max_completion_tokens = provider.maxTokens
    else
      body.max_tokens = provider.maxTokens
    end
    if provider.id == "openrouter" then
      body.usage = { include = true }
      if browsing then
        body.max_tool_calls = toolLimit(provider, mode)
        body.tools[#body.tools + 1] = { type = "openrouter:web_search", parameters = { max_results = 3 } }
        body.tools[#body.tools + 1] = { type = "openrouter:web_fetch" }
      else
        body.max_tool_calls = 2
      end
    elseif provider.id == "groq" and browsing then
      body.stream = false
      body.max_completion_tokens = body.max_tokens
      body.max_tokens = nil
      body.tools = { { type = "browser_search" } }
    end
  end
  return { url = endpoint, method = "POST", headers = headers, body = body }
end

local function decode(json, text)
  if type(text) ~= "string" then return nil end
  local ok, value = pcall(json.decode, text)
  return ok and type(value) == "table" and value or nil
end

function M.parse(provider, response, json, mode)
  local body = decode(json, response.body)
  local status = tonumber(response.status) or 0
  if not response.ok or status < 200 or status >= 300 or (body and body.error) then
    local err = body and body.error
    local message = type(err) == "table" and (err.message or err.type or err.code) or err
    if type(message) ~= "string" and type(message) ~= "number" then
      message = response.error or (not response.ok and "Network transfer failed before the response completed" or "Request failed")
    end
    local prefix = status > 0 and ("HTTP " .. status .. ": ") or ""
    return nil, M.safeError(provider, prefix .. tostring(message))
  end
  if not body then return nil, "Invalid JSON response" end
  local content, reason, assistant
  local calls = {}
  if mode and provider.id == "gemini" then
    local candidate = type(body.candidates) == "table" and body.candidates[1] or {}
    local parts = type(candidate.content) == "table" and candidate.content.parts or {}
    local textParts = {}
    for _, part in ipairs(type(parts) == "table" and parts or {}) do
      if type(part.text) == "string" and part.thought ~= true then
        textParts[#textParts + 1] = part.text
      end
    end
    content = table.concat(textParts, "\n")
    reason = candidate.finishReason
    if reason == "MAX_TOKENS" then reason = "max_tokens" end
  elseif mode and (provider.id == "openai" or provider.id == "xai") then
    local textParts = {}
    for _, item in ipairs(type(body.output) == "table" and body.output or {}) do
      if item.type == "message" then
        for _, part in ipairs(type(item.content) == "table" and item.content or {}) do
          if type(part.text) == "string" then textParts[#textParts + 1] = part.text end
        end
      end
    end
    content = table.concat(textParts, "\n")
    reason = body.status == "incomplete" and "max_tokens" or nil
  elseif mode and provider.id == "mistral" then
    local textParts = {}
    for _, item in ipairs(type(body.outputs) == "table" and body.outputs or {}) do
      if item.type == "message.output" then
        textParts = {}
        if type(item.content) == "string" then textParts[#textParts + 1] = item.content end
        for _, part in ipairs(type(item.content) == "table" and item.content or {}) do
          if part.type == "text" and type(part.text) == "string" then
            textParts[#textParts + 1] = part.text
          end
        end
      end
    end
    content = table.concat(textParts, "\n")
  elseif provider.id == "anthropic" then
    reason = body.stop_reason
    assistant = { role = "assistant", content = body.content }
    local parts = {}
    for _, block in ipairs(type(body.content) == "table" and body.content or {}) do
      if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
        parts[#parts + 1] = block.text
      elseif type(block) == "table" and block.type == "tool_use" then
        calls[#calls + 1] = { id = block.id, name = block.name, arguments = block.input }
      end
    end
    content = table.concat(parts, "\n")
  else
    local choice = type(body.choices) == "table" and body.choices[1]
    local message = type(choice) == "table" and choice.message
    reason = type(choice) == "table" and choice.finish_reason
    content = type(message) == "table" and message.content
    assistant = message
    if type(message) == "table" then
      message.role = "assistant"
      for _, call in ipairs(type(message.tool_calls) == "table" and message.tool_calls or {}) do
        local fn = call["function"] or {}
        calls[#calls + 1] = { id = call.id, name = fn.name, arguments = decode(json, fn.arguments) }
      end
    end
    if type(message) == "table" and message.refusal then return nil, M.safeError(provider, message.refusal) end
  end
  if reason == "length" or reason == "max_tokens" then
    return nil, "Output token limit reached (" .. provider.maxTokens .. "); increase LLM output token limit"
  end
  if reason == "error" then return nil, "Provider ended the response with an error" end
  if #calls > 0 then
    for _, call in ipairs(calls) do
      if type(call.id) ~= "string" or call.id == "" or type(call.name) ~= "string" then
        return nil, "Invalid tool call"
      end
    end
    return { toolCalls = calls, assistant = assistant }
  end
  content = trim(content)
  if content == "" then return nil, "Empty response" .. (reason and (" (" .. reason .. ")") or "") end
  -- Some compatible/local models wrap their JSON in a Markdown code fence.
  content = content:match("^```[%w_-]*%s*\n(.-)\n```$") or content
  local match = decode(json, content)
  if not match then return nil, "Invalid track identification JSON" end
  if match.not_a_song == true then
    if match.result_id ~= nil then return nil, "Response cannot both reject the video and select lyrics" end
    return { not_a_song = true }
  end
  if mode == "album" then
    if match.not_album == true then return { not_album = true } end
    if match.unavailable == true then return { unavailable = true } end
    if type(match.tracks) ~= "table" then return nil, "Album response must contain tracks" end
    return match
  end
  if mode == "lyrics" then
    if match.unavailable == true then return { unavailable = true } end
    for _, key in ipairs({ "artist", "title", "lyrics", "source_url" }) do
      match[key] = trim(match[key])
      if match[key] == "" then return nil, "Web lyrics response needs " .. key end
    end
    if not match.source_url:match("^https?://[^/]+") then return nil, "Invalid lyric source URL" end
    return match
  end
  if match.album == true then return { album = true } end
  if type(match.result_id) ~= "number" and type(match.result_id) ~= "string" then
    return nil, "Track selection must contain result_id from search_lyrics, or 0 for no match"
  end
  return match
end

-- A single selected backend handles the request. Failure must be visible,
-- never silently send the track to another provider.
function M.identify(provider, prompt, host, callback, mode)
  local request, err = M.request(provider, prompt, mode)
  if not request then callback(nil, err) return end
  request.body = host.json.encode(request.body)
  local completed = false
  local cost, webSearchRequests, webFetchRequests
  local function reportedUsage(usage)
    local value = type(usage) == "table" and tonumber(usage.cost) or nil
    if value and value >= 0 and value < math.huge then cost = value end
    local serverTools = type(usage) == "table" and usage.server_tool_use
    local searches = type(serverTools) == "table" and tonumber(serverTools.web_search_requests) or nil
    if searches and searches >= 0 then webSearchRequests = searches end
    local fetches = type(serverTools) == "table" and tonumber(serverTools.web_fetch_requests) or nil
    if fetches and fetches >= 0 then webFetchRequests = fetches end
  end
  local function finish(match, failure)
    if completed then return end
    completed = true
    callback(match, failure and M.safeError(provider, failure) or nil, cost, webSearchRequests, webFetchRequests)
  end
  -- Use the host's long-lived SSE stream; the ordinary HTTP client has a
  -- transfer deadline, while this stream runs until completion or stop().
  local lines, data, parts = {}, {}, {}
  local toolCalls, blocks, reasoning = {}, {}, {}
  local streamed, terminal, reason, streamError, refusal = false, false, nil, nil, nil
  local function event()
    if #data == 0 then return end
    local payload = table.concat(data, "\n")
    data = {}
    if payload == "[DONE]" then terminal = true return end
    local chunk = decode(host.json, payload)
    if not chunk then streamError = { message = "Invalid stream event JSON" } return end
    reportedUsage(chunk.usage)
    if chunk.error then streamError = chunk.error end
    if provider.id == "anthropic" then
      local index = (tonumber(chunk.index) or 0) + 1
      if chunk.type == "content_block_start" and chunk.content_block then
        blocks[index] = chunk.content_block
      elseif chunk.type == "content_block_delta" and chunk.delta then
        local delta = chunk.delta
        local block = blocks[index]
        if delta.type == "text_delta" then
          if not block then block = { type = "text", text = "" } blocks[index] = block end
          block.text = (block.text or "") .. (delta.text or "")
        elseif delta.type == "input_json_delta" and block then
          block.partial_json = (block.partial_json or "") .. (delta.partial_json or "")
        elseif delta.type == "thinking_delta" and block then
          block.thinking = (block.thinking or "") .. (delta.thinking or "")
        elseif delta.type == "signature_delta" and block then
          block.signature = (block.signature or "") .. (delta.signature or "")
        end
      elseif chunk.type == "message_delta" then
        reason = chunk.delta and chunk.delta.stop_reason or reason
      elseif chunk.type == "message_stop" then terminal = true end
    else
      local choice = type(chunk.choices) == "table" and chunk.choices[1]
      if type(choice) == "table" then
        local delta = choice.delta or {}
        if type(delta.content) == "string" then parts[#parts + 1] = delta.content end
        if delta.refusal then refusal = delta.refusal end
        for _, call in ipairs(delta.tool_calls or {}) do
          local index = (tonumber(call.index) or 0) + 1
          local saved = toolCalls[index] or { id = "", type = "function", ["function"] = { name = "", arguments = "" } }
          toolCalls[index] = saved
          if call.id then saved.id = call.id end
          if call.extra_content then saved.extra_content = call.extra_content end
          for _, field in ipairs({ "name", "arguments" }) do
            local value = call["function"] and call["function"][field]
            if value then saved["function"][field] = saved["function"][field] .. value end
          end
        end
        for _, detail in ipairs(delta.reasoning_details or {}) do
          local index = (tonumber(detail.index) or 0) + 1
          local saved = reasoning[index] or {}
          reasoning[index] = saved
          for key, value in pairs(detail) do
            if (key == "text" or key == "data" or key == "signature") and type(value) == "string" then
              saved[key] = (saved[key] or "") .. value
            else saved[key] = value end
          end
        end
        reason = choice.finish_reason or reason
        if choice.error then streamError = choice.error end
      end
    end
  end
  local ok, stream = pcall(host.httpStream, request, function(line)
    if line:sub(1, 5) == "data:" then
      streamed = true
      data[#data + 1] = line:sub(6):gsub("^ ", "")
    elseif line == "" then event()
    elseif line:sub(1, 1) ~= ":" and not line:match("^event:") then
      lines[#lines + 1] = line
    end
  end, function(result)
    if type(result) ~= "table" then finish(nil, "Malformed provider response") return end
    event()
    local response = { ok = result.ok, status = result.status, error = result.error,
      body = table.concat(lines, "\n") }
    if not streamed then
      local body = decode(host.json, response.body)
      reportedUsage(body and body.usage)
    end
    if streamed then
      if not terminal and not reason and not streamError then
        streamError = { message = "Stream ended before the response completed" }
      end
      if provider.id == "anthropic" then
        for _, block in ipairs(blocks) do
          if block.partial_json then
            block.input = decode(host.json, block.partial_json)
            block.partial_json = nil
          end
        end
        response.body = host.json.encode({ error = streamError, stop_reason = reason,
          content = blocks })
      else
        response.body = host.json.encode({ error = streamError, choices = { {
          finish_reason = reason, message = { content = table.concat(parts), refusal = refusal,
            tool_calls = #toolCalls > 0 and toolCalls or nil,
            reasoning_details = #reasoning > 0 and reasoning or nil } } } })
      end
    end
    local parsed, match, failure = pcall(M.parse, provider, response, host.json, mode)
    if parsed then finish(match, failure) else finish(nil, "Malformed provider response") end
  end)
  if not ok then finish(nil, stream)
  elseif not stream then finish(nil, "Could not start request") end
  return ok and stream or nil
end

-- Model-driven search, with selection constrained to actual database results.
-- No confidence score or generated artist/title is used as acceptance evidence.
function M.resolve(provider, prompt, host, search, callback, mode, traceId)
  local messages = { { role = "user", content = prompt } }
  local candidates, queries, steps = {}, 0, 0
  local searchLimit = toolLimit(provider, mode)
  local cancelled, completed, active = false, false, nil
  local reportedCost, hasCost, providerSearches, providerFetches = 0, false, 0, 0
  local started = host.nowMs and host.nowMs() or 0
  local phase = mode == "album" and "album" or mode == "lyrics" and "web-lyrics" or "identify"
  local function log(message)
    if host.log then
      host.log("media-lyrics AI [" .. tostring(traceId or "unknown") .. "/" .. phase .. "] "
        .. M.safeError(provider, message))
    end
  end
  local function elapsedSince(time)
    return host.nowMs and math.floor(host.nowMs() - time) or 0
  end
  local function publicUrl(url)
    return type(url) == "string" and url:match("^[^?#]+") or nil
  end
  log("start provider=" .. provider.name .. " model=" .. provider.model
    .. " tool_limit=" .. tostring(searchLimit))
  local function finish(value, err, outcome)
    if cancelled or completed then return end
    completed = true
    local result = err and ("error=" .. tostring(err)) or outcome
      or (value and (mode == "album" and ("album tracks=" .. #(value.tracks or {}))
        or mode == "lyrics" and ("lyrics source=" .. tostring(publicUrl(value.source_url)))
        or ("selected result_id=" .. tostring(value.id))) or "no match")
    log("finish " .. result .. " steps=" .. steps .. " database_calls=" .. queries
      .. " provider_web_searches=" .. providerSearches
      .. " provider_web_fetches=" .. providerFetches
      .. " elapsed_ms=" .. elapsedSince(started)
      .. (hasCost and (" cost_usd=" .. tostring(reportedCost)) or ""))
    callback(value, err and M.safeError(provider, err) or nil, outcome,
      { cost = hasCost and reportedCost or nil })
  end
  local step
  step = function()
    if cancelled or completed then return end
    steps = steps + 1
    local stepNumber = steps
    local stepStarted = host.nowMs and host.nowMs() or 0
    log("model step=" .. stepNumber .. " start")
    -- Callbacks can complete synchronously in tests or on local validation.
    local answered = false
    local stream = M.identify(provider, mode and prompt or messages, host, function(action, err, cost, webSearchRequests, webFetchRequests)
      answered = true
      if cancelled or completed then return end
      if cost ~= nil then reportedCost, hasCost = reportedCost + cost, true end
      if webSearchRequests then providerSearches = providerSearches + webSearchRequests end
      if webFetchRequests then providerFetches = providerFetches + webFetchRequests end
      log("model step=" .. stepNumber .. " finish elapsed_ms=" .. elapsedSince(stepStarted)
        .. (cost ~= nil and (" cost_usd=" .. tostring(cost)) or "")
        .. (webSearchRequests and (" provider_web_searches=" .. webSearchRequests) or "")
        .. (webFetchRequests and (" provider_web_fetches=" .. webFetchRequests) or "")
        .. (err and (" error=" .. tostring(err)) or ""))
      if err then finish(nil, err) return end
      if not action.toolCalls then
        if action.not_a_song then finish(nil, nil, "not_song") return end
        if mode == "lyrics" then
          if action.unavailable then finish(nil, nil, "unavailable")
          else finish(action) end
          return
        end
        if mode == "album" then
          if action.not_album then finish(nil, nil, "not_album")
          elseif action.unavailable then finish(nil, nil, "unavailable")
          else finish(action) end
          return
        end
        if action.album == true then finish(nil, nil, "album") return end
        if action.result_id == 0 or action.result_id == "0" then finish(nil) return end
        local selected = candidates[tostring(action.result_id)]
        if not selected then finish(nil, "Selected lyrics were not returned by search_lyrics") return end
        finish(selected)
        return
      end
      log("model step=" .. stepNumber .. " requested " .. #action.toolCalls .. " tool call(s)")
      if mode then finish(nil, "Provider returned a client-side tool call during web lookup") return end
      messages[#messages + 1] = action.assistant
      local results = {}
      local function run(index)
        if cancelled or completed then return end
        local call = action.toolCalls[index]
        if not call then
          if provider.id == "anthropic" then
            messages[#messages + 1] = { role = "user", content = results }
          end
          step()
          return
        end
        -- Exhausting database guesses is a miss, so the service can try web lyrics.
        if queries >= searchLimit then finish(nil) return end
        queries = queries + 1
        local args = call.arguments
        local loggedArgs = type(args) == "table"
          and { title = args.title, artist = args.artist } or nil
        log("tool " .. queries .. "/" .. searchLimit .. " name=" .. tostring(call.name)
          .. " args=" .. (loggedArgs and host.json.encode(loggedArgs) or "invalid"))
        local function reply(value)
          if cancelled or completed then return end
          if type(value) == "table" and value.error then
            log("tool " .. queries .. " error=" .. tostring(value.error))
          end
          local content = host.json.encode(value)
          if provider.id == "anthropic" then
            results[#results + 1] = { type = "tool_result", tool_use_id = call.id, content = content }
          else
            messages[#messages + 1] = { role = "tool", tool_call_id = call.id, content = content }
          end
          run(index + 1)
        end
        if call.name ~= "search_lyrics" then reply({ error = "Unknown tool: " .. call.name }) return end
        if type(args) ~= "table" or type(args.title) ~= "string" or trim(args.title) == ""
          or type(args.artist) ~= "string" then
          reply({ error = "Provide a nonempty title and an artist string (empty is allowed)." })
          return
        end
        local queryStarted = host.nowMs and host.nowMs() or 0
        search(args, function(found, searchError)
          if cancelled or completed then return end
          log("tool " .. queries .. " database elapsed_ms=" .. elapsedSince(queryStarted)
            .. " results=" .. #(found or {}))
          if searchError then reply({ error = searchError }) return end
          local summaries = {}
          for _, item in ipairs(found or {}) do
            candidates[tostring(item.id)] = item
            summaries[#summaries + 1] = { result_id = item.id, artist = item.artist, title = item.title,
              album = item.album, duration_seconds = item.duration,
              synced_lyrics = item.synced ~= "", plain_lyrics = item.plain ~= "" }
          end
          for _, summary in ipairs(summaries) do
            log("tool " .. queries .. " candidate=" .. host.json.encode(summary))
          end
          reply({ results = summaries, queries_remaining = searchLimit - queries })
        end)
      end
      run(1)
    end, mode)
    if not answered then active = stream end
  end
  step()
  return { stop = function()
    if not cancelled and not completed then
      log("cancelled steps=" .. steps .. " tools=" .. queries
        .. " elapsed_ms=" .. elapsedSince(started))
    end
    cancelled = true
    if active then active.stop() end
  end }
end

return M
