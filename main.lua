-- kochess.lua
-- Core dependencies
local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")
local Size = require("ui/size")
local Geometry = require("ui/geometry")

-- UI Widgets
local Event = require("ui/event")
local ButtonWidget    = require("ui/widget/button")
local infoMessage = require("ui/widget/infomessage")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TitleBarWidget = require("ui/widget/titlebar")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local InputText = require("ui/widget/inputtext")
local InputDialog = require("ui/widget/inputdialog")
local PathChooser = require("ui/widget/pathchooser")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local MovableContainer = require("ui/widget/container/movablecontainer")

-- Chess Logic Modules
local Chess = require("chess")
local ChessBoard = require("board")
local Timer = require("timer")
local Uci = require("uci")
local SettingsWidget = require("settingswidget")

-- Utilities
local Logger = require("logger")
local _ = require("gettext") -- Localization function

-- Configuration Constants
local DEFAULT_TIME_MINUTES = 30
local UCI_ENGINE_PATH = "resources/bin/stockfish"
local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE
local PGN_LOG_FONT = "smallinfofont"
local PGN_LOG_FONT_SIZE = 14
local TOOLBAR_PADDING = 4
local PGN_LOG_PAST_MOVES_TO_SHOW = 10 -- Number of past moves to show in PGN log for context

-- Debugging functions for Kochess
local function dbg(txt, label)
    Logger.dbg("Kochess " .. (label or "") .. ": " .. txt)
end

local function dbgTable(tbl, label)
    label = label or "dbgTable"
    if not tbl then
        Logger.dbg(("Kochess %s: <nil>"):format(label))
        return
    end
    local parts = {}
    for k, v in pairs(tbl) do
        -- Ensure values are converted to strings for concatenation to prevent errors
        table.insert(parts, ("%s=%s"):format(k, tostring(v)))
    end
    Logger.dbg(("Kochess %s: {%s}"):format(label, table.concat(parts, ", ")))
end

--- map(tbl, fn) -> new_tbl
-- Applies fn(value, index) to each element of the array-style table `tbl`
-- and returns a new array of the results. This is a common functional programming utility.
local function map(tbl, fn)
    local out = {}
    for i, v in ipairs(tbl) do
        out[i] = fn(v, i)
    end
    return out
end

-- Define the main Kochess application widget, extending FrameContainer
local Kochess = FrameContainer:extend{
    name = "kochess_root",
    background = BACKGROUND_COLOR,
    bordersize = 0,
    padding = 0,
    full_width = Screen:getWidth(),
    full_height = Screen:getHeight(),
    notation_font = PGN_LOG_FONT,
    notation_size = PGN_LOG_FONT_SIZE,
    -- Internal state variables (initialized in init or startGame)
    game = nil,
    timer = nil,
    engine = nil,
    board = nil,
    pgn_log = nil,
    status_bar = nil,
    running = false,
}

--- Kochess:init()
-- Initializes the Kochess application, registers it with the dispatcher
-- and adds it to the main menu.
function Kochess:init()
    self.dimensions = Geometry:new{ w = self.full_width, h = self.full_height }
    self.covers_fullscreen = true -- Indicates this widget should cover the entire screen

    -- Register a dispatcher action to allow starting Kochess from elsewhere
    Dispatcher:registerAction("kochess", {
        category = "none",
        event = "KochessStart",
        title = _("Chess Game"),
        general = true,
    })

    -- Register this instance to the UIManager's main menu
    self.ui.menu:registerToMainMenu(self)
end

--- Kochess:addToMainMenu(menu_items)
-- Callback for the UIManager to add Kochess as an option in the main menu.
-- @param menu_items Table of menu items to append to.
function Kochess:addToMainMenu(menu_items)
    dbg("Adding Kochess to main menu", "MENU")
    menu_items.kochess = {
        text = _("Chess Game"),
        sorting_hint = "tools", -- Suggests where it should appear in the menu
        callback = function() self:startGame() end, -- Action when selected
        keep_menu_open = false, -- Close menu after starting game
    }
end

--- Kochess:startGame()
-- Entry point for starting a new chess game.
-- Initializes all game components (logic, engine, board) and builds the UI.
function Kochess:startGame()
    dbg("Starting new chess game session", "GAME START")
    self:initializeGameLogic()
    self:initializeEngine()
    self:initializeBoard()
    self:buildUILayout()
    -- self:registerHold() -- Re-enable if 'hold' functionality on PGN log is desired
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
    self.board:updateBoard() -- Redraw the chess board
    UIManager:show(self) -- Show the main Kochess UI
    UIManager:setDirty(self, "full") -- Request a full redraw
end

--- Kochess:initializeGameLogic()
-- Sets up the core chess game state and timer.
function Kochess:initializeGameLogic()
    dbg("Initializing chess game logic and timer", "GAME INIT")
    self.game = Chess:new()
    self.game.reset() -- Reset the game to the initial position
    self.game.initial_fen = self.game.fen() -- Store the initial FEN string
    dbg(self.game.fen(), "INITIAL FEN")

    -- Initialize the game timer with default settings
    self.timer = Timer:new(
        {[Chess.WHITE] = DEFAULT_TIME_MINUTES * 60,
            [Chess.BLACK] = DEFAULT_TIME_MINUTES * 60},
        {[Chess.WHITE] = 0, [Chess.BLACK] = 0,}, function()
            self:updateTimerDisplay() -- Callback to update timer display every second
    end)
    self.running = false -- Game is paused initially, starts on first human move or explicit play
end

--- Kochess:initializeEngine()
-- Spawns and configures the UCI chess engine (e.g., Stockfish).
function Kochess:initializeEngine()
    dbg("Initializing UCI engine and setting up event listeners", "ENGINE INIT")
    self.engine = Uci.UCIEngine.spawn(UCI_ENGINE_PATH, {})
    if not self.engine then
        dbg("Failed to spawn UCI engine at: " .. UCI_ENGINE_PATH, "ERROR")
        UIManager:show(infoMessage:new{
            text = _("Error"),
            message = _("Failed to load chess engine.\nPlease ensure Stockfish is installed at %s"):format(UCI_ENGINE_PATH),
        })
        return
    end

    -- Setup event listeners for UCI engine communication
    self.engine:on("uciok", function()
        dbg("UCI: uciok received (engine is ready)", "ENGINE")
        self:updatePgnLogInitialText() -- Update PGN log with engine name/author
    end)

    self.engine:on("bestmove", function(move_uci, ponder_move)
        dbg("UCI: bestmove received: " .. move_uci .. " ponder: " .. (ponder_move or "none"), "ENGINE")
        -- Only process the bestmove if it's currently the engine's turn
        if not self.game.is_human(self.game.turn()) then
            self:uciMove(move_uci)
        end
    end)

    self.engine:on("id_name", function(name)
        dbg("UCI: engine name identified: " .. name, "ENGINE")
    end)

    self.engine:on("option", function(name, type, default_val)
        dbg(("UCI: option %s type:%s default:%s"):format(name, type, tostring(default_val)), "ENGINE")
    end)

    self.engine:on("readyok", function()
        dbg("UCI: readyok (engine is ready for commands)", "ENGINE")
    end)

    self.engine:on("eof", function()
        dbg("UCI: eof (engine process terminated)", "ENGINE")
        -- Potentially display an error message or attempt to restart the engine
        UIManager:show(infoMessage:new{
            text = _("Engine Offline"),
            message = _("The chess engine has stopped running."),
        })
    end)

    -- Send initial UCI command to the engine to get its identity
    self.engine:uci()
end

--- Kochess:updatePgnLogInitialText()
-- Updates the PGN log widget with initial welcome message and engine information.
function Kochess:updatePgnLogInitialText()
    local text = _("Welcome to Kochess!\nWhite to play.")
    if self.engine and self.engine.state.uciok then
        text = text .. "\nEngine ready: " .. (self.engine.state.id_name or "")
        if self.engine.state.id_author then
            text = text .. " " .. _("by") .. " " .. self.engine.state.id_author
        end
    else
        text = text .. "\n" .. _("Chess engine not loaded or ready.")
    end
    if self.pgn_log then
        self.pgn_log:setText(text)
        UIManager:setDirty(self, "ui") -- Request UI redraw to show updated text
    end
end

--- Kochess:initializeBoard()
-- Sets up the ChessBoard widget.
-- NOTE: This now expects ChessBoard to provide an 'onPromotionNeeded' callback
-- when a human player attempts a pawn promotion, rather than directly executing the move.
function Kochess:initializeBoard()
    dbg("Initializing chess board widget", "BOARD INIT")
    self.board = ChessBoard:new{
        game = self.game,
        width = self.full_width,
        height = math.floor(0.7 * self.full_height), -- Calculate board height
        -- Callback for when any move (human or engine) has been executed and needs UI updates.
        moveCallback = function(move) self:onMoveExecuted(move) end,
        holdCallback = function() UIManager:setDirty(self, "full") end,
        -- NEW: This callback is expected to be triggered by ChessBoard
        -- when a human pawn reaches the promotion rank, before game.move() is called.
        onPromotionNeeded = function(from_sq, to_sq, pawn_color)
            self:openPromotionDialog(from_sq, to_sq, pawn_color)
        end,
    }
end

--- Kochess:registerHold()
-- Registers a hold gesture listener specifically for the PGN log area.
-- This allows for text selection or other interactions.
-- (Currently commented out in startGame, re-enable if needed).
function Kochess:registerHold()
    dbg("Registering hold gesture on PGN log area", "UI")
    self.pgn_log:registerTouchZones({
        {
            id = "text_hold",
            ges = "hold", -- Gesture type
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1, -- Full screen zone
            },
            handler = function(ges)
                dbg('Kochess DBG: Chess User held screen!', "HOLD")
                dbgTable(ges, "Hold Gesture Info")
                self.pgn_log:onHoldWord(
                    function(word)
                        dbg("Text: on hold '" .. word .. "'", "HOLD")
                    end,
                    ges
                )
                return true -- Consume the event
            end
        },
    })
end

--- Kochess:createPgnLogWidget(initial_text, width, height)
-- Helper to create and configure the PGN log TextBoxWidget.
-- @param initial_text String to display initially.
-- @param width Numeric width of the widget.
-- @param height Numeric height of the widget.
-- @return TextBoxWidget instance.
function Kochess:createPgnLogWidget(initial_text, width, height)
    return TextBoxWidget:new{
        use_xtext = true, -- Enables rich text features if supported
        text = initial_text,
        face = Font:getFace(self.notation_font, self.notation_size),
        bold = false,
        scroll = true,
        editable = false,
        select_mode = false,
        dialog = self, -- Parent dialog for context
        width = width,
        height = height,
    }
end

--- Kochess:createToolbarButton(icon, width, height, callback, hold_callback)
-- Helper to create standard toolbar buttons with icons.
-- @param icon String icon name.
-- @param width Numeric icon width.
-- @param height Numeric icon height.
-- @param callback Function to call on tap.
-- @param hold_callback Function to call on hold (optional).
-- @return ButtonWidget instance.
function Kochess:createToolbarButton(icon, width, height, callback, hold_callback)
    return ButtonWidget:new{
        icon = icon,
        icon_width = width,
        icon_height = height,
        margin = 0,
        padding_h = 0,
        callback = callback,
        hold_callback = hold_callback,
    }
end

--- Kochess:buildUILayout()
-- Constructs the entire user interface for the Kochess application.
function Kochess:buildUILayout()
    dbg("Building main UI layout structure", "UI")
    -- Create top and bottom bars
    local title_bar = self:createTitleBar()
    local status_bar = self:createStatusBar()

    -- Calculate dynamic heights for board, PGN log, and toolbar
    local board_h = self.board:getSize().h
    local title_h = title_bar:getSize().h
    local status_h = status_bar:getSize().h
    local total_h = self.full_height
    local log_h = total_h - title_h - board_h - status_h

    -- Ensure a minimum height for the log area and toolbar to prevent layout issues
    if log_h < 100 then log_h = 100 end

    -- Calculate toolbar width relative to log height, with a cap
    local toolbar_width = math.floor(log_h / 4 + 4 * TOOLBAR_PADDING + 4 * Size.border.button)
    if toolbar_width > self.full_width / 3 then toolbar_width = math.floor(self.full_width / 3) end

    local pgn_log_width = self.full_width - toolbar_width
    self.pgn_log = self:createPgnLogWidget(_("Welcome to Kochess!\nWhite to play."), pgn_log_width, log_h)

    -- Wrap PGN log in a centered frame
    local log_frame = FrameContainer:new{
        background = BACKGROUND_COLOR,
        padding = 0,
        bordersize = 0,
        margin = 0,
        CenterContainer:new{
            dimen = self.pgn_log:getSize(),
            self.pgn_log,
        }
    }

    -- Calculate button icon dimensions for the toolbar
    local btn_icon_width = toolbar_width - 2 * TOOLBAR_PADDING
    local btn_icon_height = math.floor((log_h - TOOLBAR_PADDING * 2) / 4 - Size.border.button * 2)

    -- Create the vertical toolbar with navigation and file operations
    local toolbar = VerticalGroup:new{
        width = toolbar_width,
        height = log_h,
        padding = TOOLBAR_PADDING,
        -- Back one move (tap for one, hold for all)
        self:createToolbarButton("chevron.left", btn_icon_width, btn_icon_height,
            function() self:handleUndoMove(false) end,
            function() self:handleUndoMove(true) end
        ),
        -- Forward one move (tap for one, hold for all)
        self:createToolbarButton("chevron.right", btn_icon_width, btn_icon_height,
            function() self:handleRedoMove(false) end,
            function() self:handleRedoMove(true) end
        ),
        -- Save PGN
        self:createToolbarButton("bookmark", btn_icon_width, btn_icon_height,
            function() UIManager:show(self:openSaveDialog()) end
        ),
        -- Load PGN
        self:createToolbarButton("appbar.filebrowser", btn_icon_width, btn_icon_height,
            function() self:openLoadPgnDialog() end
        ),
    }

    -- Group toolbar and PGN log horizontally
    local pgngroup = FrameContainer:new{
        background = BACKGROUND_COLOR,
        padding = 0,
        HorizontalGroup:new{
            height = log_h,
            toolbar,
            log_frame,
        }
    }

    -- Assemble the main vertical layout: TitleBar, Board, PGN Group, StatusBar
    local main_vgroup = VerticalGroup:new{
        align = "center",
        width = self.full_width,
        height = self.full_height,
        title_bar,
        self.board,
        pgngroup,
        status_bar,
    }
    self.status_bar = status_bar -- Store reference for dynamic updates

    -- Center the entire application layout on the screen
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        main_vgroup
    }
end

--- Kochess:handleUndoMove(all_moves)
-- Handles the undo action, either for one move or all moves.
-- Stops the engine and timer, performs undo, updates UI, and restarts timer.
-- @param all_moves Boolean, true to undo all moves, false for single move.
function Kochess:handleUndoMove(all_moves)
    dbg("Handling undo move(s), all: " .. tostring(all_moves), "ACTION")
    self:stopUCI() -- Stop any ongoing engine calculations
    self.timer:stop() -- Pause the timer during undo/redo

    local moved = false
    if all_moves then
        while self.game.undo() do moved = true end -- Keep undoing until no more moves
    else
        moved = self.game.undo() -- Undo a single move
    end

    if moved then
        self.board:updateBoard() -- Redraw board after undo
        self:updatePgnLog() -- Update PGN text
        UIManager:setDirty(self, "ui") -- Request UI redraw
    end
    self.timer:start() -- Restart timer
end

--- Kochess:handleRedoMove(all_moves)
-- Handles the redo action, either for one move or all moves.
-- Stops the engine and timer, performs redo, updates UI, and restarts timer.
-- @param all_moves Boolean, true to redo all moves, false for single move.
function Kochess:handleRedoMove(all_moves)
    dbg("Handling redo move(s), all: " .. tostring(all_moves), "ACTION")
    self:stopUCI()
    self.timer:stop()

    local moved = false
    if all_moves then
        while self.game.redo() do moved = true end -- Keep redoing until no more moves
    else
        moved = self.game.redo() -- Redo a single move
    end

    if moved then
        self.board:updateBoard()
        self:updatePgnLog()
        UIManager:setDirty(self, "ui")
    end
    self.timer:start()
end

--- Kochess:openLoadPgnDialog()
-- Opens a file chooser dialog to load a PGN chess game from a file.
function Kochess:openLoadPgnDialog()
    dbg("Opening PGN load file dialog", "FILE")
    UIManager:show(
        PathChooser:new{
            title = _("Load PGN File"),
            select_directory = false, -- Only allow file selection
            onConfirm = function(path)
                if not path then return end -- User cancelled
                local fh = io.open(path, "r")
                if not fh then
                    dbg("Failed to open PGN file: " .. path, "ERROR")
                    UIManager:show(infoMessage:new{
                        text = _("Error"), message = _("Could not open file:\n") .. path,
                    })
                    return
                end
                local pgn_data = fh:read("*a") -- Read entire file content
                fh:close()

                self:stopUCI()
                self.timer:stop()
                self.game.reset() -- Reset current game before loading new PGN

                self.game.load_pgn(pgn_data)

                -- After loading, rewind to the start of the game if necessary
                while self.game.undo() do end
                self.board:updateBoard()
                self:updatePgnLog()
                self:updateTimerDisplay()
                self:updatePlayerDisplay()
                UIManager:setDirty(self, "full")
                self.timer:start()
            end,
        }
    )
end

--- Kochess:launchNextMove()
-- Manages the transition to the next move, including switching timers and
-- potentially launching the UCI engine if it's an AI turn.
function Kochess:launchNextMove()
    dbg("Launching next move sequence", "GAME FLOW")
    self.timer:switchPlayer() -- Switch the active player for the timer
    self:updateTimerDisplay() -- Update timer display immediately

    -- If it's the engine's turn, initiate UCI calculation
    if self.engine and self.engine.state.uciok then
        if self.engine.state.bestmove then
            -- If a previous 'go' command is still active and returned a bestmove, stop it first
            self:stopUCI()
        end
        if not self.game.is_human(self.game.turn()) then
            self:launchUCI() -- Tell engine to find best move
        end
    end
end

--- formatPgnMove(idx, san)
-- Helper function to format a single move for PGN display, including move numbers.
-- @param idx Number, the index of the move in the history (1-based).
-- @param san String, the Standard Algebraic Notation of the move.
-- @return String, formatted move.
local function formatPgnMove(idx, san)
    local pgn_text = ""
    if idx % 2 == 1 then -- If it's White's move (odd index in 1-based array)
        local move_no = math.floor(idx / 2) + 1 -- Calculate move number
        pgn_text = pgn_text .. " " .. tostring(move_no) .. "."
    end
    pgn_text = pgn_text .. " " .. san
    return pgn_text
end

--- Kochess:updatePgnLog()
-- Generates and updates the text content of the PGN log widget.
-- Includes headers, past moves, current comment, and future (redo) moves.
function Kochess:updatePgnLog()
    dbg("Updating PGN log text content", "UI")
    local headers = self.game:header()
    local moves = self.game:history()
    local futures = self.game:redo_history()
    local comment = self.game:get_comment()
    local pgn_chunks = {}

    -- Helper to append multiple items to the `pgn_chunks` table
    local function push(...)
        for i = 1, select('#', ...) do
            table.insert(pgn_chunks, select(i, ...))
        end
    end

    -- 1) Build header lines
    local function buildHeader()
        if not headers then return end
        if headers.Event then push(headers.Event) end
        if headers.EventDate then push(" (" .. headers.EventDate .. ")") end
        if headers.Event or headers.EventDate then push("\n") end
        if headers.White then
            push(_("White") .. ": " .. headers.White)
            if headers.Black then push(" – ") end
        end
        if headers.Black then push(_("Black") .. ": " .. headers.Black) end
        if headers.White or headers.Black then push("\n") end
    end

    -- 2) Build completed moves (showing a limited number of past moves)
    local function buildMoves()
        local startIndex = math.max(1, #moves - PGN_LOG_PAST_MOVES_TO_SHOW + 1)
        if startIndex > 1 then
            push("...") -- Indicate that earlier moves are truncated
        end

        for idx = startIndex, #moves do
            push(formatPgnMove(idx, moves[idx]))
        end

        -- Store the character position for current game state for scrolling
        self.pgn_log.charpos = #table.concat(pgn_chunks)
    end

    -- 3) Append current move comment if present
    local function buildComment()
        if comment and comment ~= "" then
            push("\n" .. comment)
        end
    end

    -- 4) Build future (redo) moves
    local function buildFutures()
        if #futures == 0 then return end
        push("\n\n" .. _("Future moves:") .. "\n")
        -- Iterate backwards through futures as `redo_history` usually stores oldest moves first
        for rev_idx = #futures, 1, -1 do
            local entry = futures[rev_idx]
            -- Calculate the overall SAN index for future moves
            local san_idx = (#futures - rev_idx + 1) + #moves
            push(formatPgnMove(san_idx, entry.san))
        end
    end

    -- Assemble all parts into the final PGN text
    buildHeader()
    buildMoves()
    buildComment()
    buildFutures()

    local final_text = table.concat(pgn_chunks)
    self.pgn_log:setText(final_text)
    self.pgn_log:scrollViewToCharPos() -- Scroll the log to the last current move
end

--- Kochess:onMoveExecuted(move)
-- Callback function invoked when a chess move is successfully made on the board.
-- Triggers UI updates and the next move sequence. This is for both human (after promotion if needed)
-- and engine moves.
-- @param move Table, the move object with details like SAN.
function Kochess:onMoveExecuted(move)
    dbg("Chess move executed: " .. move.san, "GAME")
    self.running = true -- Game is now officially running
    self:updatePgnLog() -- Update the PGN display
    self:launchNextMove() -- Prepare for the next player's turn
    UIManager:setDirty(self, "ui") -- Request UI redraw
end

--- Kochess:uciMove(inmove_str)
-- Interprets a UCI move string from the engine and applies it to the game.
-- @param inmove_str String, the UCI move string (e.g., "e2e4", "e7e8q").
function Kochess:uciMove(inmove_str)
    dbg("Processing UCI move string: " .. inmove_str, "UCI")
    -- Parse the UCI string into a table format compatible with Chess.move
    local tmove = {
        from = string.sub(inmove_str, 1, 2),
        to = string.sub(inmove_str, 3, 4),
        promotion = (#inmove_str == 5) and string.sub(inmove_str, 5, 5) or nil -- Check for promotion
    }

    local move = self.game.move(tmove) -- Attempt to make the move
    if move then
        self.board:handleGameMove(move) -- Update the board visually
    end
end

--- Kochess:launchUCI()
-- Sends the current game position and time controls to the UCI engine
-- and requests it to find the best move.
function Kochess:launchUCI()
    dbg("Requesting bestmove from UCI engine", "UCI")
    local params = {
        wtime = self.timer:getRemainingTime(Chess.WHITE) * 1000, -- White's remaining time in ms
        btime = self.timer:getRemainingTime(Chess.BLACK) * 1000, -- Black's remaining time in ms
    }

    -- Convert game history to UCI move string format (e.g., "e2e4 e7e5 g1f3")
    local moves_uci_format = table.concat(
        map(self.game.history({ verbose = true }), function(m)
            return m.from .. m.to .. (m.promotion or "") -- Include promotion piece if present
        end),
        " "
    )

    local position = { moves = moves_uci_format } -- Define the game position

    self.engine:position(position) -- Send the position to the engine
    self.engine:go(params) -- Tell the engine to calculate the best move
end

--- Kochess:stopUCI()
-- Sends a "stop" command to the UCI engine, halting any ongoing search.
function Kochess:stopUCI()
    dbg("Sending 'stop' command to UCI engine", "UCI")
    if self.engine and self.engine.state.uciok then
        self.engine.send("stop")
    end
end

--- getPlayerIndicator(is_running, turn)
-- Helper function to determine the current player indicator character.
-- @param is_running Boolean, true if the game is currently running.
-- @param turn String, the current player's color ("w" or "b").
-- @return String, the indicator character.
local function getPlayerIndicator(is_running, turn)
    if is_running then
        return (turn == Chess.WHITE) and " ⤆ " or " ⤇ " -- Left arrow for White, right for Black
    else
        return " ⤊ " -- Up arrow for paused/initial state
    end
end

--- Kochess:updateTimerDisplay()
-- Updates the timer display in the status bar.
function Kochess:updateTimerDisplay()
    -- dbg("Updating timer display", "UI") -- This can be very chatty if un-commented
    local fmt = self.timer.formatTime -- Timer's formatTime function
    local white_time = self.timer:getRemainingTime(Chess.WHITE)
    local black_time = self.timer:getRemainingTime(Chess.BLACK)
    local player_indicator = getPlayerIndicator(self.running, self.game.turn())
    self.status_bar:setTitle(fmt(self.timer, white_time) .. player_indicator .. fmt(self.timer, black_time))
    UIManager:setDirty(self.status_bar, "full") -- Request redraw for status bar
end

--- Kochess:updatePlayerDisplay()
-- Updates the player type (Human/Engine) display in the status bar subtitle.
function Kochess:updatePlayerDisplay()
    dbg("Updating player type display", "UI")
    local function labelFor(color)
        return self.game.is_human(color) and _("Human")
            or ((self.engine.state.id_name or _("Engine"))
                .. (self.engine.state.options["UCI_Elo"] and (" (" ..  self.engine.state.options["UCI_Elo"].value .. ")")
                    or ""))
    end
    local player_indicator = getPlayerIndicator(self.running, self.game.turn())
    self.status_bar:setSubTitle(labelFor(Chess.WHITE) .. player_indicator .. labelFor(Chess.BLACK))
    UIManager:setDirty(self.status_bar, "full")
end

--- Kochess:resetGame()
-- Resets the entire chess game to its initial state.
function Kochess:resetGame()
    dbg("Resetting current game", "ACTION")
    self.running = false
    self:stopUCI()
    if self.engine and self.engine.state.uciok then
        self.engine.send("newgame") -- Inform engine of new game
    end
    self.game.reset() -- Reset game logic state
    self.game.initial_fen = self.game.fen() -- Reset initial FEN

    self.timer:reset() -- Reset timers
    self:updateTimerDisplay()
    self:updatePlayerDisplay()

    self.pgn_log:setText(_("New game.\nWhite to play."))
    self.board:updateBoard()
    UIManager:setDirty(self, "full")
end

--- Kochess:handleSaveFile(dialog, filename_input, current_dir)
-- Helper function to perform the actual file saving operation for PGN.
-- @param dialog InputDialog instance.
-- @param filename_input InputText widget for the filename.
-- @param current_dir String, the directory to save in.
function Kochess:handleSaveFile(dialog, filename_input, current_dir)
    dbg("Executing PGN file save", "FILE")
    filename_input:onCloseKeyboard() -- Ensure on-screen keyboard is closed

    local dir = current_dir
    local file = filename_input:getText():gsub("\n$", "") -- Get filename, remove trailing newline

    -- Append ".pgn" extension if not already present
    if not file:lower():match("%.pgn$") then
        file = file .. ".pgn"
    end

    local sep = package.config:sub(1, 1) -- Get platform-specific path separator
    local fullpath = dir .. sep .. file

    local pgn_data = self.game.pgn() -- Get the PGN string from the game

    local fh, err = io.open(fullpath, "w") -- Open file for writing
    if not fh then
        dbg("Failed to open file for write: " .. tostring(err), "ERROR")
        UIManager:show(infoMessage:new{
            text = _("Error"), message = _("Could not save file:\n") .. tostring(err),
        })
        return
    end

    fh:write(pgn_data) -- Write PGN data
    fh:close() -- Close the file handle

    UIManager:close(dialog) -- Close the save dialog
    dbg("PGN successfully saved to " .. fullpath, "FILE")
    UIManager:show(infoMessage:new{
        text = _("Saved"), message = _("Game saved to:\n") .. fullpath
    })
end

--- Kochess:openSaveDialog()
-- Creates and displays the dialog for saving the current game as a PGN file.
-- @return InputDialog instance.
function Kochess:openSaveDialog()
    dbg("Opening 'Save PGN' dialog", "UI")
    local current_dir = lfs.currentdir() -- Get current working directory as default save location
    local dialog
    local filename_input -- Forward declaration for scope

    local function onSaveConfirm()
        self:handleSaveFile(dialog, filename_input, current_dir)
    end

    dialog = InputDialog:new{
        title = _("Save current game as"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        filename_input:onCloseKeyboard()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true, -- Make this the default action on Enter
                    callback = onSaveConfirm,
                },
            }
        }
    }

    local dir_label = TextWidget:new{
        text = current_dir,
        face = Font:getFace("smallinfofont"),
        truncate_left = true, -- Truncate text if it's too long
        max_width = dialog:getSize().w * 0.8,
    }

    local browse_button = ButtonWidget:new{
        text = _("⋯"), -- Ellipsis icon for "Browse"
        tooltip = _("Choose folder"),
        callback = function()
            UIManager:show(
                PathChooser:new{
                    path = current_dir,
                    title = _("Select Save Folder"),
                    select_file = false, -- Only allow directory selection
                    show_files = true, -- Show files in directory (but not selectable)
                    parent = dialog, -- Set parent for correct dialog stacking
                    onConfirm = function(chosen)
                        if chosen and #chosen > 0 then
                            current_dir = chosen -- Update selected directory
                            dir_label:setText(chosen) -- Update displayed path
                            UIManager:setDirty(dialog, "ui") -- Request redraw of the dialog
                        end
                    end
                }
            )
        end,
    }

    filename_input = InputText:new{
        text = "game.pgn", -- Default filename
        focused = true, -- Automatically focus this input
        parent = dialog,
        enter_callback = onSaveConfirm, -- Trigger save when Enter is pressed in input field
    }

    -- Define the content layout for the save dialog
    local content = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        background = BACKGROUND_COLOR,
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            align = "left",
            dialog.title_bar,
            HorizontalGroup:new{
                spacing = Size.padding.large,
                TextWidget:new{ text = _("Folder") .. ":", face = Font:getFace("cfont", 22) },
                dir_label,
                HorizontalSpan:new{ width = Size.padding.small },
                browse_button,
            },
            HorizontalGroup:new{
                spacing = Size.padding.large,
                TextWidget:new{ text = _("Filename") .. ":", face = Font:getFace("cfont", 22) },
                filename_input,
            },
            CenterContainer:new{
                dimen = Geometry:new{
                    w = dialog.title_bar:getSize().w,
                    h = dialog.button_table:getSize().h,
                },
                dialog.button_table
            },
        },
    }

    -- Make the dialog movable and display it
    dialog.movable = MovableContainer:new{ content }
    dialog[1] = CenterContainer:new{ dimen = Screen:getSize(), dialog.movable }
    dialog:refocusWidget() -- Ensure the input field is focused
    return dialog
end

--- Kochess:openPromotionDialog(from_sq, to_sq, pawn_color)
-- Opens a dialog for the user to choose a promotion piece when a pawn reaches the 8th/1st rank.
-- This function is intended to be called by ChessBoard's 'onPromotionNeeded' callback.
-- @param from_sq String, the square the pawn moved from (e.g., "e7").
-- @param to_sq String, the square the pawn moved to (e.g., "e8").
-- @param pawn_color String, the color of the pawn ('w' or 'b').
function Kochess:openPromotionDialog(from_sq, to_sq, pawn_color)
    dbg(("Opening promotion dialog for %s pawn at %s to %s"):format(pawn_color, from_sq, to_sq), "PROMOTION")

    -- Define available promotion pieces (char and Chess constant mapping)
    local promotion_piece_map = {
        q = Chess.QUEEN,
        r = Chess.ROOK,
        b = Chess.BISHOP,
        n = Chess.KNIGHT,
    }
    local promotion_pieces_order = { "q", "r", "b", "n" } -- Order for display

    -- Define icons for the promotion pieces (matching board.lua's structure)
    local promotion_icons = {
        [Chess.QUEEN]  = { [Chess.WHITE] = "chess/wQ", [Chess.BLACK] = "chess/bQ" },
        [Chess.ROOK]   = { [Chess.WHITE] = "chess/wR", [Chess.BLACK] = "chess/bR" },
        [Chess.BISHOP] = { [Chess.WHITE] = "chess/wB", [Chess.BLACK] = "chess/bB" },
        [Chess.KNIGHT] = { [Chess.WHITE] = "chess/wN", [Chess.BLACK] = "chess/bN" },
    }

    local dialog = InputDialog:new{
        title = _("Choose Promotion Piece"),
        buttons = {}, -- Buttons will be created dynamically
    }

    -- Determine a reasonable size for the promotion piece icons
    local icon_size = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) / 10) -- Roughly 1/10th of smallest screen dimension
    if icon_size < 60 then icon_size = 60 end -- Minimum size
    if icon_size > 96 then icon_size = 96 end -- Maximum size

    -- Callback for when a promotion piece is chosen
    local function onPieceChosen(chosen_piece_char)
        dbg("Promotion piece chosen: " .. chosen_piece_char, "PROMOTION")
        UIManager:close(dialog) -- Close the promotion dialog

        -- Now, execute the actual chess move with the chosen promotion piece
        local tmove = { from = from_sq, to = to_sq, promotion = chosen_piece_char }
        local move_obj = self.game.move(tmove)

        if move_obj then
            self.board:handleGameMove(move_obj) -- Update the board visually with the new piece
            self:onMoveExecuted(move_obj) -- Trigger general post-move updates (PGN, timer, etc.)
        else
            -- This case should ideally not happen if Chess.move is robust,
            -- as the choice is valid.
            dbg(("Error applying promotion move from %s to %s with piece %s"):format(from_sq, to_sq, chosen_piece_char), "ERROR")
            UIManager:show(infoMessage:new{
                text = _("Error"),
                message = _("Failed to promote pawn. Please try again."),
            })
            self.board:updateBoard() -- Redraw to clear any attempted invalid highlights
            UIManager:setDirty(self, "ui")
        end
    end

    -- Create buttons for each promotion choice, using icons
    local button_widgets = {}
    for _, piece_char in ipairs(promotion_pieces_order) do
        local piece_type = promotion_piece_map[piece_char]
        local icon_path = promotion_icons[piece_type][pawn_color]
        table.insert(button_widgets, ButtonWidget:new{
            icon = icon_path, -- Use the icon path
            icon_width = icon_size,
            icon_height = icon_size,
            id = "promote_" .. piece_char,
            callback = function() onPieceChosen(piece_char) end,
            -- Optional: Add a text label below the icon if desired for clarity
            -- text = promotion_names[piece_char],
            -- text_align = "center",
        })
    end

    -- Arrange buttons in a vertical group for clarity
    local buttons_group = VerticalGroup:new{
        align = "center",
        spacing = Size.padding.large,
    }
    for _, btn in ipairs(button_widgets) do
        buttons_group[#buttons_group + 1] = btn
    end

    -- Define the content layout for the promotion dialog
    local content = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        background = BACKGROUND_COLOR,
        padding = Size.padding.large,
        margin = 0,
        VerticalGroup:new{
            align = "center",
            dialog.title_bar,
            VerticalSpan:new{ width = Size.padding.large },
            TextWidget:new{
                text = _("Select the piece for promotion:"),
                face = Font:getFace("cfont", 22),
                -- Ensure text fits within the dialog width
                max_width = dialog.width * 0.9,
                align = "center",
            },
            VerticalSpan:new{ width = Size.padding.large },
            buttons_group,
            VerticalSpan:new{ width = Size.padding.large },
            -- No general dialog.button_table needed as we handle specific choices
        },
    }

    -- Make the dialog movable and display it centered on the screen
    dialog.movable = MovableContainer:new{ content }
    dialog[1] = CenterContainer:new{ dimen = Screen:getSize(), dialog.movable }
    UIManager:show(dialog)
    -- Focus is typically handled by UIManager.show for new dialogs, but explicitly calling refocusWidget can ensure it.
    dialog:refocusWidget()
end

--- Kochess:createTitleBar()
-- Creates the application's main title bar with game controls.
-- @return TitleBarWidget instance.
function Kochess:createTitleBar()
    dbg("Creating application title bar", "UI")
    return TitleBarWidget:new{
        fullscreen = true,
        title = _("Chess for Koreader"),
        title_align = "center",
        title_multilines = false,
        title_shrink_font_to_fit = true,
        with_bottom_line = false,
        left_icon = "home", -- Icon for resetting game
        margin = 0,
        padding_h = 0,
        left_icon_tap_callback = function()
            self:resetGame()
        end,
        close_callback = function()
            self.timer:stop() -- Stop the timer when closing
            if self.engine and self.engine.state.uciok then
                self:stopUCI()
                self.engine.send("quit") -- Send quit command to engine before closing
            end
            UIManager:close(self) -- Close the Kochess UI
        end,
    }
end

--- Kochess:createStatusBar()
-- Creates the status bar, displaying timers and player types.
-- @return TitleBarWidget instance (used as a status bar).
function Kochess:createStatusBar()
    dbg("Creating application status bar", "UI")
    return TitleBarWidget:new{
        fullscreen = true,
        title = "00:00:00 – 00:00:00", -- Placeholder, will be updated live
        title_align = "center",
        with_bottom_line = false,
        subtitle = _("White – Black"), -- Placeholder, will be updated live
        left_icon = "appbar.settings", -- Icon for opening settings
        margin = 0,
        padding_h = 0,
        left_icon_tap_callback = function()
            local widget = SettingsWidget:new{
                engine   = self.engine,
                timer    = self.timer,
                game     = self.game,
                parent   = self,
                onApply  = function(_)
                    -- You can restart the engine or refresh UI here, e.g.:
                    if not self.game.is_human(self.game.turn()) then
                        self:launchUCI()
                    end
                    self.timer:reset()
                    self:updatePlayerDisplay()
                    self:updateTimerDisplay()
                    UIManager:setDirty(self, "ui")
                end,
                onCancel = function()
                    -- optional cleanup
                end
            }
            widget:show()
        end,
        right_icon = "check", -- Generic icon, will represent play/pause
        right_icon_tap_callback = function()
            if self.engine and self.engine.state.uciok then
                self:stopUCI() -- Always stop engine's current search when interacting
            end
            if not self.running then
                self:startTimer() -- Start/resume the timer
                -- If it's the engine's turn right after starting, launch UCI
                if self.engine and self.engine.state.uciok and not self.game.is_human(self.game.turn()) then
                    self:launchUCI()
                end
            else
                self.timer:stop() -- Pause the timer
                self.running = false
            end
            self:updateTimerDisplay() -- Update display to reflect play/pause state
        end,
    }
end

--- Kochess:startTimer()
-- Starts or resumes the game timer.
function Kochess:startTimer()
    dbg("Starting or resuming game timer", "TIMER")
    if not self.running then
        self.running = true
        self.timer:start()
        self:updateTimerDisplay() -- Ensure display updates to reflect running state
    end
end

return Kochess
