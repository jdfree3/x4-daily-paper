-- Word of the Day lock screen: the same page the app shows, from what the app stored. When the
-- stored word is not today's and the lock session has a network (firmware 26111201 and later,
-- manifest lockscreen "net": true), it fetches the new word first.
local W, H = C.W, C.H
local pending = false
local asked = false

local function fetch_new()
  if asked then return end
  if not ctx.net then return end
  local today = C.local_date()
  if not today then return end
  local arc = C.archive()
  if arc and arc.words[1].date >= today then return end      -- already have today's word
  asked = true
  pending = true
  local function finish()
    pending = false
    pcall(function() ctx:invalidate() end)                    -- draw again; that draw ends the session
  end
  C.get(C.BASE .. 'archive.json', function(body)
    local t = body and C.decode(body) or nil
    if not (t and type(t.words) == 'table' and #t.words > 0) then return finish() end
    C.write(C.F_ARCHIVE, body)
    C.ensure(t.words[1].date, function() finish() end, true)
  end, true)
end

function on_draw(_, g)
  if not g then return end
  local ok, err = pcall(function()
    g:clear(0)
    local arc = C.archive()
    local e = arc and C.entry(arc.words[1].date) or nil
    if not e then
      g:rect(20, 20, W - 40, H - 40, { line_width = 3 })
      g:rect(30, 30, W - 60, H - 60, { line_width = 1 })
      local y = 320
      for _, ln in ipairs(C.wrap('Open Word of the Day once to load the first word.', 'medium', C.CW, 4)) do
        g:text(C.MX, y, ln, { font = C.font('medium') }); y = y + 30
      end
      return
    end
    local set = C.load_set(e)
    C.draw_entry(g, e, set, { maxlines = 7 })
    C.release_set(set)
  end)
  if not ok then pcall(function() g:text(10, 760, 'lock error: ' .. tostring(err):sub(1, 40)) end) end
  if not pending then pcall(function() ctx.lock:done() end) end
end

function on_load()
  pcall(function() ctx.lock:set_interval(3600) end)           -- 30 to 3600 s
  pcall(fetch_new)
end
function on_tick() end
function on_input() return false end
