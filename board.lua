-- board.lua
local _ = require("gettext")
local logger = require("logger")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("buttontable")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Chess = require("chess/src/chess")
local Device = require("device")
local Screen = Device.screen

local BOARD_SIZE = 8
local SELECTED_BORDER = 5

local icons = {
    empty = "chess/empty",
    [Chess.PAWN]   = { [Chess.WHITE] = "chess/wP", [Chess.BLACK] = "chess/bP" },
    [Chess.KNIGHT] = { [Chess.WHITE] = "chess/wN", [Chess.BLACK] = "chess/bN" },
    [Chess.BISHOP] = { [Chess.WHITE] = "chess/wB", [Chess.BLACK] = "chess/bB" },
    [Chess.ROOK]   = { [Chess.WHITE] = "chess/wR", [Chess.BLACK] = "chess/bR" },
    [Chess.QUEEN]  = { [Chess.WHITE] = "chess/wQ", [Chess.BLACK] = "chess/bQ" },
    [Chess.KING]   = { [Chess.WHITE] = "chess/wK", [Chess.BLACK] = "chess/bK" },
}

local Board = FrameContainer:extend{
    game = nil,
    width = 250,
    height = 250,
    moveCallback = nil,
    holdCallback = nil,
    onPromotionNeeded = nil, -- NEW: Callback for when a pawn promotion is detected
    padding = 0,
    background = Blitbuffer.COLOR_WHITE,
}

function Board:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Board:init()
    if not self.game then
        logger.error("Chess: must be initialized with a Game object")
        return
    end

    local margins = self:allMarginSizes()
    self.button_size = math.min(
        math.floor(self.width / (BOARD_SIZE + 1)) - margins.w,
        math.floor(self.height / (BOARD_SIZE + 1)) - margins.h
    )

    self.selected = nil
    logger.dbg(string.format("Initializing board: %dx%d, button size: %d", self.width, self.height, self.button_size))

    local grid = {}
    for rank = BOARD_SIZE - 1, 0, -1 do -- Iterate from rank 7 down to 0 (corresponds to board ranks 8 to 1)
        local row = {}
        for file = 0, BOARD_SIZE - 1 do -- Iterate from file 0 to 7 (corresponds to 'a' to 'h')
            table.insert(row, self:createSquareButton(file, rank))
        end
        table.insert(grid, row)
    end

    self.table = ButtonTable:new{
        buttons = grid,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end, -- No vertical spacing between rows
    }

    self:applySquareColors()
    self[1] = CenterContainer:new{ dimen = self:getSize(), self.table }

    logger.dbg("Chess board initialized")
end

function Board:createSquareButton(file, rank)
    return {
        id = Board.toId(file, rank),
        icon = icons.empty,
        alpha = true,
        width = self.button_size,
        height = self.button_size,
        icon_width = self.button_size,
        icon_height = self.button_size,
        bordersize = 0,
        margin = 0,
        padding = 0,
        allow_hold_when_disabled = true,
        callback = function() self:handleClick(file, rank) end,
        hold_callback = self.holdCallback,
    }
end

function Board:applySquareColors()
    for rank = 0, BOARD_SIZE - 1 do
        for file = 0, BOARD_SIZE - 1 do
            local button = self.table:getButtonById(Board.toId(file, rank))
            button.frame.background = ((file + rank) % 2 == 1)
                and Blitbuffer.COLOR_LIGHT_GRAY
                or Blitbuffer.COLOR_DARK_GRAY
        end
    end
end

--- Board:handleClick(file, rank)
-- Handles a tap event on a chess board square.
-- Manages piece selection and initiates move attempts.
-- @param file Number, the 0-indexed file of the tapped square.
-- @param rank Number, the 0-indexed rank of the tapped square.
function Board:handleClick(file, rank)
    local id = Board.toId(file, rank)
    local square = Board.idToPosition(id) -- Chess algebraic notation (e.g., "e4")
    logger.dbg("Chess click on square: " .. square)

    if self.selected then
        -- A piece is already selected, this click is a move attempt
        if self.selected == square then
            -- Clicked the same square again, unselect it
            self:unmarkSelected(square)
            self.selected = nil
        else
            -- Attempt to move the selected piece to the new square
            self:handleMove(self.selected, square)
        end
    else
        -- No piece is selected, try to select one
        local piece = self.game.get(square)
        -- Only allow selection if there's a piece and it's the current player's turn
        if piece and piece.color == self.game.turn() then
            logger.dbg("Chess select piece " .. piece.type .. " at " .. square)
            self.selected = square
            self:markSelected(square)
        end
    end
end

--- Board:handleMove(from, to)
-- Attempts to make a move from 'from' square to 'to' square.
-- Includes logic for pawn promotion.
-- @param from String, algebraic notation of the starting square.
-- @param to String, algebraic notation of the destination square.
function Board:handleMove(from, to)
    self:unmarkSelected(from) -- Always unmark the selected piece after a move attempt
    self.selected = nil        -- Clear selection

    local piece = self.game.get(from) -- Get the piece that is moving

    -- Check for pawn promotion:
    -- 1. Is the piece a pawn?
    -- 2. Is the destination rank a promotion rank for its color?
    local is_pawn_promotion = false
    if piece and piece.type == Chess.PAWN then
        local to_rank_num = tonumber(to:sub(2, 2)) -- Extract rank number from 'to' square (e.g., '8' from "e8")
        if (piece.color == Chess.WHITE and to_rank_num == 8) or
           (piece.color == Chess.BLACK and to_rank_num == 1) then
            is_pawn_promotion = true
        end
    end

    if is_pawn_promotion and self.onPromotionNeeded then
        -- If it's a promotion and we have a callback, defer the move to Kochess.lua.
        -- Kochess.lua will then prompt for the promotion piece and call game.move().
        logger.dbg(string.format("Pawn promotion detected: %s pawn from %s to %s. Triggering promotion dialog.", piece.color, from, to))
        self.onPromotionNeeded(from, to, piece.color)
        -- IMPORTANT: Do NOT call self.game.move() here. Kochess will handle it after selection.
    else
        -- If not a promotion, or no promotion callback provided, proceed with a normal move.
        local move = self.game.move{ from = from, to = to }
        if move then
            self:handleGameMove(move)
        else
            -- Move was illegal (e.g., wrong piece, blocked, etc.)
            logger.dbg(string.format("Illegal move attempted from %s to %s.", from, to), "ERROR")
            -- Re-render the board to revert any temporary visual changes for the illegal move
            self:updateBoard()
        end
    end
end

--- Board:handleGameMove(move)
-- Processes a successfully executed chess move (from game logic).
-- Updates the board visually and triggers the main move callback in Kochess.
-- @param move Table, the move object returned by ChessGame.move().
function Board:handleGameMove(move)
    if not move then return end -- Should not happen if called with a valid move

    logger.dbg("Applying game move to board visuals: " .. move.san)
    self:updateSquare(move.from) -- Update source square (now empty)
    self:updateSquare(move.to)   -- Update destination square (new piece)

    -- Handle special move flags like en passant or castling which affect other squares
    self:handleMoveFlags(move, move.to)

    if self.moveCallback then
        self.moveCallback(move) -- Notify Kochess.lua that the move has completed
    end
end

--- Board:handleMoveFlags(move, to)
-- Handles visual updates for special move types (en passant, castling).
-- @param move Table, the move object.
-- @param to String, the destination square of the main piece.
function Board:handleMoveFlags(move, to)
    if not move.flags then return end

    local to_id_result = Board.chessToId(to)
    if not to_id_result then
        logger.info(_("Chess: Invalid destination square for move flags: " .. tostring(to)))
        return
    end
    local to_id = to_id_result

    if move.flags == Chess.FLAGS.EP_CAPTURE then
        -- En passant: the captured pawn is on the rank of the 'from' square, but the file of the 'to' square.
        -- We need to clear the square of the captured pawn.
        local captured_pawn_rank_offset = (move.color == Chess.BLACK and 1 or -1)
        local captured_pawn_id = to_id + captured_pawn_rank_offset * BOARD_SIZE -- Adjust ID by rank offset, maintaining file
        local captured_pawn_square_result = Board.idToPosition(captured_pawn_id)
        if captured_pawn_square_result then
            self:updateSquare(captured_pawn_square_result)
        end
    elseif move.flags == Chess.FLAGS.KSIDE_CASTLE then
        -- Kingside castling: King moves two squares, Rook moves to inner square
        -- Rook original square: h1 for White, h8 for Black
        -- Rook destination square: f1 for White, f8 for Black
        local rook_from_file_id = 7 -- 0-indexed 'h'
        local rook_to_file_id = 5 -- 0-indexed 'f'
        local rank_index = (move.color == Chess.WHITE and 0 or 7) -- 0-indexed rank 1 or 8
        self:updateSquare(Board.idToPosition(Board.toId(rook_from_file_id, rank_index)))
        self:updateSquare(Board.idToPosition(Board.toId(rook_to_file_id, rank_index)))
    elseif move.flags == Chess.FLAGS.QSIDE_CASTLE then
        -- Queenside castling: King moves two squares, Rook moves to inner square
        -- Rook original square: a1 for White, a8 for Black
        -- Rook destination square: d1 for White, d8 for Black
        local rook_from_file_id = 0 -- 0-indexed 'a'
        local rook_to_file_id = 3 -- 0-indexed 'd'
        local rank_index = (move.color == Chess.WHITE and 0 or 7) -- 0-indexed rank 1 or 8
        self:updateSquare(Board.idToPosition(Board.toId(rook_from_file_id, rank_index)))
        self:updateSquare(Board.idToPosition(Board.toId(rook_to_file_id, rank_index)))
    end
end

--- Board:markSelected(square)
-- Visually marks a square as selected by adding a border.
-- @param square String, algebraic notation of the square to mark.
function Board:markSelected(square)
    local id_result = Board.chessToId(square)
    if not id_result then
        logger.info(_("Chess: Invalid square to select: " .. tostring(square)))
        return
    end
    local button = self.table:getButtonById(id_result)
    button.frame.bordersize = Screen:scaleBySize(SELECTED_BORDER)
    button:refresh()
end

--- Board:unmarkSelected(square)
-- Visually unmarks a square by removing its border.
-- @param square String, algebraic notation of the square to unmark.
function Board:unmarkSelected(square)
    local id_result = Board.chessToId(square)
    if not id_result then
        logger.info(_("Chess: Invalid square to unselect: " .. tostring(square)))
        return
    end
    local button = self.table:getButtonById(id_result)
    button.frame.bordersize = 0
    button:refresh()
end

--- Board:placePiece(square, piece, color)
-- Places or removes a piece icon on a specific board square.
-- @param square String, algebraic notation of the square.
-- @param piece String, the piece type (e.g., Chess.PAWN, Chess.QUEEN) or nil to clear.
-- @param color String, the piece color (Chess.WHITE or Chess.BLACK), only required if `piece` is not nil.
function Board:placePiece(square, piece, color)
    local icon = (piece and icons[piece] and icons[piece][color]) or icons.empty
    local id_result = Board.chessToId(square)
    if not id_result then
        logger.info(_("Error placing " .. tostring(piece) .. " on non-chess position: " .. square))
        return
    end
    local button = self.table:getButtonById(id_result)
    button:setIcon(icon, self.button_size)
    button.frame.background = Board.positionToColor(square) -- Re-apply background color in case it was changed
    button:refresh()
end

--- Board:updateSquare(square)
-- Refreshes the display of a single square based on the current game state.
-- @param square String, algebraic notation of the square to update.
function Board:updateSquare(square)
    local piece = self.game.get(square)
    if piece then
        self:placePiece(square, piece.type, piece.color)
    else
        self:placePiece(square) -- Clear the square
    end
end

--- Board:updateBoard()
-- Refreshes the entire chess board display based on the current game state.
function Board:updateBoard()
    logger.dbg("Chess: Update entire board")
    local board_fen = self.game.board() -- Get the current board state from the game logic
    for file_idx = 0, BOARD_SIZE - 1 do
        for rank_idx = 0, BOARD_SIZE - 1 do
            -- Chess.js-like board structure: board[rank][file]
            -- Ranks are 1-8, files are a-h. Lua arrays are 1-indexed.
            -- So, board[BOARD_SIZE - rank_idx] corresponds to board ranks 8 down to 1.
            -- board[file_idx + 1] corresponds to files 'a' through 'h'.
            local element = board_fen[BOARD_SIZE - rank_idx][file_idx + 1]
            local square = Board.idToPosition(Board.toId(file_idx, rank_idx))
            if element then
                self:placePiece(square, element.type, element.color)
            else
                self:placePiece(square) -- Clear the square if no piece
            end
        end
    end
end

-- Utility functions for square conversions
--- Board.toId(file, rank)
-- Converts 0-indexed file and rank to a unique linear ID.
-- @param file Number, 0-indexed file (0-7 for 'a'-'h').
-- @param rank Number, 0-indexed rank (0-7 for '1'-'8').
-- @return Number, unique ID.
function Board.toId(file, rank)
    return file * BOARD_SIZE + rank
end

--- Board.chessToId(position)
-- Converts chess algebraic notation (e.g., "e4") to a linear ID.
-- @param position String, algebraic notation.
-- @return id or nil
function Board.chessToId(position)
    if type(position) == "string" and #position == 2 then
        local file_char = position:sub(1, 1)
        local rank_char = position:sub(2, 2)
        if 'a' <= file_char and file_char <= 'h' and '1' <= rank_char and rank_char <= '8' then
            local file_idx = string.byte(file_char) - string.byte('a')
            local rank_idx = tonumber(rank_char) - 1
            return Board.toId(file_idx, rank_idx)
        end
    end
    return nil
end

--- Board.idToPosition(id)
-- Converts a linear ID back to chess algebraic notation.
-- @param id Number, the linear ID.
-- @return position or nil
function Board.idToPosition(id)
    if type(id) == "number" and id >= 0 and id < BOARD_SIZE * BOARD_SIZE then
        local file_idx = math.floor(id / BOARD_SIZE)
        local rank_idx = id % BOARD_SIZE
        local file_char = string.char(file_idx + string.byte('a'))
        local rank_char = tostring(rank_idx + 1) -- Convert 0-indexed rank to 1-indexed chess rank
        return file_char .. rank_char
    end
    return nil
end

--- Board.positionToColor(position)
-- Determines the background color of a square based on its algebraic position.
-- @param position String, algebraic notation (e.g., "e4").
-- @return Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_DARK_GRAY.
function Board.positionToColor(position)
    if type(position) == "string" and #position == 2 then
        local file_char = position:sub(1, 1)
        local rank_char = position:sub(2, 2)
        if 'a' <= file_char and file_char <= 'h' and '1' <= rank_char and rank_char <= '8' then
            local file_idx = string.byte(file_char) - string.byte('a')
            local rank_idx = tonumber(rank_char) - 1
            return (file_idx + rank_idx) % 2 == 1 and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_DARK_GRAY
        end
    end
    return nil -- Or a default color, depending on desired behavior for invalid input
end

function Board:allMarginSizes()
    self._padding_top = self.padding_top or self.padding
    self._padding_right = self.padding_right or self.padding
    self._padding_bottom = self.padding_bottom or self.padding
    self._padding_left = self.padding_left or self.padding
    return Geom:new{
        w = (self.margin + self.bordersize) * 2 + self._padding_right + self._padding_left,
        h = (self.margin + self.bordersize) * 2 + self._padding_top + self._padding_bottom,
    }
end

return Board
