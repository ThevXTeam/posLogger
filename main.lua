-- posLogger: listens to playerDetector events and posts player info to webhook
local textutils = textutils

-- load config robustly
local config = nil
do
  local ok, c = pcall(require, "config")
  if ok and type(c) == "table" then config = c end
  if not config and fs.exists("/repos/posLogger/config.lua") then
    local ok2, c2 = pcall(dofile, "/repos/posLogger/config.lua")
    if ok2 and type(c2) == "table" then config = c2 end
  end
  if not config then config = { remote = { enabled = false } } end
end

local function timestamp()
  if os and os.date then return os.date("%Y-%m-%d - %H:%M:%S") end
  return tostring(math.floor(os.time and os.time() or os.clock()))
end

local function findDetector()
  if config.detector and config.detector.name then
    local ok, p = pcall(function() return peripheral.wrap(config.detector.name) end)
    if ok and p then return p end
  end
  local ok2, p2 = pcall(function() return peripheral.find("playerDetector") end)
  if ok2 and p2 then return p2 end
  return nil
end

local detector = findDetector()
if not detector then print("posLogger: no playerDetector peripheral found; events will still be handled but player details may be unavailable") end

-- cache last-seen player info so we can report it on leave events
local playerCache = {}

-- tracker timer id (if tracker enabled)
local trackerInterval = nil
local trackedPlayers = nil

-- initialize tracker config (do not start timers here; trackerLoop will manage sleeping)
if config.tracker and config.tracker.enabled then
  trackerInterval = tonumber(config.tracker.interval) or 1
  trackedPlayers = config.tracker.players or {}
end

local function getPlayerInfo(username)
  if not detector then return nil end
  local info = nil
  -- try getPlayer (if exists)
  if detector.getPlayer then
    local ok, res = pcall(function() return detector.getPlayer(username) end)
    if ok and type(res) == "table" then info = res end
  end
  -- fallback to getPlayerPos
  if not info and detector.getPlayerPos then
    local ok2, res2 = pcall(function() return detector.getPlayerPos(username) end)
    if ok2 and type(res2) == "table" then info = res2 end
  end
  return info
end

local function buildEmbed(eventType, username, info, extra)
  info = info or {}
  local function numfmt(v)
    if v == nil then return nil end
    return tostring(v)
  end

  -- Build CURRENT and SPAWNPOINT fields (always present)
  local dim = info.dimension or (extra and extra.dim) or "unknown"

  local curLines = {}
  if info.x or info.y or info.z then
    table.insert(curLines, "x: " .. (numfmt(info.x) or ""))
    table.insert(curLines, "y: " .. (numfmt(info.y) or ""))
    table.insert(curLines, "z: " .. (numfmt(info.z) or ""))
  end
  if info.yaw ~= nil then table.insert(curLines, "") end
  if info.yaw ~= nil then table.insert(curLines, "yaw: " .. numfmt(info.yaw)) end
  if info.pitch ~= nil then table.insert(curLines, "pitch: " .. numfmt(info.pitch)) end
  if info.eyeHeight ~= nil then table.insert(curLines, "eyeHeight: " .. numfmt(info.eyeHeight)) end

  local hpLineParts = {}
  if info.health ~= nil then table.insert(hpLineParts, "hp " .. numfmt(info.health) .. (info.maxHealth and ("/" .. numfmt(info.maxHealth)) or "")) end
  if info.airSupply ~= nil then table.insert(hpLineParts, "airSupply: " .. numfmt(info.airSupply)) end
  if #hpLineParts > 0 then
    table.insert(curLines, "")
    table.insert(curLines, table.concat(hpLineParts, " "))
  end

  local currentField = { name = ("CURRENT\n" .. tostring(dim)), value = table.concat(curLines, "\n") }

  local spawnLines = {}
  if info.respawnPosition and type(info.respawnPosition) == "table" then
    table.insert(spawnLines, "x: " .. numfmt(info.respawnPosition.x))
    table.insert(spawnLines, "y: " .. numfmt(info.respawnPosition.y))
    table.insert(spawnLines, "z: " .. numfmt(info.respawnPosition.z))
  end
  if info.respawnAngle ~= nil then
    if #spawnLines > 0 then table.insert(spawnLines, "") end
    table.insert(spawnLines, "respawnAngle: " .. numfmt(info.respawnAngle))
  end
  local spawnDim = info.respawnDimension or "unknown"
  local spawnField = { name = ("SPAWNPOINT\n" .. tostring(spawnDim)), value = (#spawnLines > 0) and table.concat(spawnLines, "\n") or "" }

  local baseColor = (config.remote and config.remote.color) or 3447003
  local evtColor = baseColor
  if eventType == "Join" then
    evtColor = (config.remote and config.remote.joinColor) or baseColor
  elseif eventType == "Leave" then
    evtColor = (config.remote and config.remote.leaveColor) or baseColor
  elseif eventType == "ChangedDimension" then
    evtColor = (config.remote and config.remote.changeDimColor) or baseColor
  end

  local embed = { color = evtColor, fields = { currentField, spawnField } }

  return embed
end

local function postWebhook(url, username, avatar_url, embed)
  if not http then return false, "http unavailable" end
  local payloadTable = {
    content = nil,
    embeds = { embed },
    username = tostring(username or "posLogger"),
    avatar_url = tostring(avatar_url or ""),
    attachments = {},
    flags = (config.remote and config.remote.flags) or 4096,
  }
  local payload = textutils.serializeJSON(payloadTable)
  local headers = { ["Content-Type"] = "application/json" }
  local ok, resp = pcall(http.post, url, payload, headers)
  if not ok or not resp then return false, resp end
  local body = resp.readAll and resp.readAll()
  return true, body or resp
end

local function sendRemoteForEvent(eventType, username, extra, eventTsNum, eventTsStr)
  if not config.remote or not config.remote.enabled then return end
  local url = config.remote.webhookURL or ""
  if config.remote.method == "webhook" and (not url or url == "") then
    print("posLogger: webhook URL not configured. Enter webhook URL (blank to cancel):")
    local input = read and read() or io.read()
    if input and input ~= "" then url = input else return end
  end

  local now = eventTsNum or ((type(os.time) == "function" and os.time()) or (type(os.clock) == "function" and math.floor(os.clock())))
  local eventTimeStr = eventTsStr or timestamp()
  local prevCache = playerCache[username]
  local info = nil
  local usedCache = false

  if eventType == "Leave" then
    -- prefer cached info for Leave events
    if prevCache and prevCache.info then
      info = prevCache.info
      usedCache = true
    else
      -- fallback to live info if no cache
      info = getPlayerInfo(username)
    end
  else
    -- regular event: fetch live info and update cache if available
    info = getPlayerInfo(username)
    if info and type(info) == "table" then
      playerCache[username] = { info = info, ts = (now and tonumber(now)) or nil, ts_str = timestamp() }
    end
  end

  local embed = buildEmbed(eventType, username, info, extra)

  -- set event titles with the exact event timestamp (eventTimeStr)
  if eventType == "ChangedDimension" then
    embed.title = string.format("Change Dimension at %s", eventTimeStr)
    local from = tostring(extra and extra.from or info.dimension or "unknown")
    local to = tostring(extra and extra.to or info.dimension or "unknown")
    embed.description = string.format("%s -> %s", from, to)
  elseif eventType == "Join" then
    embed.title = string.format("Joined server at %s", eventTimeStr)
  elseif eventType == "Leave" then
    embed.title = string.format("Left server at %s", eventTimeStr)
    local cacheEntry = prevCache or playerCache[username]
    if cacheEntry and ((cacheEntry.ts and cacheEntry.ts > 0) or cacheEntry.ts_str) then
      local tsStr = cacheEntry.ts_str or ((cacheEntry.ts and (os.date and os.date("%Y-%m-%d - %H:%M:%S", cacheEntry.ts))) or tostring(cacheEntry.ts))
        embed.description = string.format("information from %s", tsStr)
    else
      embed.description = "no prior information available"
    end
  end

  local avatar = "https://mc-heads.net/avatar/" .. (username or "")
  local ok, resp = postWebhook(url, username, avatar, embed)
  if not ok then print("posLogger: webhook post failed: " .. tostring(resp)) end

  -- cleanup cache on leave
  if eventType == "Leave" then playerCache[username] = nil end
end

print("posLogger running; listening for playerJoin/playerLeave/playerChangedDimension events")

-- Event loop (handles incoming player events)
local function eventLoop()
  while true do
    local ev = { os.pullEvent() }
    local name = ev[1]
    if name == "playerJoin" then
      local username = ev[2]
      local dim = ev[3]
      local evTs = (type(os.time) == "function" and os.time()) or (type(os.clock) == "function" and math.floor(os.clock()))
      sendRemoteForEvent("Join", username, { dim = dim }, evTs, timestamp())
      local line = string.format("[%s] JOIN %s", timestamp(), tostring(username))
      local fh = fs.open("/poslogs.log", "a")
      if fh then fh.writeLine(line); fh.close() end
    elseif name == "playerLeave" then
      local username = ev[2]
      local dim = ev[3]
      local evTs = (type(os.time) == "function" and os.time()) or (type(os.clock) == "function" and math.floor(os.clock()))
      sendRemoteForEvent("Leave", username, { dim = dim }, evTs, timestamp())
      local line = string.format("[%s] LEAVE %s", timestamp(), tostring(username))
      local fh = fs.open("/poslogs.log", "a")
      if fh then fh.writeLine(line); fh.close() end
    elseif name == "playerChangedDimension" then
      local username = ev[2]
      local fromDim = ev[3]
      local toDim = ev[4]
      local evTs = (type(os.time) == "function" and os.time()) or (type(os.clock) == "function" and math.floor(os.clock()))
      sendRemoteForEvent("ChangedDimension", username, { from = fromDim, to = toDim }, evTs, timestamp())
      local line = string.format("[%s] DIMCHANGE %s %s -> %s", timestamp(), tostring(username), tostring(fromDim), tostring(toDim))
      local fh = fs.open("/poslogs.log", "a")
      if fh then fh.writeLine(line); fh.close() end
    end
  end
end

-- Tracker loop (polls configured players on interval)
local function trackerLoop()
  if not (config.tracker and config.tracker.enabled and trackerInterval and trackerInterval > 0 and trackedPlayers and #trackedPlayers > 0) then
    -- nothing to track; sleep indefinitely but keep coroutine alive
    while true do
      if type(os.sleep) == "function" then os.sleep(10) else os.pullEvent("timer") end
    end
  end

  while true do
    if type(os.sleep) == "function" then
      os.sleep(trackerInterval)
    else
      local t = os.startTimer(trackerInterval)
      local _, id = os.pullEvent("timer")
      if id ~= t then
        -- continue waiting until expected timer fires
        goto continue_wait
      end
    end
    ::continue_wait::

    if trackedPlayers and #trackedPlayers > 0 then
      for _, pname in ipairs(trackedPlayers) do
        local ok, info = pcall(getPlayerInfo, pname)
        local now_ts = (type(os.time) == "function" and os.time()) or (type(os.clock) == "function" and math.floor(os.clock()))
        if ok and type(info) == "table" then
          playerCache[pname] = { info = info, ts = (now_ts and tonumber(now_ts)) or nil, ts_str = timestamp() }
        end
      end
    end
  end
end

-- Run event and tracker loops concurrently when `parallel.waitForAny` is available.
if parallel and type(parallel.waitForAny) == "function" then
  parallel.waitForAny(eventLoop, trackerLoop)
else
  -- fallback: run event loop only (tracker will not run concurrently)
  eventLoop()
end
