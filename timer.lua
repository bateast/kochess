-- chess_timer.lua
-- A Lua module for a chess timer that counts down from a specified duration for each player.
local Chess = require("chess/src/chess")
local Utils = require("utils")

local Timer = {}
local TIMER_TIMEOUT = 10
Timer.__index = Timer

--- Creates a new ChessTimer instance.
-- @param duration The total time for each player in seconds.
-- @param callback A function to call every second while the timer is running.
-- @return A new instance of ChessTimer.
function Timer:new(duration, increment, callback)
    local obj = {
        base = duration,  -- Total time for each player in seconds
        increment = increment,
        time = duration,
        currentPlayer = Chess.WHITE,
        running = false,
        startTime = 0,
        callback = callback  -- Store the callback function
    }
    setmetatable(obj, self)
    return obj
end

--- Starts the timer for the current player and the coroutine.
function Timer:start()
    if not self.running then
        self.startTime = os.time()
        self.running = true
        if self.callback then
            Utils.pollingLoop(TIMER_TIMEOUT,
                              function()
                                  if self:getRemainingTime(self.currentPlayer) <= 0 then
                                      self:stop()  -- Stop the timer if time is up
                                      return
                                  end
                                  self.callback()
                              end,
                              function()
                                  return self.running
                              end,
                              false)
        end
    end
end

--- Stops the timer and updates the remaining time for the current player.
function Timer:stop()
    if self.running then
        local elapsed = os.difftime(os.time(), self.startTime)
        self.time[self.currentPlayer] = math.max(0, self.time[self.currentPlayer] - elapsed
                                                 + self.increment[self.currentPlayer])
        self.running = false
    end
end

--- Switches the turn to the other player and starts their timer.
function Timer:switchPlayer()
    self:stop()  -- Stop the current timer
    self.currentPlayer = (self.currentPlayer == Chess.WHITE) and Chess.BLACK or Chess.WHITE
    self:start()  -- Start the timer for the next player
end

--- Resets the timer for both players to the initial duration.
function Timer:reset()
    self.time = self.base
    self.currentPlayer = Chess.WHITE
    self.running = false
end

--- Gets the remaining time for the specified player.
-- @param player The player to check (Chess.WHITE or Chess.BLACK).
-- @return The remaining time in seconds for the specified player.
function Timer:getRemainingTime(player)
    return self.time[player]
end

--- Formats the time in seconds into a "MM:SS" format.
-- @param seconds The time in seconds to format.
-- @return A string representing the formatted time.
function Timer:formatTime(seconds)
    local hours = math.floor(seconds / (60 * 60))
    local minutes = math.floor(seconds / 60) % 60
    local secs = seconds % 60
    return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

return Timer
