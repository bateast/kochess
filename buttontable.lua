local Blitbuffer = require("ffi/blitbuffer")
local Button = require("button")
local Device = require("device")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local Geom = require("ui/geometry")
local Screen = Device.screen

local ButtonTable = require("ui/widget/buttontable")

function ButtonTable:init()
    self.width = self.width or math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    self.buttons_layout = {}
    self.button_by_id = {}
    self.container = VerticalGroup:new{ width = self.width }
    self[1] = self.container
    if self.zero_sep then
        -- If we're asked to add a first line, don't add a vspan before: caller
        -- must do its own padding before.
        self:addVerticalSeparator()
    end
    local row_cnt = #self.buttons
    local table_min_needed_width = -1
    for i = 1, row_cnt do
        if not self.zero_sep then self:addVerticalSpan() end
        local buttons_layout_line = {}
        local horizontal_group = HorizontalGroup:new{}
        local row = self.buttons[i]
        local column_cnt = #row
        local available_width = self.width - self.sep_width * (column_cnt - 1)
        local unspecified_width_buttons = 0
        for j = 1, column_cnt do
            local btn_entry = row[j]
            if btn_entry.width then
                available_width = available_width - btn_entry.width
            else
                unspecified_width_buttons = unspecified_width_buttons + 1
            end
        end
        local default_button_width = math.floor(available_width / unspecified_width_buttons)
        local min_needed_button_width = -1
        for j = 1, column_cnt do
            local btn_entry = row[j]
            local button = Button:new{
                text = btn_entry.text,
                text_func = btn_entry.text_func,
                checked_func = btn_entry.checked_func,
                lang = btn_entry.lang,
                icon = btn_entry.icon,
                alpha = btn_entry.alpha,
                icon_width = btn_entry.icon_width,
                icon_height = btn_entry.icon_height,
                align = btn_entry.align,
                enabled = btn_entry.enabled,
                enabled_func = btn_entry.enabled_func,
                callback = function()
                    if self.show_parent and self.show_parent.movable then
                        self.show_parent.movable:resetEventState()
                    end
                    btn_entry.callback()
                end,
                hold_callback = btn_entry.hold_callback,
                allow_hold_when_disabled = btn_entry.allow_hold_when_disabled,
                vsync = btn_entry.vsync,
                width = btn_entry.width or default_button_width,
                height = btn_entry.height,
                background = btn_entry.background,
                bordersize = 0,
                margin = 0,
                padding = Size.padding.buttontable, -- a bit taller than standalone buttons, for easier tap
                padding_h = btn_entry.align == "left" and Size.padding.large or Size.padding.button,
                    -- allow text to take more of the horizontal space if centered
                avoid_text_truncation = btn_entry.avoid_text_truncation,
                text_font_face = btn_entry.font_face,
                text_font_size = btn_entry.font_size,
                text_font_bold = btn_entry.font_bold,
                menu_style = btn_entry.menu_style,
                show_parent = self.show_parent,
            }
            if self.shrink_unneeded_width and not btn_entry.width and min_needed_button_width ~= false then
                -- We gather the largest min width of all buttons without a specified width,
                -- and will see how it does when this largest min width is applied to all
                -- buttons (without a specified width): we still want to keep them the same
                -- size and balanced.
                local min_width = button:getMinNeededWidth()
                if min_width then
                    if min_needed_button_width < min_width then
                        min_needed_button_width = min_width
                    end
                else
                    -- If any one button in this row can't be made smaller, give up
                    min_needed_button_width = false
                end
            end
            if btn_entry.id then
                self.button_by_id[btn_entry.id] = button
            end
            local button_dim = button:getSize()
            local vertical_sep = LineWidget:new{
                background = btn_entry.no_vertical_sep and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_GRAY,
                dimen = Geom:new{
                    w = self.sep_width,
                    h = button_dim.h,
                }
            }
            buttons_layout_line[j] = button
            table.insert(horizontal_group, button)
            if j < column_cnt then
                table.insert(horizontal_group, vertical_sep)
            end
        end -- end for each button
        table.insert(self.container, horizontal_group)
        if not self.zero_sep then self:addVerticalSpan() end
        if i < row_cnt then
            self:addVerticalSeparator()
        end
        if column_cnt > 0 then
            -- Only add lines that are not separator to the focusmanager
            table.insert(self.buttons_layout, buttons_layout_line)
        end
        if self.shrink_unneeded_width and table_min_needed_width ~= false then
            if min_needed_button_width then
                if min_needed_button_width >= 0 and min_needed_button_width < default_button_width then
                    local row_min_width = self.width - (default_button_width - min_needed_button_width)*unspecified_width_buttons
                    if table_min_needed_width < row_min_width then
                        table_min_needed_width = row_min_width
                    end
                end
            else
                -- If any one row can't be made smaller, give up
                table_min_needed_width = false
            end
        end
    end -- end for each button line
    if Device:hasDPad() then
        self.layout = self.buttons_layout
        self:refocusWidget()
    else
        self.key_events = {}  -- deregister all key press event listeners
    end
    if self.shrink_unneeded_width and table_min_needed_width ~= false
            and table_min_needed_width > 0 and table_min_needed_width < self.width then
        self.width = table_min_needed_width > self.shrink_min_width and table_min_needed_width or self.shrink_min_width
        self.shrink_unneeded_width = false
        self:free()
        self:init()
    end
end

return ButtonTable
