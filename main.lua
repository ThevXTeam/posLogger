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
  if config.detector and config.detector.name and fs.exists(config.detector.name) then
    local ok, p = pcall(peripheral.wrap, config.detector.name)
    if ok and p then return p end
  end
  local ok, p = pcall(peripheral.find, "playerDetector")
  if ok and p then return p end
  return nil
end

local detector = findDetector()
if not detector then print("posLogger: no playerDetector peripheral found; events will still be handled but player details may be unavailable") end

local function getPlayerInfo(username)
  if not detector then return nil end
  local info = nil
  -- try getPlayer (if exists)
  if detector.getPlayer then
    local ok, res = pcall(detector.getPlayer, detector, username)
    if ok and type(res) == "table" then info = res end
  end
  -- fallback to getPlayerPos
  if not info and detector.getPlayerPos then
    local ok2, res2 = pcall(detector.getPlayerPos, detector, username)
    if ok2 and type(res2) == "table" then info = res2 end
  end
  return info
end

local function buildEmbed(eventType, username, info)
  local title = string.format("%s — %s", username or "unknown", eventType)
  local desc = timestamp()
  if info and info.dimension then desc = desc .. " - " .. tostring(info.dimension) end
  if info and info.uuid then desc = desc .. " - " .. tostring(info.uuid) end

  local embed = { title = title, description = desc, color = (config.remote and config.remote.color) or 3447003 }

  -- add fields for useful properties (x,y,z,yaw,pitch,health etc.)
  if info then
    local fields = {}
    for k, v in pairs(info) do
      if k ~= "uuid" and k ~= "dimension" then
        table.insert(fields, { name = tostring(k), value = tostring(v), inline = true })
      end
    end
    if #fields > 0 then embed.fields = fields end
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

local function sendRemoteForEvent(eventType, username)
  if not config.remote or not config.remote.enabled then return end
  local url = config.remote.webhookURL or ""
  if config.remote.method == "webhook" and (not url or url == "") then
    print("posLogger: webhook URL not configured. Enter webhook URL (blank to cancel):")
    local input = read and read() or io.read()
    if input and input ~= "" then url = input else return end
  end

  local info = getPlayerInfo(username)
  local embed = buildEmbed(eventType, username, info)
  local avatar = "https://mc-heads.net/avatar/" .. (username or "")
  local ok, resp = postWebhook(url, username, avatar, embed)
  if not ok then print("posLogger: webhook post failed: " .. tostring(resp)) end
end

print("posLogger running; listening for playerJoin/playerLeave/playerChangedDimension events")

while true do
  local ev = { os.pullEvent() }
  local name = ev[1]
  if name == "playerJoin" then
    local username = ev[2]
    sendRemoteForEvent("Join", username)
    -- persist local log
    local line = string.format("[%s] JOIN %s", timestamp(), tostring(username))
    local fh = fs.open("/poslogs.log", "a")
    if fh then fh.writeLine(line); fh.close() end
  elseif name == "playerLeave" then
    local username = ev[2]
    sendRemoteForEvent("Leave", username)
    local line = string.format("[%s] LEAVE %s", timestamp(), tostring(username))
    local fh = fs.open("/poslogs.log", "a")
    if fh then fh.writeLine(line); fh.close() end
  elseif name == "playerChangedDimension" then
    local username = ev[2]
    local fromDim = ev[3]
    local toDim = ev[4]
    sendRemoteForEvent("ChangedDimension", username)
    local line = string.format("[%s] DIMCHANGE %s %s -> %s", timestamp(), tostring(username), tostring(fromDim), tostring(toDim))
    local fh = fs.open("/poslogs.log", "a")
    if fh then fh.writeLine(line); fh.close() end
  end
end
