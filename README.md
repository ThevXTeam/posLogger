# posLogger

Listens to Player Detector events (`playerJoin`, `playerLeave`, `playerChangedDimension`) and posts player info to a webhook.

Usage
-
1. Edit `repos/posLogger/config.lua` to enable remote and set `remote.webhookURL`.
2. Start the logger in the emulator:

```lua
shell.run("/repos/posLogger/main.lua")
```

Or use the alias (after running `repos/posLogger/alias.lua`):

```lua
posLogger
```

Files
-
- [repos/posLogger/main.lua](repos/posLogger/main.lua#L1-L200)
- [repos/posLogger/config.lua](repos/posLogger/config.lua#L1-L200)
- [repos/posLogger/webhook_test.lua](repos/posLogger/webhook_test.lua#L1-L200)

