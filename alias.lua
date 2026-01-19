-- create a `posLogger` alias that delegates to `/vx/posLogger/main.lua` when available
if fs.exists("/vx/posLogger/main.lua") then
  pcall(function() shell.setAlias("posLogger", "/vx/posLogger/main.lua") end)
else
  print("No posLogger script found at /vx/posLogger/main.lua")
end