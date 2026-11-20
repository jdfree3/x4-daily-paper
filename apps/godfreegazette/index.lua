-- The Godfrey Gazette: a daily newspaper for the Xteink X4 Pro (XTOS Licorice, API 2.x, 480 x 800).
--
-- A scheduled Claude task publishes an edition to a public GitHub repo each morning. This app lists
-- the last 7 editions (editions/archive.json), shows the chosen edition's brief and sections, and
-- reads stories page by page. Everything fetched is cached with ctx.storage, so a story already
-- downloaded reads offline. Nothing is filled black except thin progress bars: large black areas
-- ghost on e-ink, and the host draws text black even when asked for white.
--
-- Host facts this file relies on (docs/firmware-notes.md): every ctx.* function is a method
-- (colon calls); g:text takes y at the TOP of the line box; the three system fonts are 20 / 24 / 30
-- px tall; a frame keeps about 1024 drawing commands; only GET and POST work on ctx.net; JSON is
-- parsed here (a small decoder below) so the app does not depend on ctx.json's array handling.

local W, H = 480, 800
local MX = 24
local BASE = 'https://raw.githubusercontent.com/jdfree3/x4-daily-paper/main/'
local UA = 'GodfreeGazette/0.1'
local LH = { small = 20, medium = 24, large = 30 }
local BODY_STEP = 28                       -- medium body text: 24 px line plus 4 px of leading
local BODY_BOTTOM = H - 70                 -- the reading area ends here (progress bar below)
local EXTRA_LINES = 8                      -- body lines worth of room the last page keeps for its buttons
local FULL_EVERY = 6                       -- full e-ink refresh every N page turns

local MONTHS = { 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
                 'September', 'October', 'November', 'December' }

local S = {
  screen = 'home',
  archive = nil,        -- { editions = { {date, weekday, briefing, stories}, .. } } newest first
  date = nil,           -- the edition being read
  idx = nil,            -- that edition's index.json
  sec = 1,              -- section shown / being read
  art = 0,              -- article number inside the section
  cur = nil,            -- the article being read (decoded)
  L = nil,              -- its layout { lines, pages, head, meta, source, y0 }
  pg = 1,               -- page of the article
  lpage = 1,            -- page of a list screen
  sel = nil,            -- edition picked on the editions screen
  status = nil,
  pf = nil,             -- offline prefetch progress { done, total }
  hits = {},
  turns = 0,
  want = nil,           -- key of the article being waited for
  failed = nil,
}

------------------------------------------------------------------ small helpers

local function fl(x) return math.floor(x) end
local function now_ms() local ok, t = pcall(function() return ctx.clock:millis() end); return ok and tonumber(t) or 0 end
local function refresh(full)
  pcall(function() if full then ctx:invalidate('full') else ctx:invalidate() end end)
end

local function font(name)
  local ok, f = pcall(function() return ctx.fonts[name] end)
  return ok and f or nil
end
local function tw(name, s)
  local f = font(name)
  if f then
    local ok, w = pcall(function() return f:measure(s) end)
    if ok and type(w) == 'number' then return w end
  end
  return #s * (name == 'small' and 9 or name == 'medium' and 11 or 14)
end

-- word wrap on ASCII spaces; a word wider than a line is cut by characters; maxlines truncates
local function wrap(s, name, maxw, maxlines)
  local out = {}
  for para in (tostring(s) .. '\n'):gmatch('([^\n]*)\n') do
    local line = ''
    for word in para:gmatch('[^ \t]+') do
      local w = word
      while tw(name, w) > maxw do
        local cut = #w
        while cut > 1 and tw(name, w:sub(1, cut)) > maxw do cut = cut - 1 end
        if line ~= '' then out[#out + 1] = line; line = '' end
        out[#out + 1] = w:sub(1, cut)
        w = w:sub(cut + 1)
        if w == '' then break end
      end
      if w ~= '' then
        local cand = line == '' and w or (line .. ' ' .. w)
        if line ~= '' and tw(name, cand) > maxw then out[#out + 1] = line; line = w else line = cand end
      end
    end
    out[#out + 1] = line
  end
  if maxlines and #out > maxlines then
    local last = out[maxlines]
    while #last > 1 and tw(name, last .. '...') > maxw do last = last:sub(1, -2) end
    local cut = {}
    for i = 1, maxlines - 1 do cut[i] = out[i] end
    cut[maxlines] = last .. '...'
    out = cut
  end
  return out
end

local function trim(s) return (tostring(s):gsub('^%s+', ''):gsub('%s+$', '')) end

local function first_sentences(s, n)
  local out, pos = {}, 1
  for _ = 1, n do
    local e = s:find('[%.%?!]%s', pos)
    if not e then out[#out + 1] = s:sub(pos); pos = #s + 1; break end
    out[#out + 1] = s:sub(pos, e)
    pos = e + 2
  end
  return trim(table.concat(out, ' '))
end

local function split_date(d)
  local y, m, dd = tostring(d):match('^(%d+)%-(%d+)%-(%d+)$')
  if not y then return nil end
  return tonumber(y), tonumber(m), tonumber(dd)
end
local function pretty(d, weekday)
  local y, m, dd = split_date(d)
  if not y or not MONTHS[m] then return tostring(d) end
  return (weekday and weekday ~= '' and (weekday .. ', ') or '') .. MONTHS[m] .. ' ' .. dd .. ', ' .. y
end
local function pretty_short(d, weekday)
  local y, m, dd = split_date(d)
  if not y or not MONTHS[m] then return tostring(d) end
  return (weekday and weekday ~= '' and (weekday:sub(1, 3) .. ', ') or '') .. MONTHS[m]:sub(1, 3) .. ' ' .. dd .. ', ' .. y
end
local function stories(n) return n .. (n == 1 and ' story' or ' stories') end

local function story_count(idx)
  local n = 0
  for _, s in ipairs(idx.sections or {}) do n = n + #(s.articles or {}) end
  return n
end

------------------------------------------------------------------ JSON (small, strict enough)

local function json_decode(s)
  local pos = 1
  local ESC = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
  local function ws() pos = s:find('[^ \t\r\n]', pos) or (#s + 1) end
  local parse
  local function str()
    local buf, i = {}, pos + 1
    while true do
      local j = s:find('["\\]', i)
      if not j then error('unterminated string') end
      buf[#buf + 1] = s:sub(i, j - 1)
      if s:sub(j, j) == '"' then pos = j + 1; return table.concat(buf) end
      local e = s:sub(j + 1, j + 1)
      if ESC[e] then buf[#buf + 1] = ESC[e]; i = j + 2
      elseif e == 'u' then
        local cp = tonumber(s:sub(j + 2, j + 5), 16)
        buf[#buf + 1] = (cp and cp < 128) and string.char(cp) or '?'
        i = j + 6
      else error('bad escape') end
    end
  end
  function parse()
    ws()
    local c = s:sub(pos, pos)
    if c == '{' then
      local t = {}
      pos = pos + 1; ws()
      if s:sub(pos, pos) == '}' then pos = pos + 1; return t end
      while true do
        ws()
        if s:sub(pos, pos) ~= '"' then error('object key expected') end
        local k = str()
        ws()
        if s:sub(pos, pos) ~= ':' then error('colon expected') end
        pos = pos + 1
        t[k] = parse()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == '}' then return t end
        if d ~= ',' then error('comma expected') end
      end
    elseif c == '[' then
      local t = {}
      pos = pos + 1; ws()
      if s:sub(pos, pos) == ']' then pos = pos + 1; return t end
      while true do
        t[#t + 1] = parse()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == ']' then return t end
        if d ~= ',' then error('comma expected') end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil
    else
      local num = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
      if not num or num == '' then error('unexpected character at ' .. pos) end
      pos = pos + #num
      return tonumber(num)
    end
  end
  local v = parse()
  return v
end

local function decode(body)
  local ok, v = pcall(json_decode, body)
  if ok and type(v) == 'table' then return v end
  return nil
end

------------------------------------------------------------------ storage (the offline cache)

local function key_of(date) return (tostring(date):gsub('%-', '_')) end
local function f_idx(date) return 'idx_' .. key_of(date) .. '.json' end
local function f_art(date, id) return 'art_' .. key_of(date) .. '_' .. (tostring(id):gsub('[^%w]', '_')) .. '.json' end

local function sread(name)
  local ok, s = pcall(function() return ctx.storage:read(name) end)
  return (ok and type(s) == 'string' and s ~= '') and s or nil
end
local function swrite(name, s) pcall(function() ctx.storage:write(name, s) end) end

local function clean_cache()
  if not S.archive then return end
  local keep = {}
  for _, e in ipairs(S.archive.editions or {}) do keep[key_of(e.date)] = true end
  local ok, names = pcall(function() return ctx.storage:list() end)
  if not ok or type(names) ~= 'table' then return end
  for _, n in pairs(names) do
    local name = type(n) == 'table' and (n.name or n[1]) or n
    if type(name) == 'string' then
      local k = name:match('^idx_(%d+_%d+_%d+)%.json$') or name:match('^art_(%d+_%d+_%d+)_')
      if k and not keep[k] then pcall(function() ctx.storage:remove(name) end) end
    end
  end
end

------------------------------------------------------------------ network (one request at a time)

local net = { queue = {}, inflight = nil }
local pump

local function keep_wifi() pcall(function() ctx.net:keep_wifi(5 * 60 * 1000) end) end

pump = function()
  if net.inflight and net.inflight.since and now_ms() - net.inflight.since > net.inflight.timeout + 10000 then
    net.inflight = nil                                  -- never answered
  end
  if net.inflight or #net.queue == 0 then return end
  local job = table.remove(net.queue, 1)
  net.inflight, job.since = job, now_ms()
  keep_wifi()
  local ok = pcall(function()
    ctx.net:request({ url = job.url, method = 'GET', headers = { ['User-Agent'] = UA }, timeout_ms = job.timeout },
      function(_, resp)
        if net.inflight ~= job then return end
        net.inflight = nil
        local code = type(resp) == 'table' and (tonumber(resp.status) or tonumber(resp.code)) or nil
        local body = type(resp) == 'table' and resp.body or nil
        if type(body) == 'string' and (not code or code < 400) then
          pcall(job.done, body)
        else
          pcall(job.done, nil, code and ('HTTP ' .. code) or 'no answer')
        end
        pump()
        refresh()
      end)
  end)
  if not ok then
    net.inflight = nil
    pcall(job.done, nil, 'could not ask')
    pump()
  end
end

-- priority jobs (what the reader is waiting for) go in front of the background prefetch
local function get(url, done, priority)
  local job = { url = url, done = done, timeout = 30000 }
  if priority then table.insert(net.queue, 1, job) else net.queue[#net.queue + 1] = job end
  pump()
end

------------------------------------------------------------------ data flow

local function find_entry(date)
  for _, e in ipairs((S.archive and S.archive.editions) or {}) do
    if e.date == date then return e end
  end
  return nil
end

local function art_meta(si, ai)
  local sec = S.idx and S.idx.sections and S.idx.sections[si]
  return sec and sec.articles and sec.articles[ai] or nil
end

local function prefetch()
  if not S.idx or not S.date then return end
  local date, missing = S.date, {}
  for _, sec in ipairs(S.idx.sections or {}) do
    for _, a in ipairs(sec.articles or {}) do
      if not sread(f_art(date, a.id)) then missing[#missing + 1] = a end
    end
  end
  S.pf = { done = 0, total = #missing }
  for _, a in ipairs(missing) do
    get(BASE .. 'editions/archive/' .. date .. '/a/' .. a.id .. '.json', function(body)
      if S.pf then S.pf.done = S.pf.done + 1 end
      if body and decode(body) then swrite(f_art(date, a.id), body) end
      if S.pf and S.pf.done >= S.pf.total then S.pf = nil; S.status = nil end
    end, false)
  end
end

local function open_edition(date, force)
  S.date, S.idx = date, nil
  S.sec = 1
  local cached = (not force) and sread(f_idx(date)) or nil
  local idx = cached and decode(cached) or nil
  if idx and idx.sections then S.idx = idx; prefetch(); refresh(true); return end
  S.status = 'Loading edition...'
  get(BASE .. 'editions/archive/' .. date .. '/index.json', function(body, err)
    if S.date ~= date then return end
    local t = body and decode(body) or nil
    if t and t.sections then
      S.idx = t
      swrite(f_idx(date), body)
      S.status = nil
      prefetch()
    else
      local old = sread(f_idx(date))
      local t2 = old and decode(old) or nil
      if t2 and t2.sections then S.idx = t2; S.status = 'Offline: showing the saved copy'
      else S.status = 'Could not load this edition (' .. tostring(err or 'bad data') .. '). Tap Refresh.' end
    end
  end, true)
end

local function fetch_archive(force)
  S.status = 'Checking for new editions...'
  get(BASE .. 'editions/archive.json', function(body, err)
    local t = body and decode(body) or nil
    if t and type(t.editions) == 'table' and #t.editions > 0 then
      S.archive = t
      swrite('archive.json', body)
      S.status = nil
      clean_cache()
      local latest = t.editions[1].date
      if S.screen == 'home' and (force or not S.date or not find_entry(S.date) or S.date ~= latest) then
        if not S.date or not find_entry(S.date) or force then open_edition(latest, force) end
      end
      if not S.date then open_edition(latest, false) end
    else
      if S.archive then S.status = 'Offline: showing saved editions'
      else S.status = 'Could not load editions (' .. tostring(err or 'bad data') .. '). Tap Refresh.' end
    end
  end, true)
end

local function do_refresh()
  S.failed = nil
  fetch_archive(true)
  refresh()
end

------------------------------------------------------------------ navigation

local function go(screen, nofull)
  S.screen = screen
  S.lpage = 1
  refresh(not nofull)
end

local function layout_article(a)
  local lines, source = {}, nil
  local parts = {}
  for _, p in ipairs(a.pages or {}) do
    local text = tostring(p)
    local keep = {}
    for ln in (text .. '\n'):gmatch('([^\n]*)\n') do
      if ln:match('^%s*Source:') then source = trim(ln) elseif trim(ln) ~= '' then keep[#keep + 1] = trim(ln) end
    end
    if #keep > 0 then parts[#parts + 1] = table.concat(keep, '\n') end
  end
  local body = table.concat(parts, ' ')
  lines = wrap(body, 'medium', W - 2 * MX)
  local head = wrap(a.headline or '', 'large', W - 2 * MX, 4)
  local metatext = tostring(a.source or '') .. (a.published and (' - ' .. a.published) or '')
  local meta = wrap(metatext, 'small', W - 2 * MX, 2)
  local y0 = 64 + #head * LH.large + 8 + #meta * LH.small + 24
  local cap1 = fl((BODY_BOTTOM - y0) / BODY_STEP)
  local capn = fl((BODY_BOTTOM - 70) / BODY_STEP)
  local pages, i = {}, 1
  while i <= #lines do
    local cap = (#pages == 0) and cap1 or capn
    local take = math.min(cap, #lines - i + 1)
    pages[#pages + 1] = { from = i, to = i + take - 1 }
    i = i + take
  end
  if #pages == 0 then pages[1] = { from = 1, to = 0 } end
  while true do
    local last = pages[#pages]
    local limit = ((#pages == 1) and cap1 or capn) - EXTRA_LINES
    local count = last.to - last.from + 1
    if count <= limit then break end
    local keep_to = last.from + limit - 1
    pages[#pages + 1] = { from = keep_to + 1, to = last.to }
    last.to = keep_to
  end
  return { lines = lines, pages = pages, head = head, meta = meta, source = source, y0 = y0 }
end

local function show_article(a)
  S.cur = a
  S.L = layout_article(a)
  S.failed = nil
  refresh(true)
end

local function load_article(si, ai)
  local meta = art_meta(si, ai)
  if not meta then return end
  S.sec, S.art, S.pg = si, ai, 1
  S.cur, S.L, S.failed = nil, nil, nil
  S.screen = 'read'
  local date = S.date
  local k = date .. ':' .. meta.id
  S.want = k
  local cached = sread(f_art(date, meta.id))
  local a = cached and decode(cached) or nil
  if a and a.pages then show_article(a); return end
  refresh(true)
  get(BASE .. 'editions/archive/' .. date .. '/a/' .. meta.id .. '.json', function(body, err)
    local t = body and decode(body) or nil
    if t and t.pages then
      swrite(f_art(date, meta.id), body)
      if S.want == k then show_article(t) end
    elseif S.want == k then
      S.failed = 'Could not load this story (' .. tostring(err or 'bad data') .. ').'
    end
  end, true)
end

local function turn(delta)
  if not S.L then return end
  local n = #S.L.pages
  local np = S.pg + delta
  if np < 1 or np > n then return end
  S.pg = np
  S.turns = S.turns + 1
  refresh(S.turns % FULL_EVERY == 0)
end

local function list_turn(delta, pages)
  local np = S.lpage + delta
  if np < 1 or np > pages then return end
  S.lpage = np
  refresh(true)
end

local function back()
  local sc = S.screen
  if sc == 'home' then return false end
  if sc == 'read' then S.want = nil; go('section')
  elseif sc == 'section' then go('home')
  elseif sc == 'qr' then go('read', true)
  elseif sc == 'editions' then go('home')
  elseif sc == 'summary' then go('editions')
  else go('home') end
  return true
end

------------------------------------------------------------------ drawing helpers

local function hit(x, y, w, h, fn) S.hits[#S.hits + 1] = { x = x, y = y, w = w, h = h, fn = fn } end
local function text(g, x, y, s, name) g:text(x, y, s, { font = font(name) }) end
local function rule(g, y, x1, x2, th)
  for i = 0, (th or 1) - 1 do g:line(x1 or MX, y + i, x2 or (W - MX), y + i) end
end
local function chevron_right(g, x, y) g:polyline({ x, y - 8, x + 8, y, x, y + 8 }) end
local function button(g, x, y, w, h, label, name, fn)
  g:rect(x, y, w, h, { line_width = 2 })
  local s = label
  while #s > 1 and tw(name, s) > w - 12 do s = s:sub(1, -2) end
  text(g, x + fl((w - tw(name, s)) / 2), y + fl((h - LH[name]) / 2), s, name)
  if fn then hit(x, y, w, h, fn) end
end

local function topbar(g, label, right, fn)
  hit(0, 0, 240, 56, fn)
  g:polyline({ MX + 8, 18, MX, 28, MX + 8, 38 })
  text(g, MX + 22, 16, label, 'medium')
  if right then text(g, W - MX - tw('small', right), 18, right, 'small') end
  rule(g, 55, 0, W, 2)
end

-- pages of list items by cumulative height: items = { {h = n}, .. }
local function paginate(items, limit)
  local pages, from, used = {}, 1, 0
  for i, it in ipairs(items) do
    if used > 0 and used + it.h > limit then
      pages[#pages + 1] = { from = from, to = i - 1 }
      from, used = i, 0
    end
    used = used + it.h
  end
  if #items > 0 then pages[#pages + 1] = { from = from, to = #items } else pages[1] = { from = 1, to = 0 } end
  return pages
end

------------------------------------------------------------------ screens

local function draw_home(g)
  local title = 'The Godfrey Gazette'
  text(g, fl((W - tw('large', title)) / 2), 12, title, 'large')
  local idx = S.idx
  local y = 52
  if idx then
    text(g, MX, y + 2, pretty_short(idx.date, idx.weekday), 'small')
    text(g, MX, y + 24, stories(story_count(idx)), 'small')
  else
    text(g, MX, y + 12, S.date and pretty_short(S.date) or 'Loading...', 'small')
  end
  do  -- status (when there is one) takes the top right, where the old button was
    local st = S.status
    if not st and S.pf and S.pf.total > 0 then st = 'Saving stories ' .. S.pf.done .. '/' .. S.pf.total end
    if st then
      local ln = wrap(st, 'small', 190, 2)
      for i, l in ipairs(ln) do text(g, W - MX - tw('small', l), y + 2 + (i - 1) * LH.small, l, 'small') end
    end
  end
  y = y + 56
  rule(g, y, MX, W - MX, 2); rule(g, y + 5, MX, W - MX, 1)
  y = y + 16
  if not idx then
    local msg = S.status or 'Loading the edition...'
    for _, ln in ipairs(wrap(msg, 'medium', W - 2 * MX, 6)) do text(g, MX, y, ln, 'medium'); y = y + 28 end
  else
    text(g, MX, y, 'THIS EDITION IN BRIEF', 'small'); y = y + 26
    local lines = wrap(idx.briefing or 'No summary for this edition.', 'small', W - 2 * MX, 14)
    for _, ln in ipairs(lines) do text(g, MX, y, ln, 'small'); y = y + LH.small end
    y = y + 6
    text(g, MX, y, 'Summary written by Claude from the stories', 'small'); y = y + 34
    text(g, MX, y, 'SECTIONS', 'small'); y = y + 26
    local secs = idx.sections or {}
    local room = (H - 64) - y
    local rh = math.max(52, math.min(64, fl(room / math.max(1, #secs))))
    for i, sec in ipairs(secs) do
      g:rect(MX - 8, y, W - 2 * MX + 16, rh - 6, { line_width = 2 })
      text(g, MX + 4, y + 6, sec.name, 'medium')
      text(g, MX + 4, y + 6 + LH.medium, stories(#(sec.articles or {})), 'small')
      chevron_right(g, W - MX - 6, y + fl((rh - 6) / 2))
      hit(MX - 8, y, W - 2 * MX + 16, rh - 6, function() S.sec = i; go('section') end)
      y = y + rh
    end
  end
  -- footer: the edition (tap to change it) on the left, Refresh on the right
  rule(g, H - 52, MX, W - MX, 1)
  local label = 'Edition: ' .. ((idx and pretty_short(idx.date, idx.weekday)) or (S.date and pretty_short(S.date)) or '...')
  local bw = W - 2 * MX - 122
  while tw('small', label) > bw - 52 and #label > 12 do label = label:sub(1, -2) end
  button(g, MX, H - 46, bw, 38, label, 'small', function()
    if S.archive then S.sel = nil; go('editions') else do_refresh() end
  end)
  g:polyline({ MX + bw - 28, H - 32, MX + bw - 20, H - 24, MX + bw - 12, H - 32 })   -- down chevron
  button(g, W - MX - 110, H - 46, 110, 38, 'Refresh', 'small', do_refresh)
end

local function draw_section(g)
  local idx = S.idx
  local sec = idx and idx.sections and idx.sections[S.sec]
  if not sec then go('home'); return end
  local nsec = #idx.sections
  topbar(g, 'Front page', 'Section ' .. S.sec .. ' of ' .. nsec, function() go('home') end)
  text(g, MX, 64, sec.name, 'large')
  text(g, MX, 98, stories(#sec.articles), 'small')
  rule(g, 124, MX, W - MX, 2); rule(g, 129, MX, W - MX, 1)
  local items = {}
  for i, a in ipairs(sec.articles) do
    local hl = wrap(a.headline or '', 'medium', W - 2 * MX, 2)
    local sm = wrap(a.summary or '', 'small', W - 2 * MX, 2)
    items[i] = { hl = hl, sm = sm, h = #hl * LH.medium + 4 + #sm * LH.small + 4 + LH.small + 16 }
  end
  local pages = paginate(items, (H - 56) - 140)
  if S.lpage > #pages then S.lpage = #pages end
  local pg = pages[S.lpage]
  local y = 140
  for i = pg.from, pg.to do
    local it, a = items[i], sec.articles[i]
    local top = y
    for _, ln in ipairs(it.hl) do text(g, MX, y, ln, 'medium'); y = y + LH.medium end
    y = y + 4
    for _, ln in ipairs(it.sm) do text(g, MX, y, ln, 'small'); y = y + LH.small end
    y = y + 4
    local tail = ' - ' .. (a.pages or 1) .. (a.pages == 1 and ' page' or ' pages')
    local src = tostring(a.source or '')
    while #src > 1 and tw('small', src .. tail) > W - 2 * MX do src = src:sub(1, -2) end
    text(g, MX, y, src .. tail, 'small')
    y = y + LH.small + 8
    rule(g, y, MX, W - MX, 1)
    y = y + 8
    hit(0, top, W, y - top, function() load_article(S.sec, i) end)
  end
  local nxt = idx.sections[S.sec + 1]
  local hint = nxt and ('Swipe left: ' .. nxt.name) or ''
  text(g, MX, H - 34, wrap(hint, 'small', 300, 1)[1] or '', 'small')
  if #pages > 1 then
    local pt = 'List ' .. S.lpage .. '/' .. #pages
    text(g, W - MX - tw('small', pt), H - 34, pt, 'small')
  end
  S.list_pages = #pages
end

local function draw_read(g)
  local idx = S.idx
  local sec = idx and idx.sections and idx.sections[S.sec]
  local meta = art_meta(S.sec, S.art)
  if not sec or not meta then go('home'); return end
  local L = S.L
  local right = L and ('Page ' .. S.pg .. ' of ' .. #L.pages) or nil
  topbar(g, sec.name, right, function() S.want = nil; go('section') end)
  if not L then
    local y = 80
    text(g, MX, y, meta.headline or '', 'large'); y = y + 40
    local msg = S.failed or 'Loading the story...'
    for _, ln in ipairs(wrap(msg, 'medium', W - 2 * MX, 4)) do text(g, MX, y, ln, 'medium'); y = y + 28 end
    if S.failed then button(g, MX, y + 10, 160, 52, 'Try again', 'medium', function() load_article(S.sec, S.art) end) end
    return
  end
  local P = L.pages[S.pg]
  local y
  if S.pg == 1 then
    y = 64
    for _, ln in ipairs(L.head) do text(g, MX, y, ln, 'large'); y = y + LH.large end
    y = y + 8
    for _, ln in ipairs(L.meta) do text(g, MX, y, ln, 'small'); y = y + LH.small end
    y = y + 6
    rule(g, y, MX, W - MX, 2)
    y = L.y0
  else
    y = 70
  end
  for i = P.from, P.to do text(g, MX, y, L.lines[i], 'medium'); y = y + BODY_STEP end
  if S.pg == #L.pages then
    if L.source then text(g, MX, y + 6, wrap(L.source, 'small', W - 2 * MX, 2)[1], 'small') end
    local nxt = sec.articles[S.art + 1]
    local by = BODY_BOTTOM - 56
    if nxt then
      local cy = by - 12 - 96
      g:rect(MX, cy, W - 2 * MX, 96, { line_width = 2 })
      text(g, MX + 12, cy + 8, 'NEXT IN ' .. string.upper(sec.name), 'small')
      local nl = wrap(nxt.headline or '', 'medium', W - 2 * MX - 24, 2)
      local ny = cy + 8 + LH.small + 4
      for _, ln in ipairs(nl) do text(g, MX + 12, ny, ln, 'medium'); ny = ny + LH.medium end
      hit(MX, cy, W - 2 * MX, 96, function() load_article(S.sec, S.art + 1) end)
    end
    local verified = S.cur and S.cur.url_verified == true and type(S.cur.url) == 'string'
    if verified then
      local bw = fl((W - 2 * MX - 12) / 2)
      button(g, MX, by, bw, 56, 'Show QR code', 'small', function() S.qr = nil; go('qr') end)
      button(g, MX + bw + 12, by, bw, 56, 'Back to section', 'small', function() S.want = nil; go('section') end)
    else
      button(g, MX, by, W - 2 * MX, 56, 'Back to section', 'small', function() S.want = nil; go('section') end)
    end
  end
  -- progress bar and hints
  local n = #L.pages
  g:rect(MX, H - 54, W - 2 * MX, 8, { line_width = 1 })
  g:rect(MX, H - 54, math.max(4, fl((W - 2 * MX) * S.pg / n)), 8, { fill = true })
  text(g, MX, H - 36, S.pg > 1 and 'Tap left: back' or 'Tap right: next page', 'small')
  if S.pg > 1 and S.pg < n then
    local t = 'Tap right: next page'
    text(g, W - MX - tw('small', t), H - 36, t, 'small')
  end
end

local function draw_qr(g)
  local a, meta = S.cur, art_meta(S.sec, S.art)
  if not (a and meta and a.url) then go('read', true); return end
  topbar(g, 'Back to story', 'Scan to read more', function() go('read', true) end)
  local y = 70
  for _, ln in ipairs(wrap(meta.headline or '', 'medium', W - 2 * MX, 3)) do text(g, MX, y, ln, 'medium'); y = y + LH.medium end
  text(g, MX, y + 2, tostring(meta.source or ''):sub(1, 50), 'small')
  if not S.qr or S.qr.url ~= a.url then
    if S.qr and S.qr.img then pcall(function() S.qr.img:release() end) end
    local ok, img = pcall(function() return ctx.qr:encode(a.url) end)
    S.qr = { url = a.url, img = (ok and img) or nil }
  end
  local qy = 200
  if S.qr.img then
    local w = tonumber(S.qr.img.width) or 0
    local size = w > 0 and w * math.max(1, fl(330 / w)) or 330
    pcall(function() g:image(S.qr.img, fl((W - size) / 2), qy, { w = size, h = size }) end)
    qy = qy + size + 22
  else
    text(g, MX, qy, 'Could not make a QR code here.', 'medium'); qy = qy + 40
  end
  text(g, MX, qy, 'Point your phone camera at the code.', 'small'); qy = qy + 28
  local shown = tostring(a.url):gsub('^https?://', ''):gsub('^www%.', '')
  for _, ln in ipairs(wrap(shown, 'small', W - 2 * MX, 3)) do text(g, MX, qy, ln, 'small'); qy = qy + LH.small end
  button(g, MX, H - 76, W - 2 * MX, 56, 'Done', 'medium', function() go('read', true) end)
end

local function draw_editions(g)
  local eds = (S.archive and S.archive.editions) or {}
  topbar(g, 'Front page', 'Last 7 days', function() go('home') end)
  text(g, MX, 64, 'Choose edition', 'large')
  text(g, MX, 98, #eds == 1 and '1 edition available' or (#eds .. ' editions available'), 'small')
  rule(g, 124, MX, W - MX, 2); rule(g, 129, MX, W - MX, 1)
  local items = {}
  for i, e in ipairs(eds) do
    local pv = wrap(first_sentences(e.briefing or '', 2), 'small', W - 2 * MX, 3)
    items[i] = { pv = pv, h = LH.medium + 6 + #pv * LH.small + 6 + LH.small + 18 }
  end
  local pages = paginate(items, (H - 56) - 140)
  if S.lpage > #pages then S.lpage = #pages end
  local pg = pages[S.lpage]
  local y = 140
  for i = pg.from, pg.to do
    local e, it = eds[i], items[i]
    local top = y
    local tagtxt = (i == 1) and ((S.date == e.date) and 'Latest, open' or 'Latest') or ((S.date == e.date) and 'Open' or nil)
    local room = W - 2 * MX - (tagtxt and (tw('small', tagtxt) + 32) or 0)
    local dtxt = pretty(e.date, e.weekday)
    if tw('medium', dtxt) > room then dtxt = pretty_short(e.date, e.weekday) end
    while #dtxt > 1 and tw('medium', dtxt) > room do dtxt = dtxt:sub(1, -2) end
    text(g, MX, y, dtxt, 'medium')
    if i == 1 then
      local tag = (S.date == e.date) and 'Latest, open' or 'Latest'
      local tgw = tw('small', tag) + 16
      g:rect(W - MX - tgw, y, tgw, 26, { line_width = 2 })
      text(g, W - MX - tgw + 8, y + 3, tag, 'small')
    elseif S.date == e.date then
      local tag = 'Open'
      local tgw = tw('small', tag) + 16
      g:rect(W - MX - tgw, y, tgw, 26, { line_width = 2 })
      text(g, W - MX - tgw + 8, y + 3, tag, 'small')
    end
    y = y + LH.medium + 6
    for _, ln in ipairs(it.pv) do text(g, MX, y, ln, 'small'); y = y + LH.small end
    y = y + 6
    text(g, MX, y, stories(tonumber(e.stories) or 0) .. ' - tap to read the summary', 'small')
    y = y + LH.small + 8
    rule(g, y, MX, W - MX, 1)
    y = y + 10
    hit(0, top, W, y - top, function() S.sel = e.date; go('summary') end)
  end
  if #pages > 1 then
    local pt = 'List ' .. S.lpage .. '/' .. #pages .. ' - swipe up'
    text(g, W - MX - tw('small', pt), H - 34, pt, 'small')
  end
  text(g, MX, H - 34, 'Older days appear as published', 'small')
  S.list_pages = #pages
end

local function draw_summary(g)
  local e = S.sel and find_entry(S.sel)
  if not e then go('editions'); return end
  topbar(g, 'Editions', 'Edition summary', function() go('editions') end)
  local y = 70
  for _, ln in ipairs(wrap(pretty(e.date, e.weekday), 'large', W - 2 * MX, 2)) do text(g, MX, y, ln, 'large'); y = y + LH.large end
  text(g, MX, y + 4, 'The Godfrey Gazette - ' .. stories(tonumber(e.stories) or 0), 'small')
  y = y + 34
  rule(g, y, MX, W - MX, 2); rule(g, y + 5, MX, W - MX, 1)
  y = y + 18
  text(g, MX, y, 'THIS EDITION IN BRIEF', 'small'); y = y + 28
  for _, ln in ipairs(wrap(e.briefing or 'No summary for this edition.', 'medium', W - 2 * MX, 13)) do
    text(g, MX, y, ln, 'medium'); y = y + LH.medium + 2
  end
  y = y + 6
  text(g, MX, y, 'Summary written by Claude from this edition', 'small'); y = y + 30
  local cached = sread(f_idx(e.date))
  local idx = cached and decode(cached) or nil
  if idx and idx.sections and y < H - 240 then
    for _, sec in ipairs(idx.sections) do
      if y > H - 150 then break end
      rule(g, y, MX, W - MX, 1)
      text(g, MX, y + 5, sec.name, 'small')
      local c = tostring(#(sec.articles or {}))
      text(g, W - MX - tw('small', c), y + 5, c, 'small')
      y = y + 30
    end
    rule(g, y, MX, W - MX, 1)
  end
  local bw = fl((W - 2 * MX - 12) / 2)
  button(g, MX, H - 76, bw, 56, 'Open edition', 'small', function()
    local d = e.date
    S.screen = 'home'
    if S.date == d and S.idx then refresh(true) else open_edition(d, false) end
    refresh(true)
  end)
  button(g, MX + bw + 12, H - 76, bw, 56, 'Cancel', 'small', function() go('editions') end)
end

------------------------------------------------------------------ host callbacks

function on_draw(_, g)
  S.hits = {}
  g:clear(0)                                          -- own the whole frame, white
  local sc = S.screen
  if sc == 'home' then draw_home(g)
  elseif sc == 'section' then draw_section(g)
  elseif sc == 'read' then draw_read(g)
  elseif sc == 'qr' then draw_qr(g)
  elseif sc == 'editions' then draw_editions(g)
  elseif sc == 'summary' then draw_summary(g)
  else draw_home(g) end
end

-- API 2.x sends pointer events (down / move / hold / up, the gesture on up); older hosts sent one
-- touch event per gesture. Both become one touch-like event; nil for a phase to skip.
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
  local t = tonumber(ev.time_ms) or now_ms()
  if last_key == ev.key and last_key_ms and t - last_key_ms >= 0 and t - last_key_ms < 250 then return false end
  last_key, last_key_ms = ev.key, t
  return true
end

local function tap(x, y)
  for _, h in ipairs(S.hits) do
    if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then h.fn(); return true end
  end
  if S.screen == 'read' and S.L then
    if x < fl(W / 3) then turn(-1) else turn(1) end
    return true
  end
  return false
end

local function swipe(gs)
  local sc = S.screen
  if sc == 'read' then
    if gs == 'swipe_left' then turn(1) elseif gs == 'swipe_right' then turn(-1) end
  elseif sc == 'section' then
    local n = S.idx and #S.idx.sections or 0
    if gs == 'swipe_left' and S.sec < n then S.sec = S.sec + 1; S.lpage = 1; refresh(true)
    elseif gs == 'swipe_right' and S.sec > 1 then S.sec = S.sec - 1; S.lpage = 1; refresh(true)
    elseif gs == 'swipe_up' then list_turn(1, S.list_pages or 1)
    elseif gs == 'swipe_down' then list_turn(-1, S.list_pages or 1) end
  elseif sc == 'editions' then
    if gs == 'swipe_up' then list_turn(1, S.list_pages or 1) elseif gs == 'swipe_down' then list_turn(-1, S.list_pages or 1) end
  elseif sc == 'home' then
    if gs == 'long' then do_refresh() end
  end
end

function on_input(_, ev)
  if type(ev) ~= 'table' then return false end
  ev = as_touch(ev)
  if not ev then return true end
  if ev.type == 'key' and ev.key == 'back' then
    local st = ev.phase or ev.state
    if st ~= nil and st ~= 'up' then return true end      -- Back acts on its release
    return back()
  end
  if ev.type == 'key' then
    if not key_accepted(ev) then return true end
    local k = ev.key
    if S.screen == 'read' then
      if k == 'down' or k == 'right' then turn(1) elseif k == 'up' or k == 'left' then turn(-1) end
    elseif S.screen == 'section' or S.screen == 'editions' then
      if k == 'down' then list_turn(1, S.list_pages or 1) elseif k == 'up' then list_turn(-1, S.list_pages or 1) end
    end
    return true
  end
  if ev.type == 'touch' then
    local gs = ev.gesture
    if gs ~= 'tap' and (ev.x or 0) == 0 and (ev.y or 0) == 0 and gs ~= 'long' then return true end
    if gs == 'tap' then tap(ev.x or 0, ev.y or 0) else swipe(gs) end
    return true
  end
  return false
end

function on_load(c)
  c = c or ctx
  local cached = sread('archive.json')
  local t = cached and decode(cached) or nil
  if t and type(t.editions) == 'table' and #t.editions > 0 then
    S.archive = t
    open_edition(t.editions[1].date, false)            -- shows the saved copy at once, offline too
  end
  fetch_archive(false)
  refresh(true)
end

function on_leave()
  pcall(function() ctx.net:keep_wifi(1) end)
end

-- Test hook (a Lua run on the PC): never set on the device.
if rawget(_G, '__TEST') then
  __TEST.api = { S = S, json_decode = json_decode, wrap = wrap, layout_article = layout_article,
                 paginate = paginate, first_sentences = first_sentences, pretty = pretty }
end
