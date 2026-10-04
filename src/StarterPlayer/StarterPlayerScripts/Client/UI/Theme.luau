--!strict
--[[
	UI.Theme

	Design tokens for the laptop interface.

	== The brief ==

	Clean, dark, neutral, restrained, fashion-oriented, like a modern desktop OS.
	Explicitly NOT a Roblox simulator UI: no rainbow buttons, no gradients for
	decoration, no childish icons, no giant currency counters, no popups.

	What that means concretely here:

	* ONE accent, a warm off-white. Colour is used to separate information, not
	  to decorate. Semantic colours (positive/warning/critical) exist but are
	  desaturated and used sparingly -- a quality bar, never a button.
	* A tight neutral ramp. Depth comes from small, close steps in surface
	  lightness plus a hairline border, the way real dark UIs do it, rather than
	  from drop shadows or glows.
	* A 4px spacing grid. Every gap is a multiple of it, so spacing stays
	  consistent without anyone eyeballing numbers.
	* A real type scale with deliberate weight jumps. Hierarchy comes from
	  size and weight, not from colour.

	The player's chosen style direction contributes ONE accent colour, applied
	only to brand-owned surfaces. The OS chrome itself never changes, because an
	interface that restyles itself per save stops feeling like a tool.
]]

local Theme = {}

-- ============================================================================
-- Colour
-- ============================================================================

--[[
	Neutral ramp, darkest to lightest. The steps are deliberately close: a dark
	interface reads as layered when surfaces differ by a few percent and are
	separated by a hairline, and reads as cheap when they differ by a lot.
]]
Theme.color = {
	-- Surfaces
	void = Color3.fromRGB(8, 8, 9), -- behind everything; the "off" screen
	base = Color3.fromRGB(14, 14, 16), -- app background
	surface = Color3.fromRGB(20, 20, 23), -- panels
	surfaceRaised = Color3.fromRGB(27, 27, 31), -- cards on panels
	surfaceHover = Color3.fromRGB(34, 34, 39),
	surfaceActive = Color3.fromRGB(42, 42, 48),

	-- Lines
	border = Color3.fromRGB(38, 38, 43),
	borderStrong = Color3.fromRGB(56, 56, 63),

	-- Text
	textPrimary = Color3.fromRGB(237, 236, 233),
	textSecondary = Color3.fromRGB(154, 154, 160),
	textTertiary = Color3.fromRGB(104, 104, 112),
	textInverse = Color3.fromRGB(16, 16, 18),

	-- The single accent: warm off-white, not a hue.
	accent = Color3.fromRGB(232, 229, 220),
	accentHover = Color3.fromRGB(245, 243, 237),
	accentMuted = Color3.fromRGB(78, 76, 71),

	-- Semantic, desaturated. For data, never for chrome.
	positive = Color3.fromRGB(126, 168, 128),
	warning = Color3.fromRGB(198, 164, 96),
	critical = Color3.fromRGB(190, 104, 98),
	info = Color3.fromRGB(122, 146, 180),
}

--[[
	Quality scale, used by inspection bars and forecast chips.
	Runs critical -> warning -> neutral -> positive so a bad sample is visibly
	bad at a glance without needing to read the number.
]]
function Theme.qualityColor(score: number): Color3
	if score >= 0.78 then
		return Theme.color.positive
	elseif score >= 0.58 then
		return Color3.fromRGB(168, 172, 138)
	elseif score >= 0.4 then
		return Theme.color.warning
	end
	return Theme.color.critical
end

-- ============================================================================
-- Typography
-- ============================================================================

Theme.FONT_FAMILY = "rbxasset://fonts/families/Montserrat.json"

--[[
	BuilderSans for dense data: prices, measurements, table columns. Its figures
	are more even than Montserrat's, which matters in a column of numbers.

	NOT Inter, despite Inter being the obvious choice for this. Inter,
	SourceSans and Gotham all FAIL TO LOAD at runtime in this engine build
	("Temp read failed") and silently fall back to the default face -- verified
	by measuring TextBounds, where all three produced byte-identical metrics
	while genuinely-loading families each differed. A silent fallback is worse
	than picking a different font deliberately, because the type scale and the
	measured layout widths stop matching what is actually drawn.

	Montserrat and BuilderSans both load correctly and are what the UI uses.
]]
Theme.DATA_FAMILY = "rbxasset://fonts/families/BuilderSans.json"

function Theme.font(weight: Enum.FontWeight?, italic: boolean?): Font
	return Font.new(
		Theme.FONT_FAMILY,
		weight or Enum.FontWeight.Medium,
		if italic then Enum.FontStyle.Italic else Enum.FontStyle.Normal
	)
end

function Theme.dataFont(weight: Enum.FontWeight?): Font
	return Font.new(Theme.DATA_FAMILY, weight or Enum.FontWeight.Medium, Enum.FontStyle.Normal)
end

--[[
	Type scale. Sizes are in pixels at a 1280x720 reference and are scaled by
	Theme.scale() for other resolutions.

	The weight jumps are deliberate: display/title are Bold or heavier, body is
	Medium, and metadata is Medium at a smaller size in a dimmer colour. Three
	clearly different levels beat six subtly different ones.
]]
Theme.type = {
	display = { size = 34, weight = Enum.FontWeight.Bold },
	title = { size = 22, weight = Enum.FontWeight.SemiBold },
	heading = { size = 16, weight = Enum.FontWeight.SemiBold },
	body = { size = 14, weight = Enum.FontWeight.Medium },
	bodyStrong = { size = 14, weight = Enum.FontWeight.SemiBold },
	small = { size = 12, weight = Enum.FontWeight.Medium },
	micro = { size = 11, weight = Enum.FontWeight.SemiBold },
}

-- ============================================================================
-- Spacing and shape
-- ============================================================================

-- 4px grid. Everything spatial is a multiple of this.
Theme.UNIT = 4

Theme.space = {
	xs = 4,
	sm = 8,
	md = 12,
	lg = 16,
	xl = 24,
	xxl = 32,
	xxxl = 48,
}

Theme.radius = {
	sm = 4,
	md = 6,
	lg = 10,
	xl = 14,
	pill = 999,
}

Theme.stroke = {
	hairline = 1,
	standard = 1,
	strong = 2,
}

-- ============================================================================
-- Motion
-- ============================================================================

--[[
	Subtle and quick. Interface motion should confirm that something happened,
	not perform. Everything uses an ease-out quad: fast start, soft settle.
]]
Theme.motion = {
	instant = 0.08,
	fast = 0.14,
	normal = 0.22,
	slow = 0.36,
	deliberate = 0.55,
}

Theme.easing = {
	standard = Enum.EasingStyle.Quad,
	direction = Enum.EasingDirection.Out,
}

function Theme.tweenInfo(duration: number?, style: Enum.EasingStyle?): TweenInfo
	return TweenInfo.new(
		duration or Theme.motion.normal,
		style or Theme.easing.standard,
		Theme.easing.direction
	)
end

-- ============================================================================
-- Layout
-- ============================================================================

-- The laptop window's reference size. Apps lay out against this.
Theme.OS_WIDTH = 1180
Theme.OS_HEIGHT = 700
Theme.SIDEBAR_WIDTH = 212
Theme.TITLEBAR_HEIGHT = 44

--[[
	UI scale factor for the viewport.

	Clamped at 1 so the interface never grows beyond its designed size on a large
	monitor -- scaling a desktop UI up makes it look like a toy. It only ever
	shrinks, to stay usable on small screens.
]]
function Theme.scale(viewportSize: Vector2): number
	local widthScale = viewportSize.X / 1280
	local heightScale = viewportSize.Y / 720
	return math.clamp(math.min(widthScale, heightScale), 0.55, 1)
end

return Theme
