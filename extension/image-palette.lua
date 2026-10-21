-- Image Palette: shows a palette loaded from an image as a 2D grid that
-- keeps the image's layout, so color ramps stay organized in rows/columns.

local MIN_CELL = 4
local MAX_CELL = 32
local DEFAULT_MAX_VIEW = 320 -- fit the longest side of the grid to this (px)...
local DEFAULT_SHRINK = 4      -- ...then shrink cells by this, like pressing "-" twice
local CELL_STEP = 2           -- cell size change per "-" / "+" press
local MAX_INDEXED_COLORS = 256
local MAX_IMAGE_SIZE = 96 -- max width/height (px); larger palettes don't fit the view

-- Palette order options when replacing the current palette.
local ORDER_READING = "Reading order (left to right, top to bottom)"
local ORDER_DEFAULT = "Aseprite default (same as Load Palette)"

-- Key for the data this plugin stores on sprites (saved in .aseprite files).
local PROPERTIES_KEY = "jgabel/image-palette"

local plugin_ -- set in init()
local siteListener
local view = {
  grid = nil,       -- { width, height, path, hasTransparent, cells[y][x] = Color or false }
  dlg = nil,
  listeners = {},
  hover = nil,      -- { x, y } of the cell under the mouse
  picked = {},      -- picked.fg / picked.bg = { x, y } of the cell last clicked
  sprite = nil,     -- the active sprite the view was last updated for
  busy = false,     -- true while we open/close sprites ourselves
}

-- Grids already read from disk, by path, so switching tabs doesn't reload.
local gridCache = {}

-- Helpers ---------------------------------------------------------------------

local function colorKey(c)
  return string.format("%d,%d,%d,%d", c.red, c.green, c.blue, c.alpha)
end

local function hex(c)
  if c.alpha < 255 then
    return string.format("#%02X%02X%02X%02X", c.red, c.green, c.blue, c.alpha)
  end
  return string.format("#%02X%02X%02X", c.red, c.green, c.blue)
end

local function fileName(path)
  return app.fs.fileName(path)
end

-- Loads every pixel of the image at `path` into a 2D grid of colors. Fully
-- transparent pixels become empty cells, which lets gaps separate ramps.
local function loadGrid(path)
  if not path or not app.fs.isFile(path) then
    return nil, "File not found: " .. tostring(path)
  end

  local previous = app.sprite
  view.busy = true -- opening/closing the image fires sitechange
  local ok, spr = pcall(function() return Sprite{ fromFile = path } end)
  if not ok or not spr then
    view.busy = false
    return nil, "Could not open image: " .. path
  end

  if spr.width > MAX_IMAGE_SIZE or spr.height > MAX_IMAGE_SIZE then
    local w, h = spr.width, spr.height
    spr:close()
    if previous then app.sprite = previous end
    view.busy = false
    return nil, string.format(
      "The image is %dx%d. Palette images can be at most %dx%d pixels.",
      w, h, MAX_IMAGE_SIZE, MAX_IMAGE_SIZE)
  end

  -- Flatten to RGB so indexed/grayscale images and multiple layers just work.
  local img = Image(spr.width, spr.height, ColorMode.RGB)
  img:drawSprite(spr, 1)
  spr:close()
  if previous then app.sprite = previous end
  view.busy = false

  local pc = app.pixelColor
  local cells = {}
  local hasTransparent = false
  for y = 0, img.height - 1 do
    local row = {}
    for x = 0, img.width - 1 do
      local v = img:getPixel(x, y)
      local a = pc.rgbaA(v)
      if a == 0 then
        row[x + 1] = false
        hasTransparent = true
      else
        row[x + 1] = Color{ r = pc.rgbaR(v), g = pc.rgbaG(v), b = pc.rgbaB(v), a = a }
      end
    end
    cells[y + 1] = row
  end

  local grid = {
    width = img.width,
    height = img.height,
    path = path,
    hasTransparent = hasTransparent,
    cells = cells,
  }
  gridCache[path] = grid
  return grid
end

local function cachedGrid(path)
  if gridCache[path] then return gridCache[path] end
  return loadGrid(path)
end

-- Unique colors of the grid in reading order (left-to-right, top-to-bottom).
local function uniqueColors(grid)
  local seen, list = {}, {}
  for y = 1, grid.height do
    for x = 1, grid.width do
      local c = grid.cells[y][x]
      if c then
        local k = colorKey(c)
        if not seen[k] then
          seen[k] = true
          list[#list + 1] = c
        end
      end
    end
  end
  return list
end

local TRANSPARENT = Color{ r = 0, g = 0, b = 0, a = 0 }

-- Colors in the order Aseprite's own Load Palette uses (color quantization of
-- the image, which always puts a transparent entry at index 0).
local function defaultOrderColors(grid)
  local pal = Palette{ fromFile = grid.path }
  if not pal then return nil end
  local list = {}
  for i = 0, #pal - 1 do
    local c = pal:getColor(i)
    if c.alpha > 0 then list[#list + 1] = c end
  end
  return list
end

-- options: { order = ORDER_*, includeTransparent = bool }
local function applyPalette(spr, grid, options)
  local colors
  if options.order == ORDER_DEFAULT then
    colors = defaultOrderColors(grid)
    if not colors then
      app.alert("Aseprite could not load a palette from this image.")
      return false
    end
  else
    colors = uniqueColors(grid)
  end
  if #colors == 0 then
    app.alert("The image has no opaque pixels.")
    return false
  end
  if options.includeTransparent and grid.hasTransparent then
    table.insert(colors, 1, TRANSPARENT)
  end
  if spr.colorMode == ColorMode.INDEXED and #colors > MAX_INDEXED_COLORS then
    app.alert{
      title = "Image Palette",
      text = {
        string.format("The image has %d unique colors.", #colors),
        string.format("Indexed sprites support at most %d.", MAX_INDEXED_COLORS),
      },
    }
    return false
  end

  local pal = Palette(#colors)
  for i, c in ipairs(colors) do
    pal:setColor(i - 1, c)
  end
  app.transaction("Load Palette from Image", function()
    spr:setPalette(pal)
  end)
  return true
end

local function defaultCellSize(grid)
  local longest = math.max(grid.width, grid.height)
  local size = math.min(MAX_CELL, math.floor(DEFAULT_MAX_VIEW / longest))
  return math.max(MIN_CELL, size - DEFAULT_SHRINK)
end

-- Cell size chosen with -/+ for each palette image, by path.
local function cellSizes()
  local prefs = plugin_.preferences
  if type(prefs.cellSizes) ~= "table" then prefs.cellSizes = {} end
  return prefs.cellSizes
end

local function cellSize()
  return cellSizes()[view.grid.path] or defaultCellSize(view.grid)
end

-- View ------------------------------------------------------------------------

local closeView, openView

local function stopListening()
  for _, id in ipairs(view.listeners) do
    app.events:off(id)
  end
  view.listeners = {}
end

local function repaint()
  if view.dlg then view.dlg:repaint() end
end

local function contrastColor(c)
  local luma = 0.299 * c.red + 0.587 * c.green + 0.114 * c.blue
  if luma > 140 then return Color{ r = 0, g = 0, b = 0 } end
  return Color{ r = 255, g = 255, b = 255 }
end

-- Triangle markers like the standard palette: foreground in the top-left
-- corner, background in the bottom-right corner.
local function drawMarker(gc, x, y, cs, color, corner)
  local m = math.max(3, math.floor(cs / 2))
  gc.color = contrastColor(color)
  gc:beginPath()
  if corner == "fg" then
    gc:moveTo(x, y)
    gc:lineTo(x + m, y)
    gc:lineTo(x, y + m)
  else
    gc:moveTo(x + cs, y + cs)
    gc:lineTo(x + cs - m, y + cs)
    gc:lineTo(x + cs, y + cs - m)
  end
  gc:closePath()
  gc:fill()
end

-- The one cell to mark for a selected color: the cell that was clicked to
-- pick it, if it still holds that color, otherwise the first cell with that
-- color in reading order. Marking every duplicate gets too noisy.
local function markedCell(grid, key, picked)
  if picked then
    local row = grid.cells[picked.y]
    local c = row and row[picked.x]
    if c and colorKey(c) == key then return picked.x, picked.y end
  end
  for y = 1, grid.height do
    for x = 1, grid.width do
      local c = grid.cells[y][x]
      if c and colorKey(c) == key then return x, y end
    end
  end
end

local function paint(ev)
  local gc = ev.context
  local grid = view.grid
  if not grid then return end
  local cs = cellSize()

  for y = 1, grid.height do
    for x = 1, grid.width do
      local c = grid.cells[y][x]
      if c then
        gc.color = c
        gc:fillRect(Rectangle((x - 1) * cs, (y - 1) * cs, cs, cs))
      end
    end
  end

  for _, corner in ipairs{ "fg", "bg" } do
    local color = corner == "fg" and app.fgColor or app.bgColor
    local x, y = markedCell(grid, colorKey(color), view.picked[corner])
    if x then
      drawMarker(gc, (x - 1) * cs, (y - 1) * cs, cs, grid.cells[y][x], corner)
    end
  end

  if view.hover then
    local hx, hy = view.hover.x, view.hover.y
    local c = grid.cells[hy][hx]
    if c then
      gc.color = contrastColor(c)
      gc.strokeWidth = 1
      gc:strokeRect(Rectangle((hx - 1) * cs, (hy - 1) * cs, cs, cs))
    end
  end
end

local function cellAt(ev)
  local cs = cellSize()
  local x = math.floor(ev.x / cs) + 1
  local y = math.floor(ev.y / cs) + 1
  local grid = view.grid
  if x < 1 or y < 1 or x > grid.width or y > grid.height then return nil end
  return x, y
end

local function updateInfo()
  if not view.dlg then return end
  local text = ""
  if view.hover then
    local c = view.grid.cells[view.hover.y][view.hover.x]
    if c then
      text = string.format("%s  (%d, %d)", hex(c), view.hover.x - 1, view.hover.y - 1)
    end
  end
  view.dlg:modify{ id = "info", text = text }
end

local function onMouseMove(ev)
  local x, y = cellAt(ev)
  local changed
  if x then
    changed = not view.hover or view.hover.x ~= x or view.hover.y ~= y
    view.hover = { x = x, y = y }
  else
    changed = view.hover ~= nil
    view.hover = nil
  end
  if changed then
    updateInfo()
    repaint()
  end
end

local function onMouseDown(ev)
  local x, y = cellAt(ev)
  if not x then return end
  local c = view.grid.cells[y][x]
  if not c then return end
  -- Copy so the app never holds a reference into our grid.
  local color = Color{ r = c.red, g = c.green, b = c.blue, a = c.alpha }
  if ev.button == MouseButton.RIGHT then
    view.picked.bg = { x = x, y = y }
    app.bgColor = color
  else
    view.picked.fg = { x = x, y = y }
    app.fgColor = color
  end
  repaint()
end

local function saveBounds()
  if view.dlg then
    local b = view.dlg.bounds
    plugin_.preferences.x = b.x
    plugin_.preferences.y = b.y
  end
end

local function setCellSize(size)
  cellSizes()[view.grid.path] = math.max(MIN_CELL, math.min(MAX_CELL, size))
  openView(view.grid) -- rebuild with the new canvas size, keeping position
end

closeView = function()
  stopListening()
  if view.dlg then
    saveBounds()
    local dlg = view.dlg
    view.dlg = nil
    dlg:close()
  end
end

openView = function(grid)
  closeView()
  if not view.grid or view.grid.path ~= grid.path then view.picked = {} end
  view.grid = grid
  view.hover = nil

  local cs = cellSize()
  local dlg = Dialog{
    title = "Image Palette: " .. fileName(grid.path),
    onclose = function()
      if view.dlg then -- closed by the user, not by us
        plugin_.preferences.hidden = true
        saveBounds()
        view.dlg = nil
        stopListening()
      end
    end,
  }
  dlg:canvas{
    id = "grid",
    width = grid.width * cs,
    height = grid.height * cs,
    onpaint = paint,
    onmousemove = onMouseMove,
    onmousedown = onMouseDown,
  }
  dlg:newrow()
  dlg:label{ id = "info", text = "" }
  dlg:button{ text = "-", onclick = function() setCellSize(cs - CELL_STEP) end }
  dlg:button{ text = "+", onclick = function() setCellSize(cs + CELL_STEP) end }
  view.dlg = dlg

  view.listeners = {
    app.events:on("fgcolorchange", repaint),
    app.events:on("bgcolorchange", repaint),
  }

  dlg:show{ wait = false }

  -- Place it where it was last left, or by default under the color bar.
  local b = dlg.bounds
  local prefs = plugin_.preferences
  local x, y = prefs.x, prefs.y
  if not x and app.window then
    x = 0
    y = math.floor(app.window.height / 2)
  end
  if x then
    if app.window then
      x = math.max(0, math.min(x, app.window.width - b.width))
      y = math.max(0, math.min(y, app.window.height - b.height))
    end
    dlg.bounds = Rectangle(x, y, b.width, b.height)
  end
end

-- Commands --------------------------------------------------------------------

local function loadCommand()
  local spr = app.sprite
  local dlg = Dialog{ title = "Load Palette from Image" }
  dlg:file{
    id = "file",
    label = "Image",
    open = true,
    filename = (spr and spr.properties(PROPERTIES_KEY).path)
      or plugin_.preferences.lastPath or "",
    filetypes = { "png", "gif", "bmp", "aseprite", "ase", "jpg", "jpeg", "webp", "tga", "pcx" },
  }
  local prefs = plugin_.preferences
  local function setOptionsEnabled(enabled)
    dlg:modify{ id = "order", enabled = enabled }
    dlg:modify{ id = "transparent", enabled = enabled }
  end
  dlg:check{
    id = "apply",
    text = "Replace the current palette with these colors",
    selected = spr ~= nil,
    enabled = spr ~= nil,
    onclick = function() setOptionsEnabled(dlg.data.apply) end,
  }
  dlg:combobox{
    id = "order",
    label = "Order",
    option = prefs.order or ORDER_READING,
    options = { ORDER_READING, ORDER_DEFAULT },
    enabled = spr ~= nil,
  }
  dlg:check{
    id = "transparent",
    text = "Include transparent color at index 0 (if the image has transparent pixels)",
    selected = prefs.includeTransparent ~= false,
    enabled = spr ~= nil,
  }
  dlg:button{ id = "ok", text = "&OK", focus = true }
  dlg:button{ id = "cancel", text = "&Cancel" }
  dlg:show()

  local data = dlg.data
  if not data.ok or not data.file or data.file == "" then return end

  local grid, err = loadGrid(data.file)
  if not grid then
    app.alert(err)
    return
  end

  if data.apply and app.sprite then
    prefs.order = data.order
    prefs.includeTransparent = data.transparent
    applyPalette(app.sprite, grid, {
      order = data.order,
      includeTransparent = data.transparent,
    })
  end

  if app.sprite then
    app.sprite.properties(PROPERTIES_KEY).path = grid.path
  end
  prefs.lastPath = grid.path
  prefs.hidden = false
  if app.sprite then openView(grid) end
end

-- The palette image for a sprite. A sprite without one gets the last palette
-- image loaded, and keeps it from then on.
local function spritePalettePath(spr)
  local props = spr.properties(PROPERTIES_KEY)
  if not props.path and plugin_.preferences.lastPath then
    props.path = plugin_.preferences.lastPath
  end
  return props.path
end

-- Shows the active sprite's palette, or hides the view on the Home tab.
local function syncView(reload)
  local spr = app.sprite
  view.sprite = spr
  local path = spr and spritePalettePath(spr)
  if not path or plugin_.preferences.hidden then
    closeView()
    return true
  end
  if reload then gridCache[path] = nil end
  if view.dlg and view.grid.path == path and not reload then return true end

  local grid, err = cachedGrid(path)
  if not grid then
    closeView()
    return false, err
  end
  openView(grid)
  return true
end

local function onSiteChange()
  if view.busy or app.sprite == view.sprite then return end
  syncView(false) -- a missing image just leaves the view closed
end

local function showCommand()
  local prefs = plugin_.preferences
  if view.dlg then
    prefs.hidden = true
    closeView()
    return
  end
  prefs.hidden = false
  local ok, err = syncView(true)
  if not ok then app.alert(err) end
end

function init(plugin)
  plugin_ = plugin

  plugin:newCommand{
    id = "ImagePaletteLoad",
    title = "Load Palette from Image (2D)...",
    group = "palette_files",
    onclick = loadCommand,
  }

  plugin:newCommand{
    id = "ImagePaletteToggle",
    title = "Show/Hide Image Palette",
    group = "palette_files",
    onclick = showCommand,
    onenabled = function()
      return view.dlg ~= nil or
        (app.sprite ~= nil and spritePalettePath(app.sprite) ~= nil)
    end,
  }

  siteListener = app.events:on("sitechange", onSiteChange)
end

function exit(plugin)
  if siteListener then app.events:off(siteListener) end
  closeView()
end
