--!strict
--[[
	Shared.Garment.GraphicRenderer

	Renders a GraphicSpec into a UI container.

	== One renderer, three destinations ==

	The same function draws into:

	  1. the Design app canvas (a Frame)
	  2. the physical garment in the world (a SurfaceGui on the model)
	  3. the inspection viewport (a SurfaceGui, seen up close)

	That is the point. If these were separate code paths the sample that arrives
	could differ from what the player designed, and the core promise of the game
	-- that the thing you made is the thing you received -- would be a lie
	maintained by hand. One renderer makes it structurally true.

	== Resolution independence ==

	Everything is sized in SCALE (0..1 of the container), never in pixels, so the
	same spec renders correctly in a 180px canvas preview and on a 1024px
	SurfaceGui. Text uses TextScaled with a size constraint rather than a fixed
	TextSize for the same reason.

	== Print method is presentation, never logic ==

	`renderStyle` from Config.PrintMethods changes how the ink LOOKS (raised,
	stitched, flat). Print QUALITY -- whether it looks well or badly executed --
	is a separate concern applied via `context.quality`, which the inspection
	view passes in and the design canvas does not. A design preview always shows
	the intended result; only a manufactured sample shows the degraded one.
]]

local Shared = script.Parent.Parent
local Graphics = require(Shared.Config.Graphics)
local PrintMethods = require(Shared.Config.PrintMethods)

local GraphicRenderer = {}

local FONT_FAMILY = "rbxasset://fonts/families/Montserrat.json"
-- BuilderSans, not Inter: Inter fails to load at runtime in this engine build
-- and silently falls back. See the note in UI.Theme.
local MONO_FAMILY = "rbxasset://fonts/families/BuilderSans.json"

local function font(weight: Enum.FontWeight, italic: boolean?): Font
	return Font.new(FONT_FAMILY, weight, if italic then Enum.FontStyle.Italic else Enum.FontStyle.Normal)
end

export type RenderContext = {
	-- Resolves `text == nil` on the spec. The brand name is injected at render
	-- time rather than baked into the spec, so renaming a brand updates every
	-- garment that already exists.
	brandName: string,
	garmentColor: Color3,
	garmentIsDark: boolean,

	--[[
		Optional per-dimension execution quality, 0..1. Supplied only when
		rendering a MANUFACTURED garment. When present, the ink is degraded to
		match: a 0.3 print reads as misregistered, patchy and soft, which is how
		the player sees a bad factory rather than just reading a number.
	]]
	quality: number?,

	-- Deterministic jitter source so a given sample always has the SAME flaws.
	-- Without this, re-opening an inspection view would reshuffle the defects.
	seed: number?,
}

-- ============================================================================
-- Helpers
-- ============================================================================

local function newFrame(parent: Instance, name: string): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = parent
	return frame
end

--[[
	Two engine behaviours drive how text is handled in this file. Both were
	verified directly rather than assumed, and both are easy to reintroduce:

	1. Setting `TextWrapped = false` AFTER `TextScaled = true` silently turns
	   TextScaled back OFF, leaving the label at its default TextSize of 8.
	   Setting them in the other order does not help -- TextScaled always forces
	   TextWrapped on. So TextWrapped is never touched here.

	2. `TextSize`, `UITextSizeConstraint.MaxTextSize` and the size TextScaled
	   resolves to are ALL hard-capped at 100 pixels, regardless of how large
	   the containing box is. CANVAS_RESOLUTION in GarmentBuilder is chosen so
	   that 100 canvas pixels is a large fraction of the garment; otherwise
	   every print would render tiny no matter what scale the player chose.

	Because wrapping cannot be disabled, the only way to keep a mark on one line
	is to give it a box SHORT enough that width is the binding constraint. That
	is what `singleLineHeight` computes.
]]
local function newLabel(parent: Instance, name: string, text: string, weight: Enum.FontWeight): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Text = text
	label.FontFace = font(weight)
	label.TextScaled = true
	label.RichText = false -- player text is never interpreted as markup
	label.Parent = parent
	return label
end

-- MaxTextSize is capped at 100 by the engine; values above it are clamped.
local function capText(label: TextLabel, maxPixels: number)
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = math.clamp(maxPixels, 1, 100)
	constraint.MinTextSize = 1
	constraint.Parent = label
end

--[[
	Height (as a fraction of a box `aspect` wide-over-tall) at which a string of
	`text` lays out on a single line under TextScaled, filling the box width.

	The divisor is the average advance width per character, in ems, for
	Montserrat at the heavy weights used here. It was calibrated against measured
	TextBounds rather than guessed: at 0.62 a twelve-character name filled only
	~66% of its box and the print read as undersized.

	It must stay comfortably above HALF the resulting single-line height, because
	TextScaled prefers wrapping to filling a tall box -- leave room for two lines
	and it will break the name in half rather than set it larger. At this value a
	two-line layout is always smaller than a one-line one, so it never wraps.
]]
local CHAR_ADVANCE_EM = 0.45

local function singleLineHeight(text: string, aspect: number): number
	local charCount = math.max(1, utf8.len(text) or #text)
	return math.clamp(aspect / (charCount * CHAR_ADVANCE_EM), 0.04, 1)
end

--[[
	Derives ink colours from the palette, with two special cases:

	  * "tonal" resolves against the garment colour for a same-colour print
		(slightly lifted on dark fabric, slightly dropped on light) -- a real
		technique that cannot be expressed as a fixed colour.
	  * low quality desaturates and lifts the ink toward the garment colour,
		which is what a thin, under-cured or misregistered print actually looks
		like.
]]
local function resolveInk(spec: any, context: RenderContext): (Color3, Color3)
	local palette = Graphics.getPalette(spec.paletteId) or Graphics.getPalette("white")
	assert(palette, "palette catalogue is empty")

	local ink, secondary = palette.ink, palette.secondary

	if spec.paletteId == "tonal" then
		local base = context.garmentColor
		local shift = if context.garmentIsDark then 0.12 else -0.1
		ink = Color3.new(
			math.clamp(base.R + shift, 0, 1),
			math.clamp(base.G + shift, 0, 1),
			math.clamp(base.B + shift, 0, 1)
		)
		secondary = ink
	end

	local quality = context.quality
	if quality and quality < 0.85 then
		-- Pull the ink toward the fabric as quality drops: a weak print does not
		-- sit on top of the cloth, it sinks into it.
		local blend = (1 - quality) * 0.45
		ink = ink:Lerp(context.garmentColor, blend)
		secondary = secondary:Lerp(context.garmentColor, blend * 0.8)
	end

	return ink, secondary
end

-- Applies the look of the chosen print method to a rendered layer.
local function applyPrintStyle(
	layer: Frame,
	printMethodId: string,
	ink: Color3,
	context: RenderContext
)
	local method = PrintMethods.get(printMethodId)
	local style = method and method.renderStyle or "flat"
	local quality = context.quality or 1

	if style == "raised" then
		-- Puff: a displaced darker copy behind the artwork reads as height.
		local shadow = layer:Clone()
		shadow.Name = "PuffShadow"
		shadow.ZIndex = layer.ZIndex - 1
		shadow.Position = layer.Position + UDim2.fromScale(0.006, 0.012)
		for _, descendant in ipairs(shadow:GetDescendants()) do
			if descendant:IsA("TextLabel") then
				descendant.TextColor3 = ink:Lerp(Color3.new(0, 0, 0), 0.55)
			elseif descendant:IsA("Frame") and descendant.BackgroundTransparency < 1 then
				descendant.BackgroundColor3 = ink:Lerp(Color3.new(0, 0, 0), 0.55)
			end
		end
		shadow.Parent = layer.Parent
	elseif style == "stitched" then
		-- Embroidery: a tight darker outline on every mark reads as thread.
		for _, descendant in ipairs(layer:GetDescendants()) do
			if descendant:IsA("TextLabel") then
				local stroke = Instance.new("UIStroke")
				stroke.Thickness = 1.4
				stroke.Color = ink:Lerp(Color3.new(0, 0, 0), 0.42)
				stroke.Transparency = 0.15
				stroke.Parent = descendant
			end
		end
	elseif style == "patch" then
		-- Appliqué: artwork sits on a stitched fabric panel.
		local panel = Instance.new("Frame")
		panel.Name = "AppliquePanel"
		panel.BackgroundColor3 = ink:Lerp(context.garmentColor, 0.22)
		panel.BorderSizePixel = 0
		panel.Size = layer.Size + UDim2.fromScale(0.12, 0.16)
		panel.Position = layer.Position
		panel.AnchorPoint = layer.AnchorPoint
		panel.ZIndex = layer.ZIndex - 1
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.06, 0)
		corner.Parent = panel
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = ink
		stroke.Transparency = 0.35
		stroke.Parent = panel
		panel.Parent = layer.Parent
	elseif style == "soft" then
		-- DTG: ink sits in the fibres, so it is never fully opaque.
		for _, descendant in ipairs(layer:GetDescendants()) do
			if descendant:IsA("TextLabel") then
				descendant.TextTransparency = 0.12
			end
		end
	end

	-- Poorly executed prints lose opacity and edge definition regardless of method.
	if quality < 0.6 then
		local fade = (0.6 - quality) * 0.5
		for _, descendant in ipairs(layer:GetDescendants()) do
			if descendant:IsA("TextLabel") then
				descendant.TextTransparency = math.min(0.6, descendant.TextTransparency + fade)
			elseif descendant:IsA("Frame") and descendant.BackgroundTransparency < 1 then
				descendant.BackgroundTransparency = math.min(0.6, descendant.BackgroundTransparency + fade)
			end
		end
	end
end

-- ============================================================================
-- Recipe renderers
-- ============================================================================

local recipeRenderers: { [string]: (Frame, any, RenderContext, Color3, Color3, string) -> () } = {}

recipeRenderers.Wordmark = function(layer, spec, context, ink, _secondary, text)
	local upper = string.upper(text)
	local label = newLabel(layer, "Wordmark", upper, Enum.FontWeight.ExtraBold)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	--[[
		Wide and short, NOT square. A square box lets TextScaled grow the type
		until it wraps, which split "NOIR ATELIER" onto two lines and read as a
		broken logo. Constraining the height forces width to be the binding
		dimension, which keeps any name on one line.
	]]
	label.Size = UDim2.fromScale(1, singleLineHeight(upper, 1.15))
	label.TextColor3 = ink
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	capText(label, 100)
end

--[[
	ArchText -- genuine per-character arching.

	Roblox cannot curve a text run, so each character becomes its own rotated
	label positioned on a circular arc. Width is apportioned by character count,
	which is approximate for proportional type but visually correct at the sizes
	this renders at.
]]
recipeRenderers.ArchText = function(layer, spec, context, ink, secondary, text)
	local upper = string.upper(text)

	local characters = {}
	for _, codepoint in utf8.codes(upper) do
		table.insert(characters, utf8.char(codepoint))
	end
	local count = #characters

	local archHolder = newFrame(layer, "Arch")
	archHolder.Size = UDim2.fromScale(1, 0.68)
	archHolder.Position = UDim2.fromScale(0, 0)

	if count > 0 then
		-- Wider words need a shallower arc or the ends drop off the panel.
		local totalSweep = math.clamp(16 + count * 4.5, 24, 74)
		local startAngle = -totalSweep / 2
		local step = if count > 1 then totalSweep / (count - 1) else 0
		local radius = 0.52
		local charWidth = math.clamp(1.05 / count, 0.04, 0.3)

		for index, character in ipairs(characters) do
			local angleDeg = startAngle + step * (index - 1)
			local angleRad = math.rad(angleDeg)

			local glyph = newLabel(archHolder, "C" .. index, character, Enum.FontWeight.ExtraBold)
			glyph.AnchorPoint = Vector2.new(0.5, 0.5)
			-- Single glyphs never wrap, so the box can stay tall and the character
			-- fills it.
			glyph.Size = UDim2.fromScale(charWidth, charWidth * 1.9)
			glyph.Position = UDim2.fromScale(
				0.5 + math.sin(angleRad) * radius,
				0.92 - math.cos(angleRad) * radius
			)
			glyph.Rotation = angleDeg
			glyph.TextColor3 = ink
			capText(glyph, 100)
		end
	end

	if spec.subtext and spec.subtext ~= "" then
		local subUpper = string.upper(spec.subtext)
		local sub = newLabel(layer, "Subtext", subUpper, Enum.FontWeight.Medium)
		sub.Size = UDim2.fromScale(0.86, math.min(0.1, singleLineHeight(subUpper, 0.99)))
		sub.Position = UDim2.fromScale(0.07, 0.8)
		sub.TextColor3 = secondary
		capText(sub, 40)

		local rule = newFrame(layer, "Rule")
		rule.BackgroundTransparency = 0
		rule.BackgroundColor3 = secondary
		rule.Size = UDim2.fromScale(0.5, 0.012)
		rule.Position = UDim2.fromScale(0.25, 0.755)
	end
end

recipeRenderers.BoxLogo = function(layer, spec, context, ink, secondary, text)
	local box = newFrame(layer, "Box")
	box.BackgroundTransparency = 0
	box.BackgroundColor3 = ink
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.5)
	box.Size = UDim2.fromScale(1, 0.42)

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0.045, 0)
	padding.PaddingRight = UDim.new(0.045, 0)
	padding.PaddingTop = UDim.new(0.1, 0)
	padding.PaddingBottom = UDim.new(0.1, 0)
	padding.Parent = box

	local boxUpper = string.upper(text)
	local label = newLabel(box, "Label", boxUpper, Enum.FontWeight.ExtraBold)
	label.Size = UDim2.fromScale(1, 1)
	--[[
		Knocked out to the GARMENT colour, not the palette's secondary. A box
		logo is printed as a solid rectangle with the letterforms left unprinted,
		so the fabric itself shows through. Using the palette secondary here
		produced near-zero contrast (dark grey type on a black box) and read as a
		solid rectangle with no visible name.
	]]
	label.TextColor3 = context.garmentColor
	capText(label, 100)
end

recipeRenderers.Emblem = function(layer, spec, context, ink, secondary, text)
	-- Force a square so the roundel stays circular in any panel aspect.
	local holder = newFrame(layer, "Emblem")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(1, 1)
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = holder

	local ring = newFrame(holder, "Ring")
	ring.Size = UDim2.fromScale(1, 1)
	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(0.5, 0)
	ringCorner.Parent = ring
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Thickness = 3
	ringStroke.Color = ink
	ringStroke.Parent = ring

	local inner = newFrame(holder, "InnerRing")
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.Size = UDim2.fromScale(0.86, 0.86)
	local innerCorner = Instance.new("UICorner")
	innerCorner.CornerRadius = UDim.new(0.5, 0)
	innerCorner.Parent = inner
	local innerStroke = Instance.new("UIStroke")
	innerStroke.Thickness = 1
	innerStroke.Color = ink
	innerStroke.Transparency = 0.45
	innerStroke.Parent = inner

	local emblemUpper = string.upper(text)
	local label = newLabel(holder, "Label", emblemUpper, Enum.FontWeight.Bold)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.44)
	label.Size = UDim2.fromScale(0.66, math.min(0.2, singleLineHeight(emblemUpper, 0.66)))
	label.TextColor3 = ink
	capText(label, 100)

	if spec.subtext and spec.subtext ~= "" then
		local sub = newLabel(holder, "Subtext", string.upper(spec.subtext), Enum.FontWeight.Medium)
		sub.AnchorPoint = Vector2.new(0.5, 0.5)
		sub.Position = UDim2.fromScale(0.5, 0.62)
		sub.Size = UDim2.fromScale(0.58, 0.09)
		sub.TextColor3 = secondary
		capText(sub, 40)
	end

	-- Two short rules flanking the centre, a standard roundel device.
	for index, xPosition in ipairs({ 0.17, 0.83 }) do
		local tick = newFrame(holder, "Tick" .. index)
		tick.BackgroundTransparency = 0
		tick.BackgroundColor3 = ink
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.Position = UDim2.fromScale(xPosition, 0.5)
		tick.Size = UDim2.fromScale(0.05, 0.012)
	end
end

recipeRenderers.Monogram = function(layer, spec, context, ink, _secondary, text)
	-- Initials from the brand name: "Noir Atelier" -> "NA". Falls back to the
	-- first two characters for a single-word name.
	local initials = ""
	for word in string.gmatch(text, "%S+") do
		initials ..= string.upper(string.sub(word, 1, 1))
		if #initials >= 3 then
			break
		end
	end
	if #initials < 2 then
		initials = string.upper(string.sub(text, 1, 2))
	end

	local holder = newFrame(layer, "Monogram")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(1, 1)
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = holder

	local label = newLabel(holder, "Initials", initials, Enum.FontWeight.Heavy)
	label.Size = UDim2.fromScale(1, 1)
	label.TextColor3 = ink
	capText(label, 100)
end

recipeRenderers.StripeStack = function(layer, spec, context, ink, secondary, text)
	local upper = string.upper(text)
	local ROWS = 5

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.Padding = UDim.new(0.018, 0)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = layer

	for row = 1, ROWS do
		local band = newFrame(layer, "Band" .. row)
		band.Size = UDim2.fromScale(1, 0.15)
		band.LayoutOrder = row

		-- Alternating inverted bands: solid ink with knocked-out type, then
		-- plain type on fabric.
		local inverted = row % 2 == 1
		if inverted then
			band.BackgroundTransparency = 0
			band.BackgroundColor3 = ink
		end

		local label = newLabel(band, "Label", upper, Enum.FontWeight.ExtraBold)
		label.Size = UDim2.fromScale(1, 1)
		-- Inverted bands knock out to the garment; plain bands print in ink.
		label.TextColor3 = if inverted then context.garmentColor else ink
		capText(label, 100)
	end
end

-- ============================================================================
-- Public API
-- ============================================================================

--[[
	render(container, spec, context) -> Frame

	Builds the graphic into `container`, sized and positioned according to the
	spec's placement panel, scale, offset and rotation. Returns the layer frame
	so callers can animate or remove it.

	`container` is expected to already represent ONE placement panel -- the
	caller (GarmentBuilder or the design canvas) decides where the panel is. This
	keeps panel geometry in Config.Garments and out of the renderer.
]]
function GraphicRenderer.render(container: GuiObject, spec: any, context: RenderContext): Frame?
	local recipe = Graphics.getRecipe(spec.recipeId)
	if not recipe then
		return nil
	end

	local renderer = recipeRenderers[recipe.kind]
	if not renderer then
		return nil
	end

	local ink, secondary = resolveInk(spec, context)

	-- Resolve the display text. nil text means "use the brand name".
	local text = spec.text
	if text == nil or text == "" then
		text = context.brandName
	end
	if recipe.maxTextLength and utf8.len(text) and (utf8.len(text) :: number) > recipe.maxTextLength then
		local offset = utf8.offset(text, recipe.maxTextLength + 1)
		if offset then
			text = string.sub(text, 1, offset - 1)
		end
	end

	local scale = math.clamp(spec.scale or recipe.defaultScale, 0.05, 1)
	local offsetX = math.clamp((spec.offset and spec.offset.x) or 0, -0.5, 0.5)
	local offsetY = math.clamp((spec.offset and spec.offset.y) or 0, -0.5, 0.5)

	local layer = Instance.new("Frame")
	layer.Name = "GraphicLayer"
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
	layer.AnchorPoint = Vector2.new(0.5, 0.5)
	layer.Position = UDim2.fromScale(0.5 + offsetX, 0.5 + offsetY)
	layer.Size = UDim2.fromScale(scale, scale)
	layer.Rotation = math.clamp(spec.rotation or 0, -180, 180)
	layer.ClipsDescendants = false
	layer.Parent = container

	--[[
		Misregistration: a low-quality print is physically OFF-CENTRE, not just
		faded. The displacement is derived from the seed so a given sample always
		has the same flaw in the same place -- re-opening the inspection view must
		not reshuffle it.
	]]
	local quality = context.quality
	if quality and quality < 0.75 then
		local random = Random.new(context.seed or 0)
		local severity = (0.75 - quality) * 0.06
		layer.Position += UDim2.fromScale(
			random:NextNumber(-severity, severity),
			random:NextNumber(-severity, severity)
		)
		layer.Rotation += random:NextNumber(-severity * 40, severity * 40)
	end

	renderer(layer, spec, context, ink, secondary, text)
	applyPrintStyle(layer, spec.printMethodId, ink, context)

	return layer
end

-- Convenience for the Design app's recipe picker: renders a neutral thumbnail.
function GraphicRenderer.renderThumbnail(
	container: GuiObject,
	recipeId: string,
	brandName: string,
	inkColor: Color3,
	backgroundColor: Color3
): Frame?
	local recipe = Graphics.getRecipe(recipeId)
	if not recipe then
		return nil
	end

	return GraphicRenderer.render(container, {
		recipeId = recipeId,
		kind = recipe.kind,
		paletteId = "white",
		placement = recipe.defaultPlacement,
		scale = 0.92,
		offset = { x = 0, y = 0 },
		rotation = 0,
		printMethodId = "dtf",
		subtext = recipe.defaultSubtext,
	}, {
		brandName = brandName,
		garmentColor = backgroundColor,
		garmentIsDark = true,
	})
end

GraphicRenderer.FONT_FAMILY = FONT_FAMILY
GraphicRenderer.MONO_FAMILY = MONO_FAMILY
GraphicRenderer.font = font

return GraphicRenderer
