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

  -- Add event-specific title/description without skipping fields
  if eventType == "ChangedDimension" then
    local from = tostring(extra and extra.from or info.dimension or "unknown")
    local to = tostring(extra and extra.to or info.dimension or "unknown")
    embed.title = "Change Dimension"
    embed.description = string.format("%s -> %s", from, to)
  elseif eventType == "Join" then
    embed.title = "Joined server"
  end

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

local function sendRemoteForEvent(eventType, username, extra)
  if not config.remote or not config.remote.enabled then return end
  local url = config.remote.webhookURL or ""
  if config.remote.method == "webhook" and (not url or url == "") then
    print("posLogger: webhook URL not configured. Enter webhook URL (blank to cancel):")
    local input = read and read() or io.read()
    if input and input ~= "" then url = input else return end
  end

  local info = getPlayerInfo(username)
  local now = (os.time and os.time()) or nil
  local prevCache = playerCache[username]

  if info and type(info) == "table" then
    -- update cache with fresh info
    playerCache[username] = { info = info, ts = now }
  else
    -- if we couldn't fetch live info (likely on leave), try cached value
    if eventType == "Leave" and prevCache and prevCache.info then
      info = prevCache.info
    end
  end

  local embed = buildEmbed(eventType, username, info, extra)

  -- For Leave events, set title and description that reference cached timestamp
  if eventType == "Leave" then
    embed.title = "Left server"
    local cacheEntry = prevCache or playerCache[username]
    if cacheEntry and cacheEntry.ts then
      local ts = cacheEntry.ts
      local tsStr = (os.date and os.date("%Y-%m-%d - %H:%M:%S", ts)) or tostring(ts)
      local age = now and (now - ts) or nil
      if age then
        embed.description = string.format("information from %s (%ds before leave)", tsStr, age)
      else
        embed.description = string.format("information from %s", tsStr)
      end
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

while true do
  local ev = { os.pullEvent() }
  local name = ev[1]
  if name == "playerJoin" then
    local username = ev[2]
    local dim = ev[3]
    sendRemoteForEvent("Join", username, { dim = dim })
    -- persist local log
    local line = string.format("[%s] JOIN %s", timestamp(), tostring(username))
    local fh = fs.open("/poslogs.log", "a")
    if fh then fh.writeLine(line); fh.close() end
  elseif name == "playerLeave" then
    local username = ev[2]
    local dim = ev[3]
    sendRemoteForEvent("Leave", username, { dim = dim })
    local line = string.format("[%s] LEAVE %s", timestamp(), tostring(username))
    local fh = fs.open("/poslogs.log", "a")
    if fh then fh.writeLine(line); fh.close() end
  elseif name == "playerChangedDimension" then
    local username = ev[2]
    local fromDim = ev[3]
    local toDim = ev[4]
    sendRemoteForEvent("ChangedDimension", username, { from = fromDim, to = toDim })
    local line = string.format("[%s] DIMCHANGE %s %s -> %s", timestamp(), tostring(username), tostring(fromDim), tostring(toDim))
    local fh = fs.open("/poslogs.log", "a")
    if fh then fh.writeLine(line); fh.close() end
  end
end
