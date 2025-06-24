# Kochess User Manual

Kochess is a simple yet functional chess application designed for your device. It allows you to play against a built-in UCI chess engine (like Stockfish), load and save games in PGN format, and review past moves.

---

## Getting Started

### Launching Kochess

1.  From the **Main Menu** of your device, navigate to the **Tools** section.
2.  Select **"Chess Game"** to start Kochess.

Upon launching, a new game will begin automatically with the chess engine initialized. You will see the chessboard, PGN log, and status bars.

---

### Installation

To install Kochess, follow these steps:

1.    Plugin Installation: Copy the Kochess plugin directory into your KOReader installation. The plugin should be located at: `koreader/plugins/kochess.koplugin` (Replace koreader with your base KOReader installation directory).

2.    Icons: For chess piece images to display correctly, the icons directory must be copied or moved to: `koreader/resources/icons/chess`

3.    Games: Your saved game files (PGN) can be stored in any convenient location on your device.

4.    Engine: Chess engine (`UCI` interface compatible) must be copied or moved as `koreader/resources/bin/stockfish`. This step is optional. Without a working installed chess engine, Kochess would still allow to play as human and load / save games for analysis.

---

## Interface Overview

The Kochess interface is designed for clarity and ease of use. It consists of the following main areas:

* **Title Bar (Top):** Displays the application title and general information or quick action buttons (like a menu button).
* **Chess Board (Middle):** This is where the chess pieces are displayed, and you interact with the game by tapping on squares to make moves.
* **PGN Log & Toolbar (Below Board):**
    * **PGN Log:** Shows the move history in Standard Algebraic Notation (SAN), along with game information and engine status.
    * **Toolbar:** Contains buttons for navigating through moves and managing game files.
* **Status Bar (Bottom):** Displays current game information, including player timers and who is currently playing (Human or Engine).

---

## Playing a Game

### Making a Move (Human Player)

Kochess supports touch-based move input:

1.  **Select a piece:** Tap on the piece you wish to move.
2.  **Select a destination:** Tap on the square where you want to move the piece.
3.  The move will be executed, the PGN log will update, and the turn will switch to the next player.

### Pawn Promotion

When a pawn reaches the last rank, a **promotion dialog** will appear, prompting you to choose the piece you wish to promote to (Queen, Rook, Bishop, or Knight). Select your desired piece to complete the move.

### Engine's Turn

When it's the engine's turn, the application will automatically calculate and make its move. You can force the engine to play by hitting the `checkmark` button in the **Status Bar**.

### Game State

The **Status Bar** will show the current player's turn and remaining time:
* **⤆**: White's turn
* **⤇**: Black's turn
* **⤊**: Game is paused or in an initial/reset state.

---

## Game Controls & Features

### Timers

Kochess includes a game timer for both White and Black.
* The timers start counting down for the active player once the game begins (after the first human move or explicit request hitting the `checkmark` button).
* The current time for both players is displayed in the **Status Bar**.

### PGN Log

The **PGN Log** displays the game's moves.
* **Move History:** Shows the sequence of moves in Standard Algebraic Notation.
* **Headers:** Displays game information like Event, Date, White player, and Black player, if available from a loaded PGN.
* **Comments:** If there are comments associated with a move in the PGN, they will be shown.
* **Scrolling:** The log automatically scrolls to the most recent move.

### Toolbar Buttons

The toolbar, located next to the PGN log, provides several useful functions:

* **Undo Move (`chevron.left` icon):**
    * **Tap:** Undoes the last single move.
    * **Hold:** Undoes all moves, rewinding the game to the initial position.
* **Redo Move (`chevron.right` icon):**
    * **Tap:** Redoes the next available move in the history.
    * **Hold:** Redoes all available moves, replaying the game to the current end of the move history.
* **Save PGN (`bookmark` icon):** Opens a dialog to save the current game state as a PGN (Portable Game Notation) file.
    * You can choose the **folder** to save in.
    * You can enter a **filename**. The `.pgn` extension will be added automatically if not provided.
* **Load PGN (`appbar.filebrowser` icon):** Opens a file browser to load a PGN chess game from your device.
    * Select a `.pgn` file to load. The current game will be reset, and the loaded game will be displayed from its initial position.

---

## Settings

While the code snippet doesn't detail a full settings menu, it references a `SettingsWidget`. It's likely that future versions or a more complete implementation will include options to configure:

* **Player type:** Choosing color to be a human or engine player (if available)
* **Engine Difficulty:** Adjusting the strength of the UCI engine (e.g., Stockfish).
* **Time Controls:** Modifying the initial time and increment for players.

---

## License and Acknowledgement

All sources and creation are copyrighted by Baptiste Fouques and provided under the GPL license 3.0 or above.

The Chess game logic module is provided by arizati (https://github.com/arizati/chess.lua).

Icons are derived work from [Colin M.L. Burnett](https://en.wikipedia.org/wiki/User:Cburnett), provided under [GPLv2+](https://www.gnu.org/licenses/gpl-2.0.txt).

---

We hope you enjoy playing chess with Kochess! If you encounter any further issues or have suggestions, please open an issue so we can work on it.
