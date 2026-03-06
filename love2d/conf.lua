-- Siegecraft — LÖVE config
function love.conf(t)
  t.identity = "bom"
  t.version = "11.4"
  t.window.title = "Siegecraft"
  t.window.width = 1920
  t.window.height = 1080
  t.window.resizable = true
  t.window.highdpi = true    -- render at native pixel resolution (DPI-aware)
  t.window.msaa = 4          -- 4x multi-sample anti-aliasing
  t.console = false
end
