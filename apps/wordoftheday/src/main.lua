-- Word of the Day (the app): today's word and the last 30 days. Cached in ctx.storage, so
-- words already fetched read offline. The same pages can be the lock screen (lockscreen.lua).
local W, H = C.W, C.H
local MX, CW = C.MX, C.CW

local S = {
  arc = nil,          -- { words = { {date, weekday, word, image}, .. } } newest first
  pos = 1,            -- the word on screen (index into arc.words)
  e = nil,            -- its entry
  set = nil,          -- its decoded pictures
  set_date = nil,
  screen = 'today',   -- today | list
  lpage = 1,
  status = nil,
  err = nil,
  hits = {},
  turns = 0,
}

local function refresh(full)
  pcall(function() if full then ctx:invalidate('full') else ctx:invalidate() end end)
end
local function text(g, x, y, s, name) g:text(x, y, s, { font = C.font(name) }) end
local function hit(x, y, w, h, fn) S.hits[#S.hits + 1] = { x = x, y = y, w = w, h = h, fn = fn } end
local function button(g, x, y, w, h, label, name, fn)
  g:rect(x, y, w, h, { line_width = 2 })
  local s = label
  while #s > 1 and C.tw(name, s) > w - 12 do s = s:sub(1, -2) end
  text(g, x + (w - C.tw(name, s)) // 2, y + (h - C.LH[name]) // 2, s, name)
  if fn then hit(x, y, w, h, fn) end
end

local function lock_on()
  local ok, v = pcall(function() return ctx.lockscreen:is_default() end)
  return ok and v == true
end

-- decode the pictures of the word on screen (when all three files are stored)
local function show_set()
  local w = S.arc and S.arc.words[S.pos]
  if not w then return end
  local e = C.entry(w.date)
  if not e then return end
  if S.set_date == w.date and S.set then S.e = e; return end
  C.release_set(S.set)
  S.set = C.load_set(e)
  S.set_date, S.e = w.date, e
end

local function go_to(pos, full)
  if not S.arc or pos < 1 or pos > #S.arc.words then return end
  S.pos = pos
  S.e = nil
  S.err = nil
  local date = S.arc.words[pos].date
  C.release_set(S.set); S.set, S.set_date = nil, nil
  show_set()
  if not S.e or not S.set or not S.set.art then
    C.ensure(date, function(ok, err)
      if S.arc and S.arc.words[S.pos] and S.arc.words[S.pos].date == date then
        if ok then C.release_set(S.set); S.set, S.set_date = nil, nil; show_set() else S.err = err end
        refresh(true)
      end
    end, true)
  end
  S.turns = S.turns + 1
  refresh(full ~= false)
end

-- keep this week's pages stored so swiping works offline
local function prefetch()
  if not S.arc then return end
  for i = 1, math.min(7, #S.arc.words) do
    local d = S.arc.words[i].date
    if i == S.pos then goto continue end
    if not (C.read(C.f_entry(d)) and C.read(C.f_word(d))) or not C.read(C.F_FRAME) then
      C.ensure(d, function() end, false)
    end
    ::continue::
  end
end

local function clean_cache()
  if not S.arc then return end
  local keep = {}
  for _, w in ipairs(S.arc.words) do keep[C.key(w.date)] = true end
  local ok, names = pcall(function() return ctx.storage:list() end)
  if not ok or type(names) ~= 'table' then return end
  for _, n in pairs(names) do
    local name = type(n) == 'table' and (n.name or n[1]) or n
    if type(name) == 'string' then
      local k = name:match('^e_(%d+_%d+_%d+)%.json$') or name:match('^w_(%d+_%d+_%d+)%.jpg$')
      if k and not keep[k] then C.remove(name) end
    end
  end
end

local function fetch_archive(force)
  S.status = 'Checking for a new word...'
  C.get(C.BASE .. 'archive.json', function(body, err)
    local t = body and C.decode(body) or nil
    if t and type(t.words) == 'table' and #t.words > 0 then
      local first = not S.arc
      local newest_changed = S.arc and S.arc.words[1].date ~= t.words[1].date
      S.arc = t
      C.write(C.F_ARCHIVE, body)
      S.status = nil
      clean_cache()
      if first or (newest_changed and S.pos == 1) or force then go_to(S.pos <= #t.words and (first and 1 or S.pos) or 1) end
      prefetch()
    else
      if S.arc then S.status = 'Offline: showing saved words'
      else S.status = 'Could not load words (' .. tostring(err or 'bad data') .. '). Press Back and try again.' end
    end
  end, true)
end

------------------------------------------------------------------ screens

local function draw_today(g)
  local e = S.e
  if e then
    C.draw_entry(g, e, S.set, { maxlines = 6 })
  else
    g:rect(20, 20, W - 40, H - 40, { line_width = 3 })
    g:rect(30, 30, W - 60, H - 60, { line_width = 1 })
    local msg = S.err or S.status or 'Loading the word...'
    local y = 300
    for _, ln in ipairs(C.wrap(msg, 'medium', CW, 6)) do text(g, MX, y, ln, 'medium'); y = y + 30 end
  end
  -- small labels inside the frame: the day and the place in the list
  local w = S.arc and S.arc.words[S.pos]
  if w then
    text(g, MX, 40, C.pretty(w.date, w.weekday), 'small')
    local pt = S.pos .. ' of ' .. #S.arc.words
    text(g, MX + CW - C.tw('small', pt), 40, pt, 'small')
  end
  local bw = (CW - 12) // 2
  button(g, MX, 712, bw, 40, 'Past words', 'small', function() S.lpage = 1; S.screen = 'list'; refresh(true) end)
  button(g, MX + bw + 12, 712, bw, 40, lock_on() and 'Lock: on' or 'Lock: off', 'small', function()
    if lock_on() then pcall(function() ctx.lockscreen:clear_default() end)
    else pcall(function() ctx.lockscreen:set_default() end) end
    refresh(true)
  end)
  if S.status and e then text(g, MX, 756, C.wrap(S.status, 'small', CW, 1)[1] or '', 'small') end
end

local ROW = 72
local function list_pages()
  local per = (H - 150 - 20) // ROW
  local n = S.arc and #S.arc.words or 0
  return per, math.max(1, (n + per - 1) // per)
end

local function draw_list(g)
  hit(0, 0, 240, 56, function() S.screen = 'today'; refresh(true) end)
  g:polyline({ 32, 18, 24, 28, 32, 38 })
  text(g, 46, 16, 'Today', 'medium')
  for i = 0, 1 do g:line(0, 55 + i, W, 55 + i) end
  text(g, 24, 68, 'Past words', 'large')
  local n = S.arc and #S.arc.words or 0
  text(g, 24, 102, n == 1 and '1 word' or (n .. ' words'), 'small')
  g:line(24, 128, W - 24, 128); g:line(24, 129, W - 24, 129)
  local per, pages = list_pages()
  if S.lpage > pages then S.lpage = pages end
  local first = (S.lpage - 1) * per + 1
  local y = 142
  for i = first, math.min(n, first + per - 1) do
    local w = S.arc.words[i]
    local top = y
    text(g, 24, y, w.word or '', 'large')
    text(g, 24, y + 34, C.pretty(w.date, w.weekday), 'small')
    if i == S.pos then
      local tag = 'Open'
      local tgw = C.tw('small', tag) + 16
      g:rect(W - 24 - tgw, y + 4, tgw, 26, { line_width = 2 })
      text(g, W - 24 - tgw + 8, y + 7, tag, 'small')
    end
    y = y + ROW - 6
    g:line(24, y, W - 24, y)
    y = y + 6
    hit(0, top, W, ROW, function() S.screen = 'today'; go_to(i, true) end)
  end
  if pages > 1 then
    local pt = 'Page ' .. S.lpage .. '/' .. pages .. ' - swipe up'
    text(g, W - 24 - C.tw('small', pt), H - 34, pt, 'small')
  end
end

------------------------------------------------------------------ host callbacks

function on_draw(_, g)
  S.hits = {}
  g:clear(0)
  if S.screen == 'list' then draw_list(g) else draw_today(g) end
end

local function as_touch(ev)
  if ev.type ~= 'pointer' then return ev end
  if ev.phase ~= 'up' then return nil end
  local gs = ev.gesture
  if gs == 'double_tap' then gs = 'tap' end
  return { type = 'touch', gesture = gs, x = ev.x, y = ev.y }
end

local last_key, last_key_ms = nil, nil
local function key_accepted(ev)
  local ph = ev.phase or ev.action or ev.state
  if ph == 'up' or ph == 'release' or ph == 'released' or ev.pressed == false or ev.down == false then return false end
  local t = tonumber(ev.time_ms) or C.now_ms()
  if last_key == ev.key and last_key_ms and t - last_key_ms >= 0 and t - last_key_ms < 250 then return false end
  last_key, last_key_ms = ev.key, t
  return true
end

local function older() go_to(S.pos + 1) end
local function newer() go_to(S.pos - 1) end

local function swipe(gs)
  if S.screen == 'today' then
    if gs == 'swipe_left' then older() elseif gs == 'swipe_right' then newer() end
  else
    local _, pages = list_pages()
    if gs == 'swipe_up' and S.lpage < pages then S.lpage = S.lpage + 1; refresh(true)
    elseif gs == 'swipe_down' and S.lpage > 1 then S.lpage = S.lpage - 1; refresh(true) end
  end
end

function on_input(_, ev)
  if type(ev) ~= 'table' then return false end
  ev = as_touch(ev)
  if not ev then return true end
  if ev.type == 'key' and ev.key == 'back' then
    local st = ev.phase or ev.state
    if st ~= nil and st ~= 'up' then return true end
    if S.screen == 'list' then S.screen = 'today'; refresh(true); return true end
    return false
  end
  if ev.type == 'key' then
    if not key_accepted(ev) then return true end
    local k = ev.key
    if S.screen == 'today' then
      if k == 'down' or k == 'right' then older() elseif k == 'up' or k == 'left' then newer() end
    else
      local _, pages = list_pages()
      if k == 'down' and S.lpage < pages then S.lpage = S.lpage + 1; refresh(true)
      elseif k == 'up' and S.lpage > 1 then S.lpage = S.lpage - 1; refresh(true) end
    end
    return true
  end
  if ev.type == 'touch' then
    local gs = ev.gesture
    if gs ~= 'tap' and (ev.x or 0) == 0 and (ev.y or 0) == 0 and gs ~= 'long' then return true end
    if gs == 'tap' then
      local x, y = ev.x or 0, ev.y or 0
      for _, h in ipairs(S.hits) do
        if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then h.fn(); return true end
      end
    else
      swipe(gs)
    end
    return true
  end
  return false
end

function on_load()
  S.arc = C.archive()
  if S.arc then go_to(1) end
  fetch_archive(false)
  refresh(true)
end

function on_leave()
  C.release_set(S.set); S.set = nil
  pcall(function() ctx.net:keep_wifi(1) end)
end

if rawget(_G, '__TEST') then __TEST.api = { S = S, C = C } end
