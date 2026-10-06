-- ProTreck 1.1 — wadamesh outdoor watch
-- Tabs: ASTRO · CHRONO · TIMER · ALTI
-- ASTRO  : UTC clock, alarm (tap on/off, swipe-up/down +/-15 min), sun arc,
--          moon phase disc + rise/set approximation, sunrise/sunset
-- CHRONO : tap start/stop, swipe-up lap, swipe-down reset
-- TIMER  : tap start/stop, swipe-up cycle preset, swipe-down reset
-- ALTI   : GPS alt + trend graph; swipe-down resets min/max
-- Swipe left/right to change tab
-- Contributed by samuelcoustet

local ui, sys, store, tmr = wada.ui, wada.sys, wada.store, wada.timer
local C = ui.colors

local app = {}

-- ── Constants ─────────────────────────────────────────────────────────────
local TAB   = { "ASTRO", "CHRONO", "TIMER", "ALTI" }
local TAB_H = 18
local HIST_N = 60

-- ── Shared display state ───────────────────────────────────────────────────
local tab = 1
local cv, W, H

-- ── Time helpers ──────────────────────────────────────────────────────────
local PI = math.pi

local function now_unix()
  local ep = sys.epoch and sys.epoch()
  if ep then return ep end
  if os then return os.time and os.time() end
  return nil
end

local function decompose(t)
  if os and os.date then return os.date("*t", t) end
  local s    = t % 86400
  local sec  = s % 60;  s = math.floor(s / 60)
  local min2 = s % 60;  local hr = math.floor(s / 60)
  local days = math.floor(t / 86400)
  local y = 1970; local d = days
  while true do
    local yl = ((y%4==0 and y%100~=0) or y%400==0) and 366 or 365
    if d < yl then break end
    d = d - yl; y = y + 1
  end
  return { year=y, month=1, day=1, hour=hr, min=min2, sec=sec, yday=d+1 }
end

local function fmt_hms(ms)
  local s  = math.floor(ms / 1000)
  local cs = math.floor((ms % 1000) / 10)
  local m  = math.floor(s / 60); s = s % 60
  local h  = math.floor(m / 60); m = m % 60
  if h > 0 then return string.format("%d:%02d:%02d",    h, m, s)
            else return string.format("%02d:%02d.%02d", m, s, cs) end
end

local function fmt_mm_ss(secs)
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  local s = secs % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%02d:%02d", m, s)
end

local function fmt_utch(fh)
  -- fractional UTC hour → "HH:MM"
  if not fh then return "--:--" end
  local h = math.floor(fh) % 24
  local m = math.floor((fh - math.floor(fh)) * 60 + 0.5)
  if m >= 60 then h = (h+1)%24; m = 0 end
  return string.format("%02d:%02d", h, m)
end

-- ── Astronomical algorithms ────────────────────────────────────────────────
local function sun_utc(lat, lon, yday)
  -- Spencer 1971 simplified; returns rise_utc, set_utc (fractional hours)
  local B    = PI / 180 * (360 / 365) * (yday - 81)
  local eqt  = 9.87*math.sin(2*B) - 7.53*math.cos(B) - 1.5*math.sin(B)
  local decl = PI / 180 * 23.45 * math.sin(B)
  local cha  = -math.tan(lat * PI/180) * math.tan(decl)
  if cha < -1 or cha > 1 then return nil, nil end
  local ha   = math.acos(cha) / (PI/180)
  local noon = 12 - lon/15 - eqt/60
  return noon - ha/15, noon + ha/15
end

local function moon_phase_num(t)
  -- phase 0-29 from Unix timestamp
  local days = t / 86400 - 10957
  return math.floor((days - 6.0) % 29.53058867)
end

local function moonrise_set(phase, sr, ss)
  -- rough approximation: moon rises ~50 min later each day than the day before
  -- at new moon rises with sun; at full moon rises at sunset
  local base = sr or 6.0
  local rise = (base + phase * 24 / 29.5) % 24
  local set2 = (rise + 12.4) % 24
  return rise, set2
end

local MOON_NAMES = {
  [0]="New",[1]="New",
  [2]="Waxing Crescent",[3]="Waxing Crescent",[4]="Waxing Crescent",
  [5]="Waxing Crescent",[6]="Waxing Crescent",[7]="Waxing Crescent",
  [8]="First Quarter",[9]="First Quarter",
  [10]="Waxing Gibbous",[11]="Waxing Gibbous",[12]="Waxing Gibbous",
  [13]="Waxing Gibbous",[14]="Waxing Gibbous",
  [15]="Full Moon",[16]="Full Moon",
  [17]="Waning Gibbous",[18]="Waning Gibbous",[19]="Waning Gibbous",
  [20]="Waning Gibbous",[21]="Waning Gibbous",
  [22]="Last Quarter",[23]="Last Quarter",
  [24]="Waning Crescent",[25]="Waning Crescent",[26]="Waning Crescent",
  [27]="Waning Crescent",[28]="Waning Crescent",[29]="New",
}

-- ── Astro state ────────────────────────────────────────────────────────────
local astro_t0    = 0
local astro_sr, astro_ss           -- sunrise/sunset UTC fractional hours
local astro_mr, astro_ms           -- moonrise/moonset UTC fractional hours
local astro_phase = 0
local astro_lat, astro_lon

local function update_astro()
  local now = sys.millis()
  if now - astro_t0 < 60000 then return end
  astro_t0 = now
  local t   = now_unix()
  local gps = sys.gps()
  if gps and t then
    local d    = decompose(t)
    astro_lat  = gps.lat
    astro_lon  = gps.lon
    local yday = d.yday or 182
    astro_sr, astro_ss = sun_utc(gps.lat, gps.lon, yday)
    astro_phase        = moon_phase_num(t)
    astro_mr, astro_ms = moonrise_set(astro_phase, astro_sr, astro_ss)
  end
end

-- ── Alarm state ────────────────────────────────────────────────────────────
local alarm_h    = 7
local alarm_m    = 0
local alarm_on   = 0   -- 0=off, 1=on
local alarm_fire = false

local function alarm_step(delta_min)
  local total = alarm_h * 60 + alarm_m + delta_min
  total = total % (24 * 60)
  if total < 0 then total = total + 24 * 60 end
  alarm_h = math.floor(total / 60)
  alarm_m = total % 60
  store.set("alarm_h", alarm_h)
  store.set("alarm_m", alarm_m)
end

-- ── Sun arc diagram ────────────────────────────────────────────────────────
local function draw_sun_arc(cx, hy, r, cur_h)
  -- arc dots (22 points along the upper semicircle)
  for step = 0, 22 do
    local a  = PI - step / 22 * PI
    local ax = math.floor(cx + (r + 3) * math.cos(a))
    local ay = math.floor(hy - (r + 3) * math.sin(a))
    cv:rect(ax, ay, 2, 2, 0x243040, true, 0)
  end
  -- horizon line
  cv:rect(cx - r - 8, hy, r * 2 + 16, 1, C.sub, true, 0)

  if astro_sr and astro_ss then
    -- rise and set tick marks
    cv:rect(cx - r - 3, hy - 6, 1, 12, C.good, true, 0)
    cv:rect(cx + r + 2, hy - 6, 1, 12, C.bad,  true, 0)
    -- sun position
    if cur_h and cur_h >= astro_sr and cur_h <= astro_ss then
      local prog = (cur_h - astro_sr) / (astro_ss - astro_sr)
      local a  = PI - prog * PI
      local sx = math.floor(cx + r * math.cos(a))
      local sy = math.floor(hy - r * math.sin(a))
      cv:circle(sx, sy, 5, 0xffcc00, true, 0)
      cv:circle(sx, sy, 5, 0xff9900, false, 1)
    else
      -- below horizon
      cv:circle(cx, hy + 9, 4, 0x334455, true, 0)
    end
  else
    -- no fix / polar: show neutral disc
    cv:circle(cx, hy - r / 2, 4, 0x445566, true, 0)
  end
end

-- ── Moon phase disc (scan-line, exact terminator) ─────────────────────────
local function draw_moon_disc(cx, cy, r, phase)
  local phi    = phase / 29.5 * 2 * PI
  local drk    = 0x1a2433
  local lit    = 0xdde8f8

  for yi = -r, r - 1, 2 do
    local chord = math.floor(math.sqrt(r * r - yi * yi) + 0.5)
    if chord > 0 then
      -- full dark row
      cv:rect(cx - chord, cy + yi, chord * 2, 2, drk, true, 0)
      -- terminator x = cos(phi) * chord
      local term = math.floor(math.cos(phi) * chord + 0.5)
      local lx, lw
      if phi <= PI then
        -- waxing: lit is right of terminator
        lx = cx + term; lw = chord - term
      else
        -- waning: lit is left of -term (= right of term mirrored)
        lx = cx - chord; lw = chord - term
      end
      if lw > 0 then
        cv:rect(lx, cy + yi, lw, 2, lit, true, 0)
      end
    end
  end
  cv:circle(cx, cy, r, 0x4a5f70, false, 1)
end

-- ── ASTRO tab ─────────────────────────────────────────────────────────────
local function draw_astro(cw, ch)
  local t    = now_unix()
  local d    = t and decompose(t) or nil
  local cur_h = d and (d.hour + d.min/60 + d.sec/3600) or nil

  -- right-column geometry
  local col_w = math.floor(cw / 2)
  local cx_r  = math.floor(cw * 3 / 4)
  local arc_r = math.min(36, math.floor(col_w * 0.44))
  local moo_r = math.min(18, math.floor(col_w * 0.22))
  -- y anchors
  local ARC_Y = 72       -- sun arc horizon baseline
  local MOO_Y = 160      -- moon disc centre

  -- ── Clock ───────────────────────────────────────────────────────────────
  if d then
    local clk = string.format("%02d:%02d:%02d", d.hour or 0, d.min or 0, d.sec or 0)
    cv:text(4, 2, clk, C.text, 20)
    local ds = string.format("%04d-%02d-%02d", d.year or 0, d.month or 0, d.day or 0)
    cv:text(4, 24, ds, C.sub, 11)
  else
    cv:text(4, 2, "--:--:--", C.sub, 20)
  end

  -- ── Alarm ───────────────────────────────────────────────────────────────
  local alm_s = string.format("%02d:%02d", alarm_h, alarm_m)
  local alm_col = alarm_on == 1 and C.good or C.sub
  local ax0 = cw - math.floor(#alm_s * 10 + 26)
  cv:text(ax0, 2, alm_s, alm_col, 16)
  -- on/off dot
  local dot_x = ax0 + math.floor(#alm_s * 10 + 4)
  cv:circle(dot_x, 10, 4, alarm_on == 1 and C.good or 0x334455, true, 0)
  cv:text(ax0 - 22, 4, "AL", C.sub, 11)

  local sep_y = 40
  cv:rect(0, sep_y, cw, 1, 0x1e2a38, true, 0)

  -- ── Sun section (left) ──────────────────────────────────────────────────
  local SY = sep_y + 6
  cv:text(4, SY, "SUN", C.accent, 11)
  if astro_sr then
    cv:text(4, SY+14, "Rise  " .. fmt_utch(astro_sr), C.text, 12)
    cv:text(4, SY+28, "Set   " .. fmt_utch(astro_ss), C.text, 12)
  elseif astro_lat then
    cv:text(4, SY+14, "Polar", C.sub, 12)
  else
    cv:text(4, SY+14, "No GPS", C.bad, 12)
  end

  -- ── Sun arc (right) ─────────────────────────────────────────────────────
  draw_sun_arc(cx_r, ARC_Y, arc_r, cur_h)
  -- small rise/set times under arc
  if astro_sr and astro_ss then
    cv:text(cx_r - arc_r - 6, ARC_Y + 4, fmt_utch(astro_sr), C.good, 9)
    cv:text(cx_r + arc_r - 16, ARC_Y + 4, fmt_utch(astro_ss), C.bad, 9)
  end

  local sep2_y = ARC_Y + 20
  cv:rect(0, sep2_y, cw, 1, 0x1e2a38, true, 0)

  -- ── Moon section (left) ─────────────────────────────────────────────────
  local MY = sep2_y + 6
  cv:text(4, MY, "MOON", C.accent, 11)
  if astro_lat and t then
    local mname = MOON_NAMES[astro_phase] or "?"
    cv:text(4, MY+14, mname,                        C.text, 12)
    cv:text(4, MY+28, "Phase " .. astro_phase .. "/29", C.sub,  11)
    cv:text(4, MY+42, "Rise  " .. fmt_utch(astro_mr), C.sub, 11)
    cv:text(4, MY+54, "Set   " .. fmt_utch(astro_ms), C.sub, 11)
  else
    cv:text(4, MY+14, "No GPS+time", C.bad, 12)
  end

  -- ── Moon disc (right) ───────────────────────────────────────────────────
  draw_moon_disc(cx_r, MOO_Y, moo_r, astro_phase)

  -- ── GPS footer ──────────────────────────────────────────────────────────
  local gps = sys.gps()
  local gy  = ch - 14
  if gps then
    cv:text(4, gy, string.format("GPS %d  %.3f,%.3f", gps.sats, gps.lat, gps.lon), C.sub, 10)
  else
    cv:text(4, gy, "GPS: no fix", C.bad, 10)
  end
end

-- ── CHRONO tab ────────────────────────────────────────────────────────────
local chr_run = false
local chr_t0  = 0
local chr_acc = 0
local chr_laps = {}

local function chr_elapsed()
  if chr_run then return chr_acc + (sys.millis() - chr_t0) end
  return chr_acc
end

local function draw_chrono(cw, ch)
  local ms  = chr_elapsed()
  local ts  = fmt_hms(ms)
  local tw  = math.floor(#ts * 14)
  cv:text(math.max(4, math.floor((cw - tw) / 2)), 20, ts, chr_run and C.good or C.text, 22)

  local stat = chr_run and "RUNNING" or (chr_acc > 0 and "STOPPED" or "READY")
  cv:text(math.floor((cw - #stat * 6) / 2), 52, stat, chr_run and C.good or C.sub, 11)
  cv:text(4, 66, "tap: start/stop   up: lap   down: reset", C.sub, 11)

  local start_i = math.max(1, #chr_laps - 5)
  local ly = 84
  for i = start_i, #chr_laps do
    local col = i == #chr_laps and C.text or C.sub
    cv:text(4,  ly, string.format("Lap %d", i), col, 12)
    cv:text(44, ly, chr_laps[i],                col, 12)
    ly = ly + 14
    if ly > ch - 20 then break end
  end
end

-- ── TIMER tab ─────────────────────────────────────────────────────────────
local TMR_PRESETS = { 30, 60, 120, 300, 600, 1800, 3600 }
local tmr_pi    = 4
local tmr_secs  = 300
local tmr_end   = 0
local tmr_done  = false

local function tmr_remaining()
  if tmr_end == 0 then return tmr_secs * 1000 end
  local r = tmr_end - sys.millis()
  return r < 0 and 0 or r
end

local function draw_timer(cw, ch)
  local rem  = tmr_remaining()
  local ts   = fmt_mm_ss(math.floor(rem / 1000))
  local col  = tmr_done and C.bad or (tmr_end ~= 0 and C.good or C.text)
  local tw   = math.floor(#ts * 16)
  cv:text(math.max(4, math.floor((cw - tw) / 2)), 20, ts, col, 26)

  local total_ms = tmr_secs * 1000
  local pct = total_ms > 0 and math.floor((total_ms - rem) * (cw - 8) / total_ms) or 0
  if pct > 0 then cv:rect(4, 58, pct, 4, tmr_done and C.bad or C.accent, true, 0) end
  cv:rect(4, 58, cw - 8, 4, 0x1a1f26, false, 0)

  cv:text(4, 70, "Preset: " .. fmt_mm_ss(tmr_secs), C.sub, 11)
  cv:text(4, 84, "tap: start/stop   up: preset   down: reset", C.sub, 11)

  if tmr_done then
    local ax = math.floor((cw - 60) / 2)
    cv:rect(ax, 100, 60, 22, 0x1a1f26, true, 4)
    cv:text(ax + 8, 104, "ALARM!", C.bad, 16)
  end
end

-- ── ALTI tab ──────────────────────────────────────────────────────────────
local alti_min  = 99999
local alti_max  = -99999
local alti_hist = {}

local function draw_alti(cw, ch)
  local gps = sys.gps()
  local alt = gps and gps.alt_m or nil
  local ats = alt and string.format("%d m", math.floor(alt)) or "--- m"
  local tw  = math.floor(#ats * 14)
  cv:text(math.max(4, math.floor((cw - tw) / 2)), 10, ats, alt and C.text or C.sub, 24)

  local mn_s = alti_min < 99999 and string.format("%d m", math.floor(alti_min)) or "---"
  local mx_s = alti_max > -99999 and string.format("%d m", math.floor(alti_max)) or "---"
  cv:text(4, 44, "MIN", C.sub, 11)
  cv:text(4, 56, mn_s, C.sub, 13)
  cv:text(math.floor(cw/2)+4, 44, "MAX", C.sub, 11)
  cv:text(math.floor(cw/2)+4, 56, mx_s, C.sub, 13)

  if gps then
    cv:text(4, 76, string.format("Sats %d   %d km/h", gps.sats, math.floor(gps.speed_kmh or 0)),
            gps.sats >= 4 and C.good or C.bad, 11)
  else
    cv:text(4, 76, "No GPS fix", C.bad, 11)
  end

  local n = #alti_hist
  if n > 2 then
    local gy = 92
    local gh = ch - gy - 20
    local gw = cw - 8
    cv:rect(4, gy, gw, gh, 0x1a1f26, true, 2)
    local mn2, mx2 = alti_hist[1], alti_hist[1]
    for _, v in ipairs(alti_hist) do
      if v < mn2 then mn2 = v end
      if v > mx2 then mx2 = v end
    end
    local rng = mx2 - mn2; if rng < 1 then rng = 1 end
    for i = 2, n do
      local x1 = math.floor(4 + (i-2) * gw / (HIST_N-1))
      local x2 = math.floor(4 + (i-1) * gw / (HIST_N-1))
      local y1 = math.floor(gy + gh - (alti_hist[i-1] - mn2) * gh / rng)
      local y2 = math.floor(gy + gh - (alti_hist[i]   - mn2) * gh / rng)
      local lx = math.min(x1,x2); local lw = math.max(1, math.abs(x2-x1))
      local ly = math.min(y1,y2); local lh = math.max(1, math.abs(y2-y1))
      cv:rect(lx, ly, lw, lh, C.accent, true, 0)
    end
    cv:text(6, gy+2,       math.floor(mx2) .. "m", C.sub, 10)
    cv:text(6, gy+gh-12,   math.floor(mn2) .. "m", C.sub, 10)
  end
  cv:text(4, ch-14, "down: reset min/max", C.sub, 10)
end

-- ── Tab bar ───────────────────────────────────────────────────────────────
local function draw_tab_bar()
  local tw = math.floor(W / #TAB)
  for i, name in ipairs(TAB) do
    local tx = (i-1) * tw
    if i == tab then
      cv:rect(tx, H-TAB_H, tw, TAB_H, C.accent, true, 0)
      cv:text(math.floor(tx + (tw - #name*6)/2), H-TAB_H+4, name, 0x000000, 10)
    else
      cv:text(math.floor(tx + (tw - #name*6)/2), H-TAB_H+4, name, C.sub, 10)
    end
  end
end

-- ── Main redraw ───────────────────────────────────────────────────────────
local function redraw()
  if not cv then return end
  local ch = H - TAB_H
  cv:fill(0x0d1117)
  if     tab == 1 then draw_astro( W, ch)
  elseif tab == 2 then draw_chrono(W, ch)
  elseif tab == 3 then draw_timer( W, ch)
  elseif tab == 4 then draw_alti(  W, ch)
  end
  draw_tab_bar()
end

-- ── App lifecycle ─────────────────────────────────────────────────────────
function app.on_open(w, h)
  W, H = w, h
  cv = ui.canvas(w, h)
  cv:pos(0, 0)
  alti_min = tonumber(store.get("alti_min",   99999)) or 99999
  alti_max = tonumber(store.get("alti_max",  -99999)) or -99999
  tmr_pi   = tonumber(store.get("tmr_pi",         4)) or 4
  if tmr_pi < 1 or tmr_pi > #TMR_PRESETS then tmr_pi = 4 end
  tmr_secs = TMR_PRESETS[tmr_pi]
  alarm_h  = tonumber(store.get("alarm_h",  7)) or 7
  alarm_m  = tonumber(store.get("alarm_m",  0)) or 0
  alarm_on = tonumber(store.get("alarm_on", 0)) or 0
  astro_t0 = 0
  update_astro()
  redraw()
  tmr.every(500)
end

function app.on_tick(dt)
  -- altimeter sampling
  if tab == 4 then
    local gps = sys.gps()
    if gps and gps.alt_m then
      local a = gps.alt_m
      alti_hist[#alti_hist+1] = a
      if #alti_hist > HIST_N then table.remove(alti_hist, 1) end
      if a < alti_min then alti_min = a; store.set("alti_min", alti_min) end
      if a > alti_max then alti_max = a; store.set("alti_max", alti_max) end
    end
  end
  -- countdown timer alarm
  if tmr_end ~= 0 and not tmr_done and sys.millis() >= tmr_end then
    tmr_done = true; tmr_end = 0
    sys.beep()
  end
  -- alarm clock check (requires real time)
  if alarm_on == 1 then
    local t = now_unix()
    if t then
      local d = decompose(t)
      if d and d.hour == alarm_h and d.min == alarm_m then
        if not alarm_fire then
          alarm_fire = true
          sys.beep()
          sys.toast(string.format("Alarm %02d:%02d", alarm_h, alarm_m), 4000)
        end
      else
        alarm_fire = false
      end
    end
  end
  update_astro()
  redraw()
end

function app.on_input(ev)
  if ev.type == "swipe" then
    local d = ev.dir
    if d == "left" then
      tab = (tab % #TAB) + 1
    elseif d == "right" then
      tab = ((tab - 2) % #TAB) + 1
    elseif d == "up" then
      if tab == 1 then
        alarm_step(15)
      elseif tab == 2 and chr_run then
        chr_laps[#chr_laps+1] = fmt_hms(chr_elapsed())
        sys.toast("Lap " .. #chr_laps, 800)
      elseif tab == 3 then
        tmr_pi   = (tmr_pi % #TMR_PRESETS) + 1
        tmr_secs = TMR_PRESETS[tmr_pi]
        store.set("tmr_pi", tmr_pi)
        tmr_end = 0; tmr_done = false
      end
    elseif d == "down" then
      if tab == 1 then
        alarm_step(-15)
      elseif tab == 2 then
        chr_run = false; chr_t0 = 0; chr_acc = 0; chr_laps = {}
      elseif tab == 3 then
        tmr_end = 0; tmr_done = false
      elseif tab == 4 then
        alti_min = 99999; alti_max = -99999; alti_hist = {}
        store.set("alti_min", alti_min); store.set("alti_max", alti_max)
        sys.toast("Alt min/max reset", 1000)
      end
    end
    redraw()
  elseif ev.type == "down" then
    if tab == 1 then
      alarm_on = alarm_on == 1 and 0 or 1
      store.set("alarm_on", alarm_on)
    elseif tab == 2 then
      if chr_run then chr_acc = chr_elapsed(); chr_run = false
      else            chr_t0 = sys.millis();    chr_run = true end
    elseif tab == 3 then
      if tmr_end ~= 0 then        tmr_end = 0; tmr_done = false
      elseif tmr_done then        tmr_done = false
      else                        tmr_end = sys.millis() + tmr_secs * 1000 end
    end
    redraw()
  end
end

function app.on_close()
  chr_run = false
end

return app
