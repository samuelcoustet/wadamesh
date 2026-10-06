-- Tetris — wadamesh Lua app
-- Swipe left/right to move  |  Swipe up to rotate  |  Swipe down to hard-drop
-- Keyboard: arrows to move/rotate, Enter or Space to hard-drop
-- Contributed by samuelcoustet

local ui, sys, store, timer = wada.ui, wada.sys, wada.store, wada.timer
local C = ui.colors

local app = {}

local COLS, ROWS = 10, 20
local CELL  -- computed in on_open from screen size

local COLORS = {
  0x00d4ff,  -- 1 I: cyan
  0xffe066,  -- 2 O: yellow
  0xcc44ff,  -- 3 T: purple
  0x00dd88,  -- 4 S: green
  0xff4455,  -- 5 Z: red
  0x3399ff,  -- 6 J: blue
  0xff8833,  -- 7 L: orange
}

-- Piece rotations: each entry is 4 {dr, dc} offsets from bounding-box origin
-- Row and column are 0-indexed; field coords = py+dr (row), px+dc (col)
local PIECES = {
  -- 1 I (4×4 bounding box)
  { {{1,0},{1,1},{1,2},{1,3}}, {{0,2},{1,2},{2,2},{3,2}},
    {{1,0},{1,1},{1,2},{1,3}}, {{0,1},{1,1},{2,1},{3,1}} },
  -- 2 O
  { {{0,0},{0,1},{1,0},{1,1}}, {{0,0},{0,1},{1,0},{1,1}},
    {{0,0},{0,1},{1,0},{1,1}}, {{0,0},{0,1},{1,0},{1,1}} },
  -- 3 T
  { {{0,1},{1,0},{1,1},{1,2}}, {{0,1},{1,1},{1,2},{2,1}},
    {{1,0},{1,1},{1,2},{2,1}}, {{0,1},{1,0},{1,1},{2,1}} },
  -- 4 S
  { {{0,1},{0,2},{1,0},{1,1}}, {{0,0},{1,0},{1,1},{2,1}},
    {{0,1},{0,2},{1,0},{1,1}}, {{0,0},{1,0},{1,1},{2,1}} },
  -- 5 Z
  { {{0,0},{0,1},{1,1},{1,2}}, {{0,1},{1,0},{1,1},{2,0}},
    {{0,0},{0,1},{1,1},{1,2}}, {{0,1},{1,0},{1,1},{2,0}} },
  -- 6 J
  { {{0,0},{1,0},{1,1},{1,2}}, {{0,1},{0,2},{1,1},{2,1}},
    {{1,0},{1,1},{1,2},{2,2}}, {{0,1},{1,1},{2,0},{2,1}} },
  -- 7 L
  { {{0,2},{1,0},{1,1},{1,2}}, {{0,1},{1,1},{2,1},{2,2}},
    {{1,0},{1,1},{1,2},{2,0}}, {{0,0},{0,1},{1,1},{2,1}} },
}

local board, cv, side_cv
local px, py, rot, pid, npid
local score, hiscore, level, cleared_total
local over
local SIDE_W = 58
local rot90 = false  -- portrait / CCW-rotation mode
local _W, _H = 320, 240  -- physical screen size, saved on open

local function new_board()
  local b = {}
  for r = 1, ROWS do
    b[r] = {}
    for c = 1, COLS do b[r][c] = 0 end
  end
  return b
end

local function get_cells(p, r, bx, by)
  local out = {}
  for _, off in ipairs(PIECES[p][r]) do
    out[#out+1] = {by + off[1], bx + off[2]}
  end
  return out
end

local function collides(p, r, bx, by)
  for _, fc in ipairs(get_cells(p, r, bx, by)) do
    local fr, fc2 = fc[1] + 1, fc[2] + 1  -- 0-indexed to 1-indexed
    if fc[2] < 0 or fc[2] >= COLS or fc[1] >= ROWS then return true end
    if fc[1] >= 0 and board[fr][fc2] ~= 0 then return true end
  end
  return false
end

local function lock_piece()
  for _, fc in ipairs(get_cells(pid, rot, px, py)) do
    local fr, fc2 = fc[1] + 1, fc[2] + 1
    if fr >= 1 then board[fr][fc2] = pid end
  end
  local cleared = 0
  local r = ROWS
  while r >= 1 do
    local full = true
    for c = 1, COLS do
      if board[r][c] == 0 then full = false; break end
    end
    if full then
      table.remove(board, r)
      table.insert(board, 1, {})
      for c = 1, COLS do board[1][c] = 0 end
      cleared = cleared + 1
    else
      r = r - 1
    end
  end
  if cleared > 0 then
    cleared_total = cleared_total + cleared
    local pts = {100, 300, 500, 800}
    score = score + (pts[cleared] or 800) * level
    level = math.max(1, math.floor(cleared_total / 10) + 1)
    timer.every(math.max(80, 700 - (level - 1) * 60))
  end
end

local function spawn()
  pid, npid = npid, sys.random(1, 7)
  px = math.floor((COLS - 4) / 2)  -- center the 4-wide bounding box
  py = 0
  rot = 1
  if collides(pid, rot, px, py) then
    over = true
    if score > hiscore then
      hiscore = score
      store.set("hiscore", hiscore)
      sys.toast("New high score: " .. hiscore, 2000)
    end
  end
end

-- Draw one CELL block at board (col=c, row=r), 0-indexed.
local function put_cell(c, r, color)
  if rot90 then
    -- 90° CCW: row→x, col→y (inverted); canvas is (ROWS*CELL, COLS*CELL)
    cv:rect((r)*CELL+1, (COLS-1-c)*CELL+1, CELL-2, CELL-2, color, true, 2)
  else
    cv:rect((c)*CELL+1, (r)*CELL+1, CELL-2, CELL-2, color, true, 2)
  end
end

local function draw_board()
  cv:fill(0x0d1117)
  for r = 1, ROWS do
    for c = 1, COLS do
      local v = board[r][c]
      if v ~= 0 then put_cell(c-1, r-1, COLORS[v]) end
    end
  end
  if not over then
    for _, fc in ipairs(get_cells(pid, rot, px, py)) do
      local r, c = fc[1]+1, fc[2]+1
      if r >= 1 then put_cell(c-1, r-1, COLORS[pid]) end
    end
  end
  if over then
    local mx, my
    if rot90 then
      mx = math.floor(ROWS * CELL / 2)
      my = math.floor(COLS * CELL / 2)
    else
      mx = math.floor(COLS * CELL / 2)
      my = math.floor(ROWS * CELL / 2)
    end
    cv:rect(math.max(0, mx - 44), my - 18, 88, 36, 0x1a1f26, true, 4)
    cv:text(math.max(2, mx - 38), my - 12, "GAME OVER", C.bad, 14)
    cv:text(math.max(2, mx - 30), my + 4,  "tap to retry", C.sub, 11)
  end
end

local function draw_side()
  side_cv:fill(0x0d1117)
  if rot90 then
    -- In rot90 mode canvas is (ROWS*CELL wide, SIDE_W=58 tall).
    -- Lay out info horizontally across the strip (text appears rotated to user).
    local sx = ROWS * CELL / 2 - 60
    side_cv:text(sx,        4, "SCORE", C.sub,    11)
    side_cv:text(sx,       20, tostring(score),   C.text,   13)
    side_cv:text(sx + 80,   4, "BEST",  C.sub,    11)
    side_cv:text(sx + 80,  20, tostring(hiscore), C.accent, 13)
    side_cv:text(sx + 160,  4, "LEVEL", C.sub,    11)
    side_cv:text(sx + 160, 20, tostring(level),   C.good,   15)
    return
  end
  local bh = ROWS * CELL
  local PC = math.min(10, CELL)
  local nox = math.floor((SIDE_W - 4 * PC) / 2)
  side_cv:text(6, 4, "NEXT", C.sub, 11)
  for _, off in ipairs(PIECES[npid][1]) do
    side_cv:rect(nox + off[2]*PC+1, 18 + off[1]*PC+1, PC-2, PC-2, COLORS[npid], true, 2)
  end
  local base = 18 + 4 * PC + 6
  local gap  = math.max(28, math.floor((bh - base - 32) / 3))
  side_cv:text(6, base,            "SCORE", C.sub, 11)
  side_cv:text(6, base + 14,       tostring(score), C.text, 13)
  side_cv:text(6, base + gap,      "BEST", C.sub, 11)
  side_cv:text(6, base + gap + 14, tostring(hiscore), C.accent, 13)
  side_cv:text(6, base + gap*2,    "LEVEL", C.sub, 11)
  side_cv:text(6, base + gap*2 + 14, tostring(level), C.good, 15)
end

local function try_rotate()
  local nr = (rot % 4) + 1
  if      not collides(pid, nr, px,   py) then rot = nr
  elseif  not collides(pid, nr, px-1, py) then px = px-1; rot = nr
  elseif  not collides(pid, nr, px+1, py) then px = px+1; rot = nr
  end
  draw_board()
end

local function hard_drop()
  while not collides(pid, rot, px, py+1) do py = py+1 end
  lock_piece()
  spawn()
  draw_board()
  draw_side()
end

local function reset()
  board = new_board()
  score, cleared_total, level = 0, 0, 1
  over = false
  npid = sys.random(1, 7)
  spawn()
  draw_board()
  draw_side()
  timer.every(700)
end

function app.on_open(w, h)
  _W, _H = w, h
  hiscore = store.get("hiscore", 0)
  rot90 = store.get("rot90", 0) == 1
  -- Logical dimensions: in rot90 mode the board fills a w×h space where
  -- the physical screen axes are swapped.
  local lw = rot90 and h or w
  local lh = rot90 and w or h
  -- Cell size: fit the board (COLS wide, ROWS tall) inside the available area,
  -- leaving room for the side panel.
  CELL = math.max(6, math.min(
    math.floor((lw - SIDE_W - 4) / COLS),
    math.floor(lh / ROWS)
  ))
  local board_w = COLS * CELL
  local board_h = ROWS * CELL
  local total_w = board_w + 4 + SIDE_W
  local ox = math.max(0, math.floor((lw - total_w) / 2))
  local oy = math.max(0, math.floor((lh - board_h) / 2))
  if rot90 then
    -- 90° CCW: canvas is (board_h wide × board_w tall) in physical space.
    -- Physical pos: x = loy, y = h - lox - board_w.
    cv = ui.canvas(board_h, board_w)
    cv:pos(oy, h - ox - board_w)
    side_cv = ui.canvas(board_h, SIDE_W)
    side_cv:pos(oy, h - ox - board_w - 4 - SIDE_W)
  else
    cv = ui.canvas(board_w, board_h)
    cv:pos(ox, oy)
    side_cv = ui.canvas(SIDE_W, board_h)
    side_cv:pos(ox + board_w + 4, oy)
  end
  reset()
end

function app.on_input(ev)
  if over then
    if ev.type == "down" then reset()
    elseif ev.type == "key" and (ev.key == "r" or ev.key == "R") then
      rot90 = not rot90
      store.set("rot90", rot90 and 1 or 0)
      app.on_open(_W, _H)
    end
    return
  end
  if ev.type == "swipe" then
    local d = ev.dir
    -- In rot90 (CCW) mode remap physical swipe → logical direction
    if rot90 then
      if     d == "up"    then d = "right"
      elseif d == "down"  then d = "left"
      elseif d == "left"  then d = "up"
      elseif d == "right" then d = "down"
      end
    end
    if d == "left" then
      if not collides(pid, rot, px-1, py) then px = px-1; draw_board() end
    elseif d == "right" then
      if not collides(pid, rot, px+1, py) then px = px+1; draw_board() end
    elseif d == "up" then
      try_rotate()
    elseif d == "down" then
      hard_drop()
    end
  elseif ev.type == "key" then
    local k = ev.key
    if k == "left" then
      if not collides(pid, rot, px-1, py) then px = px-1; draw_board() end
    elseif k == "right" then
      if not collides(pid, rot, px+1, py) then px = px+1; draw_board() end
    elseif k == "up" then
      try_rotate()
    elseif k == "down" then
      if not collides(pid, rot, px, py+1) then py = py+1; draw_board() end
    elseif k == "enter" or k == " " then
      hard_drop()
    elseif k == "r" or k == "R" then
      rot90 = not rot90
      store.set("rot90", rot90 and 1 or 0)
      app.on_open(_W, _H)
    end
  end
end

function app.on_tick(dt)
  if over then return end
  if collides(pid, rot, px, py+1) then
    lock_piece()
    spawn()
    draw_board()
    draw_side()
  else
    py = py + 1
    draw_board()
  end
end

function app.on_close() end

return app
