-- posLogger configuration
return {
  -- Remote webhook settings
  remote = {
    enabled = false,
    method = "webhook",
    webhookURL = "",
    color = 3447003,
    -- Per-event colors (can override `color` when sending event embeds)
    joinColor = 3066993,       -- green-ish for joins
    leaveColor = 15158332,     -- red-ish for leaves
    changeDimColor = 10181046, -- purple-ish for dimension changes
    flags = 4096,
  },

  -- Player detector preferences
  detector = {
    -- optional: prefer a specific peripheral name (nil to auto-find)
    name = nil,
  }
}
