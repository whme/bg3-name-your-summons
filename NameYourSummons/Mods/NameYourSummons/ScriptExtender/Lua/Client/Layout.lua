-- SPDX-License-Identifier: MIT
--[[
    Viewport-relative sizing. Sizes are authored in pixels against a 4K
    (3840x2160) reference and scaled to the player's actual viewport, so the
    windows keep the same proportions from a 1080p laptop to a 4K monitor
    instead of a fixed pixel size overflowing small screens.
]]

local Layout = {}

local REF_W, REF_H = 3840, 2160

--- The ImGui viewport size, falling back to the 4K reference if unavailable.
---@return number width, number height
function Layout.Viewport()
	local ok, size = pcall(Ext.IMGUI.GetViewportSize)
	if ok and type(size) == "table" and type(size[1]) == "number" and type(size[2]) == "number" then
		return size[1], size[2]
	end
	return REF_W, REF_H
end

--- Scale a reference-pixel width to the current viewport.
---@param px number
---@return number
function Layout.ScaleW(px)
	local vw = Layout.Viewport()
	return px * vw / REF_W
end

--- A {width, height} authored at the 4K reference, scaled to the viewport.
---@param w number
---@param h number
---@return number[]
function Layout.Size(w, h)
	local vw, vh = Layout.Viewport()
	return { w * vw / REF_W, h * vh / REF_H }
end

return Layout
