local Logger = require("logger")
local Utils = require("utils")

local M = {}

local UCIEngine = {}
UCIEngine.__index = UCIEngine

local function parse_uci_line(line, state)
  line = line:match("^%s*(.-)%s*$")
  local eng = state._engine

  if line == "kill" then
      state.to_uciok = -1
  elseif line == "uciok" then
    state.uciok = true
    eng:_trigger("uciok")
  elseif line:find("^id name") then
    state.id_name = line:match("^id name%s+(.+)$")
    eng:_trigger("id_name", state.id_name)
  elseif line:find("^id author") then
    state.id_author = line:match("^id author%s+(.+)$")
    eng:_trigger("id_author", state.id_author)
  elseif line:find("^option") then
    -- Robust parsing for option lines, handling names with spaces and min/max
    local parts = {}
    for part in line:gmatch("[^%s]+") do
      table.insert(parts, part)
    end

    local name_start_idx
    for i = 1, #parts do
      if parts[i] == "name" then
        name_start_idx = i + 1
        break
      end
    end

    if name_start_idx then
      local name_parts = {}
      local type_start_idx
      for i = name_start_idx, #parts do
        if parts[i] == "type" then
          type_start_idx = i
          break
        end
        table.insert(name_parts, parts[i])
      end
      local name = table.concat(name_parts, " ")

      if type_start_idx then
        local typ = parts[type_start_idx + 1]
        local def = nil
        local min_val = nil
        local max_val = nil
        local current_value = nil

        -- Iterate through the rest of the parts to find default, min, max
        for i = type_start_idx + 2, #parts do -- Start after 'type <value>'
          if parts[i] == "default" then
            def = parts[i+1]
            current_value = def -- Initialize current_value with default
          elseif parts[i] == "min" then
            min_val = parts[i+1]
          elseif parts[i] == "max" then
            max_val = parts[i+1]
          end
        end

        -- Store the option's properties including min and max
        state.options[name] = {
          type = typ,
          default = def,
          value = current_value, -- Last set value (initially default)
          min = min_val,
          max = max_val,
        }
        eng:_trigger("option", name, typ, def, min_val, max_val) -- Trigger with min/max
      end
    end
  elseif line == "readyok" then
    state.readyok = true
    eng:_trigger("readyok")
  elseif line:find("^info") then
    table.insert(state.infos, line)
    eng:_trigger("info", line)
  elseif line:find("^bestmove") then
    local mv, p = line:match("^bestmove%s+(%S+)%s*ponder%s*(%S*)$")
    if not p then mv = line:match("^bestmove%s+(%S+)") end
    state.bestmove = mv
    state.ponder = (p ~= "" and p) or nil
    eng:_trigger("bestmove", mv, state.ponder)
  end
end

function UCIEngine.spawn(cmd, args)
  local pid, rfd, wfd_or_err = Utils.execInSubProcess(cmd, args, true, false)
  if not pid then return nil, rfd end

  local self = setmetatable({}, UCIEngine)
  self.pid = pid
  self.fd_read = rfd
  self.fd_write = wfd_or_err
  self.callbacks = {}

  self.state = {
    uciok = false,
    id_name = nil,
    id_author = nil,
    options = {}, -- This will store detailed info about options, including min/max
    readyok = false,
    infos = {},
    bestmove = nil,
    ponder = nil,
    _engine = self,
  }

  self._reader = Utils.reader(self.fd_read,
                              function(line)
                                parse_uci_line(line, self.state)
                                self:_trigger("line", line)
                              end,
                              "Kochess DBG UCI")
  self.send = Utils.writer(self.fd_write, true, "Kochess DBG UCI")
  return self
end

function UCIEngine:on(event, fn)
    assert(type(event) == "string", "event must be a string")
    assert(type(fn) == "function", "callback must be a function")
    self.callbacks[event] = self.callbacks[event] or {}
    table.insert(self.callbacks[event], fn)
end

function UCIEngine:_trigger(event, ...)
    local list = self.callbacks[event]
    if not list then return end
    for _, fn in ipairs(list) do
        pcall(fn, ...)
    end
end

function UCIEngine:uci()
  -- Reset relevant state for a new UCI session
  for k in pairs(self.state) do self.state[k] = nil end
  self.state.options = {}
  self.state.infos = {}
  self.state.uciok = false
  self.state.to_uciok = 10
  self.state.readyok = false
  self.state._engine = self

  self.send("uci")

  Utils.pollingLoop(1,
                    self._reader,
                    function()
                        self.state.to_uciok = self.state.to_uciok - 1
                        return not self.state.uciok and 0 < self.state.to_uciok
                    end
  )

end

function UCIEngine:isready()
  self.state.readyok = false
  self.send("isready")
end

-- New setOption method
function UCIEngine:setOption(name, value)
  assert(type(name) == "string", "setOption: 'name' must be a string")
  local cmd = "setoption name " .. name
  if value ~= nil then
    cmd = cmd .. " value " .. tostring(value)
  end
  self.send(cmd)

  -- Update the internal state of options to reflect the new setting
  if not self.state.options[name] then
    -- If the option wasn't advertised by the engine, create a basic entry for it
    self.state.options[name] = { value = value }
  else
    -- If it was advertised, update its current value
    self.state.options[name].value = value
  end
  -- Trigger an event for external listeners that an option has been set
  self:_trigger("option_set", name, value)
end

function UCIEngine:position(spec)
  assert(type(spec) == "table", "position: expected a table")
  local cmd = "position"

  if spec.fen then
    assert(type(spec.fen) == "string", "position: 'fen' must be a string")
    cmd = cmd .. (spec.fen == "startpos" and " startpos" or " fen " .. spec.fen)
  else
    cmd = cmd .. " startpos"
  end

  if spec.moves then
    assert(type(spec.moves) == "string", "position: 'moves' must be a string")
    local moves = spec.moves:match("^%s*(.-)%s*$")
    if #moves > 0 then
      cmd = cmd .. " moves " .. moves
    end
  end

  self.send(cmd)
end

function UCIEngine:go(opts)
  local cmd = "go"
  for k, v in pairs(opts or {}) do
    cmd = cmd .. " " .. k .. " " .. tostring(v)
  end
  self.state.bestmove = nil
  self.send(cmd)

  Utils.pollingLoop(1,
                    self._reader,
                    function() return not self.state.bestmove and 0 < self.state.to_uciok end)
end

function UCIEngine:stop()
    if self.uciok then
        self.send("stop")
        self.send("quit") -- Send quit command to engine before closing
    end
    self.state.to_uciok = -1
end

M.UCIEngine = UCIEngine
return M
