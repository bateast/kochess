-- SettingsWidget.lua
-- Autonomous API widget for chess settings.
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geometry = require("ui/geometry")
local Size = require("ui/size")

local CenterContainer = require("ui/widget/container/centercontainer")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local InputDialog = require("ui/widget/inputdialog")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ButtonWidget    = require("ui/widget/button")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")

local Chess = require("chess")
local _ = require("gettext") -- Localization function

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE

local SettingsWidget = {}
SettingsWidget.__index = SettingsWidget

-- ============================================================================
--  Constructor
-- ============================================================================
-- options:
--   engine            = your UCI engine instance
--   timer             = your timer object
--   game              = your game logic (for .is_human, .set_human, .turn, etc.)
--   onApply(settings) = callback when user clicks Apply
--   onCancel()        = callback when user clicks Cancel (optional)
function SettingsWidget:new(opts)
    assert(opts.engine, "engine is required")
    assert(opts.timer,  "timer is required")
    assert(opts.game,   "game is required")
    assert(opts.onApply and type(opts.onApply) == "function",
           "onApply callback is required")
    assert(opts.parent,   "parent is required")

    self = setmetatable({
        engine     = opts.engine,
        timer      = opts.timer,
        game       = opts.game,
        onApply    = opts.onApply,
        onCancel   = opts.onCancel,
        parent     = opts.parent,
        dialog     = nil,
        changes    = {},
    }, SettingsWidget)

    self:initializeState()
    return self
end

-- ============================================================================
--  Initialize the local `changes` table from current engine/timer/game state
-- ============================================================================
function SettingsWidget:initializeState()
    -- ELO bounds
    local uciEloOpt = self.engine.state.options["UCI_Elo"]
    self.min_elo      = uciEloOpt and uciEloOpt.min or 800
    self.max_elo      = uciEloOpt and uciEloOpt.max or 2500
    self.elo_step     = 50

    -- Time bounds
    self.min_base_min = 1
    self.max_base_min = 180
    self.min_incr_sec = 0
    self.max_incr_sec = 60

    -- Current changes snapshot
    self.changes = {
        human_choice = {
            [Chess.WHITE] = self.game.is_human(Chess.WHITE),
            [Chess.BLACK] = self.game.is_human(Chess.BLACK),
        },
        elo_strength = (uciEloOpt and uciEloOpt.value) or 1500,
        time_control = {
            [Chess.WHITE] = {
                base_minutes  = self.timer.base[Chess.WHITE] / 60,
                incr_seconds  = self.timer.increment[Chess.WHITE],
            },
            [Chess.BLACK] = {
                base_minutes  = self.timer.base[Chess.BLACK] / 60,
                incr_seconds  = self.timer.increment[Chess.BLACK],
            },
        },
    }
end

-- ============================================================================
--  Public show() method: builds and displays the dialog
-- ============================================================================
function SettingsWidget:show()
    local dlg = InputDialog:new{
        title          = _("Chess Settings"),
        save_callback  = function() self:applyAndClose() end,
        dismiss_callback = function()
            if self.onCancel then self.onCancel() end
        end,
    }
    dlg.element_width = math.floor(dlg.width * 0.8)
    self.dialog = dlg

    -- Build the UI groups
    self:buildPlayerTypeGroup()
    self:buildEloGroup()

    self:buildTimeGroups()
    self:assembleContent()

    dlg:refocusWidget()
    UIManager:show(dlg)
end

-- ============================================================================
--  Helper: enable the Apply button when something changes
-- ============================================================================
function SettingsWidget:markDirty()
    self.dialog:_buttons_edit_callback(true)
    UIManager:setDirty(self.parent, "ui")
end

-- ============================================================================
--  PLAYER TYPE RADIO GROUP
-- ============================================================================
function SettingsWidget:buildPlayerTypeGroup()
    local makeList = function(color)
        return {{
            { text = _("Human"), checked = self.changes.human_choice[color], color = color }
        }, {
            { text = _("Robot"), checked = not self.changes.human_choice[color], color = color }
        }}
    end

    local function onSelect(entry)
        self.changes.human_choice[entry.color] = (entry.text == _("Human"))
        self:markDirty()
    end

    -- White
    local wtxt = TextWidget:new{ text = _("White")..":", face = Font:getFace("cfont",22) }
    local whiteRadios = RadioButtonTable:new{
        width  = math.floor(self.dialog.element_width/2 - wtxt:getSize().w),
        radio_buttons = makeList(Chess.WHITE),
        button_select_callback = onSelect,
        parent = self.dialog
    }
    self.playerTypeGroupWhite = HorizontalGroup:new{ wtxt, whiteRadios }

    -- Black
    local btxt = TextWidget:new{ text = _("Black")..":", face = Font:getFace("cfont",22) }
    local blackRadios = RadioButtonTable:new{
        width  = math.floor(self.dialog.element_width/2 - btxt:getSize().w),
        radio_buttons = makeList(Chess.BLACK),
        button_select_callback = onSelect,
        parent = self.dialog
    }
    self.playerTypeGroupBlack = HorizontalGroup:new{ btxt, blackRadios }

    self.playerSettingsGroup = HorizontalGroup:new{
        width = self.dialog.element_width,
        TextWidget:new{ text=_("Player Type")..":", face=Font:getFace("cfont",22) },
        VerticalGroup:new{ spacing=Size.padding.small,
                           self.playerTypeGroupWhite,
                           self.playerTypeGroupBlack }
    }
end

-- ============================================================================
--  ELO GROUP
-- ============================================================================
function SettingsWidget:buildEloGroup()
    -- value display
    local tv = TextWidget:new{
        text   = tostring(self.changes.elo_strength),
        face   = Font:getFace("cfont",22),
        halign = "center",
        width  = 80
    }
    self.eloValueText = tv

    local function updateDisplay()
        tv:setText(tostring(math.floor(self.changes.elo_strength)))
        UIManager:setDirty(self, "ui")
    end

    local function onClick(delta)
        self.changes.elo_strength = math.max(
            self.min_elo,
            math.min(self.max_elo, self.changes.elo_strength + delta)
        )
        updateDisplay()
        self:markDirty()
    end

    local decBtn = ButtonWidget:new{
        text     = "- "..tostring(self.elo_step),
        callback = function() onClick(-self.elo_step) end,
        face     = Font:getFace("cfont",20),
        padding  = Size.padding.small,
        radius   = Size.radius.button,
        parent   = self.dialog,
    }
    local incBtn = ButtonWidget:new{
        text     = "+ "..tostring(self.elo_step),
        callback = function() onClick(self.elo_step) end,
        face     = Font:getFace("cfont",20),
        padding  = Size.padding.small,
        radius   = Size.radius.button,
        parent   = self.dialog,
    }

    local ctrl = HorizontalGroup:new{ spacing=Size.padding.small, decBtn, tv, incBtn }
    self.eloSettingsGroup = HorizontalGroup:new{
        width = self.dialog.element_width,
        TextWidget:new{ text=_("Engine ELO Strength")..":", face=Font:getFace("cfont",22) },
        ctrl
    }
end

-- ============================================================================
--  TIME GROUPS: one button per color that opens a sub-dialog
-- ============================================================================
function SettingsWidget:buildTimeGroups()
    local function fmt(b,i) return string.format("%d + %d",b,i) end

    local function openSubDialog(color, btn)
        local cur = self.changes.time_control[color]
        local inputFmt = fmt(cur.base_minutes, cur.incr_seconds)

        local timeDlg
        timeDlg = InputDialog:new{
            title           = _(color.." Time Settings"),
            description     = _("Time (min + sec):"),
            allow_newline   = false,
            input           = inputFmt,
            input_type      = "number",
            save_callback   = function(txt)
                local nb, ni = txt:match("^(%d+)%s*+%s*(%d+)$")
                if not nb or not ni then
                    UIManager:showMessage(
                      _("Invalid Time Format"),
                      _("Enter 'minutes + seconds' (e.g. '5 + 0').")
                    )
                    return
                end
                nb = math.max(self.min_base_min, math.min(self.max_base_min, tonumber(nb)))
                ni = math.max(self.min_incr_sec, math.min(self.max_incr_sec, tonumber(ni)))
                if cur.base_minutes ~= nb or cur.incr_seconds ~= ni then
                    cur.base_minutes  = nb
                    cur.incr_seconds  = ni
                    btn:setText(fmt(nb,ni))
                    self:markDirty()
                end
                timeDlg:onCloseKeyboard()
                UIManager:close(timeDlg)
            end,
            dismiss_callback = function() end,
        }
        timeDlg:refocusWidget()
        UIManager:show(timeDlg)
    end

    local wbtn
    local wtxt = TextWidget:new{ text=_("White Time: "), face=Font:getFace("cfont",22) }
    wbtn = ButtonWidget:new{
        text     = fmt(self.changes.time_control[Chess.WHITE].base_minutes,
                       self.changes.time_control[Chess.WHITE].incr_seconds),
        callback = function() openSubDialog(Chess.WHITE, wbtn) end,
        face     = Font:getFace("cfont",20),
        padding  = Size.padding.small,
        radius   = Size.radius.button,
        parent   = self.dialog,
        width    = self.dialog.element_width/2 - wtxt:getSize().w - Size.padding.small*2,
    }
    self.whiteTimeGroup = HorizontalGroup:new{ wtxt, wbtn }

    local bbtn
    local btxt = TextWidget:new{ text=_("Black Time: "), face=Font:getFace("cfont",22) }
    bbtn = ButtonWidget:new{
        text     = fmt(self.changes.time_control[Chess.BLACK].base_minutes,
                       self.changes.time_control[Chess.BLACK].incr_seconds),
        callback = function() openSubDialog(Chess.BLACK, bbtn) end,
        face     = Font:getFace("cfont",20),
        padding  = Size.padding.small,
        radius   = Size.radius.button,
        parent   = self.dialog,
        width    = self.dialog.element_width/2 - btxt:getSize().w - Size.padding.small*2,
    }
    self.blackTimeGroup = HorizontalGroup:new{ btxt, bbtn }

    self.timeSettingsGroup = VerticalGroup:new{
        width   = self.dialog.element_width,
        spacing = Size.padding.large,
        self.whiteTimeGroup,
        self.blackTimeGroup,
    }
end

-- ============================================================================
--  Assemble the final dialog content and show
-- ============================================================================
function SettingsWidget:assembleContent()
    local D = self.dialog
    local empty = VerticalSpan:new{ width = 0 }
    local content = FrameContainer:new{
        radius     = Size.radius.window,
        bordersize = Size.border.window,
        background = BACKGROUND_COLOR,
        padding    = 0,
        margin     = 0,

        VerticalGroup:new{
            align = "left",
            D.title_bar,

            VerticalSpan:new{ width = Size.padding.large },

            -- Player type only if engine is ready
            self.engine.state.uciok and CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.playerSettingsGroup:getSize().h },
                self.playerSettingsGroup
            } or VerticalSpan:new{ width = 0 },

            self.engine.state.uciok and VerticalSpan:new{ width = Size.padding.large } or empty,

            -- ELO only if engine is ready
            self.engine.state.uciok and CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.eloSettingsGroup:getSize().h },
                self.eloSettingsGroup
            } or VerticalSpan:new{ width = 0 },

            self.engine.state.uciok and VerticalSpan:new{ width = Size.padding.large } or empty,

            -- Time controls
            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.timeSettingsGroup:getSize().h },
                self.timeSettingsGroup
            },
            VerticalSpan:new{ width = Size.padding.large },

            -- Buttons
            CenterContainer:new{
                dimen = Geometry:new{
                    w = D.title_bar:getSize().w,
                    h = D.button_table:getSize().h,
                },
                D.button_table
            },
        }
    }

    D.movable = MovableContainer:new{ content }
    D[1]      = CenterContainer:new{ dimen = Screen:getSize(), D.movable }
end

-- ============================================================================
--  APPLY: gather `self.changes`, perform any engine/timer updates, then callback
-- ============================================================================
function SettingsWidget:applyAndClose()
    local s = self.changes

    -- 1) ELO
    local opt = self.engine.state.options["UCI_Elo"]
    if opt and tonumber(opt.value) ~= s.elo_strength then
        self.engine:setOption("UCI_Elo", tostring(s.elo_strength))
    end

    -- 2) Time controls
    local function applyTime(color)
        local baseOld = self.timer.base[color] / 60
        local incrOld = self.timer.increment[color]
        local c = s.time_control[color]
        if baseOld ~= c.base_minutes then
            self.timer.base[color] = c.base_minutes * 60
        end
        if incrOld ~= c.incr_seconds then
            self.timer.increment[color] = c.incr_seconds
        end
    end
    applyTime(Chess.WHITE)
    applyTime(Chess.BLACK)

    -- 3) Player types
    for _, color in ipairs({Chess.WHITE, Chess.BLACK}) do
        if self.game.is_human(color) ~= s.human_choice[color] then
            self.game.set_human(color, s.human_choice[color])
        end
    end

    -- invoke user callback
    self.onApply(s)

    -- close the dialog
    UIManager:close(self.dialog)
end

return SettingsWidget
