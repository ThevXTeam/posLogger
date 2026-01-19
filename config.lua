-- posLogger configuration
return {
  -- Remote webhook settings
  remote = {
    enabled = false,
    method = "webhook",
    webhookURL = "",
    color = 3447003,
    flags = 4096,
  },

  -- Player detector preferences
  detector = {
    -- optional: prefer a specific peripheral name (nil to auto-find)
    name = nil,
  }
}
