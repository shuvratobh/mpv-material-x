local Element = require('elements/Element')

---@class SkipNotificationButton : Element
local SkipNotificationButton = class(Element)

function SkipNotificationButton:new() return Class.new(self) --[[@as SkipNotificationButton]] end

function SkipNotificationButton:init()
	Element.init(self, 'skip_notification_button', {render_order = 7})
	self.ignores_curtain = true
	self.message = ""
	self.is_prompt = false
	self.hovered = false
	self.min_visibility = 0
	self.scale = 1
	self:update_dimensions()
end

local function format_label(message)
	local upper = (message ~= "" and message or "Skip Opening"):upper()
	if upper == "SKIP OPENING" then
		return "SKIP INTRO"
	end
	return upper
end

function SkipNotificationButton:update_dimensions()
	if not display.initialized then return end

	local base_height = 1080
	local scale = math.max(0.85, display.height / base_height)
	self.scale = scale

	local margin_right = 34 * scale
	local margin_bottom = 98 * scale
	local label = format_label(self.message)
	local font_size = round(26 * scale)
	local pad_x = 28 * scale

	local measured_w = (type(text_width) == 'function')
		and text_width(label, {size = font_size, font = 'Arial', bold = true})
		or (#label * font_size * 0.62)
	if not measured_w or measured_w <= 0 then
		measured_w = #label * font_size * 0.62
	end

	local button_width = math.max(158 * scale, round(measured_w + pad_x * 2))
	local button_height = round(54 * scale)

	self:set_coordinates(
		round(display.width - button_width - margin_right),
		round(display.height - button_height - margin_bottom),
		round(display.width - margin_right),
		round(display.height - margin_bottom)
	)
end

function SkipNotificationButton:hit_test(x, y)
	if not x or not y or self:get_visibility() <= 0 or self.message == "" then
		return false
	end
	return x >= self.ax and x <= self.bx and y >= self.ay and y <= self.by
end

function SkipNotificationButton:set_hovered(hovered)
	hovered = hovered and true or false
	if self.hovered ~= hovered then
		self.hovered = hovered
		request_render()
	end
end

function SkipNotificationButton:set_message(message, is_prompt)
	self.message = message or ""
	self.is_prompt = is_prompt or false
	self.min_visibility = 1
	self:update_dimensions()
	request_render()
end

function SkipNotificationButton:hide()
	self.message = ""
	self.hovered = false
	self.min_visibility = 0
	request_render()
end

function SkipNotificationButton:on_display()
	self:update_dimensions()
end

function SkipNotificationButton:render()
	local visibility = self:get_visibility()
	if visibility <= 0 or self.message == "" then return end

	local ass = assdraw.ass_new()
	local s = self.scale
	local label = format_label(self.message)

	-- Sharp rectangular dark box with crisp thin grey/white border (Netflix SKIP INTRO style)
	local bg_color = self.hovered and '242424' or '000000'
	local bg_opacity = self.hovered and 0.90 or 0.78
	local border_color = self.hovered and 'FFFFFF' or '8C8C8C'
	local border_opacity = self.hovered and 0.98 or 0.85

	ass:rect(self.ax, self.ay, self.bx, self.by, {
		color = bg_color,
		opacity = {
			primary = visibility * bg_opacity,
			border = visibility * border_opacity,
		},
		border = 1.5 * s,
		border_color = border_color,
		radius = 0,
	})

	local cx = round((self.ax + self.bx) / 2)
	local cy = round((self.ay + self.by) / 2)

	-- Classic heavy Arial Bold (renders true thick weight in libass, unlike variable TTFs)
	ass:txt(cx, cy, 5, '{\\fsp1}' .. label, {
		font = 'Arial',
		size = round(26 * s),
		color = self.hovered and 'FFFFFF' or 'EBEBEB',
		opacity = visibility * 0.98,
		bold = true,
	})

	return ass
end

return SkipNotificationButton
