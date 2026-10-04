--!strict
--[[
	UI.Components

	The primitives every app is built from.

	These exist so the three apps cannot drift apart visually. An app never
	creates a raw TextLabel or TextButton -- it asks for `Components.text` or
	`Components.button`, so changing a token in Theme restyles the whole
	interface rather than one screen.

	Conventions:

	* Every constructor takes a props table and returns the instance.
	* Sizing and position are the CALLER's business, so the same button works in
	  a sidebar, a toolbar or a form.
	* Interactive components own their hover/press states.
	* Player-authored text is rendered with RichText off, everywhere, without
	  exception -- a brand name must never be parsed as markup.
]]

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local Components = {}

-- ============================================================================
-- Primitives
-- ============================================================================

export type FrameProps = {
	name: string?,
	parent: Instance?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	color: Color3?,
	transparency: number?,
	radius: number?,
	stroke: Color3?,
	strokeThickness: number?,
	clip: boolean?,
	layoutOrder: number?,
	zIndex: number?,
	automaticSize: Enum.AutomaticSize?,
}

function Components.frame(props: FrameProps): Frame
	local frame = Instance.new("Frame")
	frame.Name = props.name or "Frame"
	frame.BackgroundColor3 = props.color or Theme.color.surface
	frame.BackgroundTransparency = props.transparency or (if props.color then 0 else 1)
	frame.BorderSizePixel = 0
	frame.Size = props.size or UDim2.fromScale(1, 1)
	frame.Position = props.position or UDim2.fromScale(0, 0)
	frame.AnchorPoint = props.anchor or Vector2.new(0, 0)
	frame.ClipsDescendants = props.clip or false
	frame.LayoutOrder = props.layoutOrder or 0
	frame.ZIndex = props.zIndex or 1

	if props.automaticSize then
		frame.AutomaticSize = props.automaticSize
	end

	if props.radius then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, props.radius)
		corner.Parent = frame
	end

	if props.stroke then
		local stroke = Instance.new("UIStroke")
		stroke.Color = props.stroke
		stroke.Thickness = props.strokeThickness or Theme.stroke.hairline
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = frame
	end

	frame.Parent = props.parent
	return frame
end

export type TextProps = {
	name: string?,
	parent: Instance?,
	text: string,
	variant: string?,
	color: Color3?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	align: Enum.TextXAlignment?,
	valign: Enum.TextYAlignment?,
	wrap: boolean?,
	data: boolean?,
	layoutOrder: number?,
	zIndex: number?,
	automaticSize: Enum.AutomaticSize?,
	truncate: boolean?,
	scale: number?,
	transparency: number?,
}

function Components.text(props: TextProps): TextLabel
	local spec = Theme.type[props.variant or "body"] or Theme.type.body
	local uiScale = props.scale or 1

	local label = Instance.new("TextLabel")
	label.Name = props.name or "Text"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Text = props.text
	label.FontFace = if props.data then Theme.dataFont(spec.weight) else Theme.font(spec.weight)
	label.TextSize = math.round(spec.size * uiScale)
	label.TextColor3 = props.color or Theme.color.textPrimary
	label.TextTransparency = props.transparency or 0
	label.TextXAlignment = props.align or Enum.TextXAlignment.Left
	label.TextYAlignment = props.valign or Enum.TextYAlignment.Center
	-- Never parse player text as markup.
	label.RichText = false
	label.Size = props.size or UDim2.new(1, 0, 0, math.round(spec.size * uiScale * 1.5))
	label.Position = props.position or UDim2.fromScale(0, 0)
	label.AnchorPoint = props.anchor or Vector2.new(0, 0)
	label.LayoutOrder = props.layoutOrder or 0
	label.ZIndex = props.zIndex or 1

	if props.wrap then
		label.TextWrapped = true
	end
	if props.truncate then
		label.TextTruncate = Enum.TextTruncate.AtEnd
	end
	if props.automaticSize then
		label.AutomaticSize = props.automaticSize
	end

	label.Parent = props.parent
	return label
end

-- ============================================================================
-- Layout helpers
-- ============================================================================

function Components.list(parent: Instance, props: {
	direction: Enum.FillDirection?,
	padding: number?,
	horizontalAlign: Enum.HorizontalAlignment?,
	verticalAlign: Enum.VerticalAlignment?,
	sortOrder: Enum.SortOrder?,
	scale: number?,
	wraps: boolean?,
}?): UIListLayout
	local options = props or {}
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = options.direction or Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, math.round((options.padding or Theme.space.sm) * (options.scale or 1)))
	layout.HorizontalAlignment = options.horizontalAlign or Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = options.verticalAlign or Enum.VerticalAlignment.Top
	layout.SortOrder = options.sortOrder or Enum.SortOrder.LayoutOrder
	if options.wraps then
		layout.Wraps = true
	end
	layout.Parent = parent
	return layout
end

function Components.grid(parent: Instance, props: {
	cellSize: UDim2,
	padding: number?,
	scale: number?,
	horizontalAlign: Enum.HorizontalAlignment?,
}): UIGridLayout
	local uiScale = props.scale or 1
	local pad = math.round((props.padding or Theme.space.sm) * uiScale)
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = props.cellSize
	layout.CellPadding = UDim2.new(0, pad, 0, pad)
	layout.HorizontalAlignment = props.horizontalAlign or Enum.HorizontalAlignment.Left
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent
	return layout
end

function Components.padding(
	parent: Instance,
	amount: number | { top: number?, bottom: number?, left: number?, right: number? },
	scale: number?
): UIPadding
	local uiScale = scale or 1
	local pad = Instance.new("UIPadding")
	if type(amount) == "number" then
		local value = UDim.new(0, math.round(amount * uiScale))
		pad.PaddingTop = value
		pad.PaddingBottom = value
		pad.PaddingLeft = value
		pad.PaddingRight = value
	else
		pad.PaddingTop = UDim.new(0, math.round((amount.top or 0) * uiScale))
		pad.PaddingBottom = UDim.new(0, math.round((amount.bottom or 0) * uiScale))
		pad.PaddingLeft = UDim.new(0, math.round((amount.left or 0) * uiScale))
		pad.PaddingRight = UDim.new(0, math.round((amount.right or 0) * uiScale))
	end
	pad.Parent = parent
	return pad
end

function Components.scroll(props: FrameProps): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = props.name or "Scroll"
	scroll.BackgroundTransparency = props.transparency or 1
	scroll.BackgroundColor3 = props.color or Theme.color.surface
	scroll.BorderSizePixel = 0
	scroll.Size = props.size or UDim2.fromScale(1, 1)
	scroll.Position = props.position or UDim2.fromScale(0, 0)
	scroll.AnchorPoint = props.anchor or Vector2.new(0, 0)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 3
	scroll.ScrollBarImageColor3 = Theme.color.borderStrong
	scroll.ScrollBarImageTransparency = 0.2
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	scroll.ZIndex = props.zIndex or 1
	scroll.Parent = props.parent
	return scroll
end

function Components.divider(parent: Instance, props: {
	vertical: boolean?,
	layoutOrder: number?,
}?): Frame
	local options = props or {}
	local line = Instance.new("Frame")
	line.Name = "Divider"
	line.BackgroundColor3 = Theme.color.border
	line.BorderSizePixel = 0
	line.LayoutOrder = options.layoutOrder or 0
	line.Size = if options.vertical then UDim2.new(0, 1, 1, 0) else UDim2.new(1, 0, 0, 1)
	line.Parent = parent
	return line
end

-- Transparent spacer, for list layouts that need a gap without a divider.
function Components.spacer(parent: Instance, height: number, layoutOrder: number?, scale: number?): Frame
	local spacer = Instance.new("Frame")
	spacer.Name = "Spacer"
	spacer.BackgroundTransparency = 1
	spacer.BorderSizePixel = 0
	spacer.Size = UDim2.new(1, 0, 0, math.round(height * (scale or 1)))
	spacer.LayoutOrder = layoutOrder or 0
	spacer.Parent = parent
	return spacer
end

-- ============================================================================
-- Buttons
-- ============================================================================

export type ButtonProps = {
	name: string?,
	parent: Instance?,
	text: string,
	variant: string?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	layoutOrder: number?,
	onClick: (() -> ())?,
	enabled: boolean?,
	scale: number?,
	zIndex: number?,
}

local BUTTON_VARIANTS = {
	primary = {
		background = Theme.color.accent,
		backgroundHover = Theme.color.accentHover,
		text = Theme.color.textInverse,
		stroke = nil,
	},
	secondary = {
		background = Theme.color.surfaceRaised,
		backgroundHover = Theme.color.surfaceHover,
		text = Theme.color.textPrimary,
		stroke = Theme.color.border,
	},
	ghost = {
		background = Theme.color.surface,
		backgroundHover = Theme.color.surfaceRaised,
		text = Theme.color.textSecondary,
		stroke = nil,
	},
	danger = {
		background = Theme.color.surfaceRaised,
		backgroundHover = Color3.fromRGB(54, 32, 32),
		text = Theme.color.critical,
		stroke = Theme.color.border,
	},
}

export type ButtonHandle = {
	root: TextButton,
	setEnabled: (boolean) -> (),
	setText: (string) -> (),
}

function Components.button(props: ButtonProps): ButtonHandle
	local uiScale = props.scale or 1
	local variant = BUTTON_VARIANTS[props.variant or "secondary"] or BUTTON_VARIANTS.secondary
	local enabled = props.enabled ~= false

	local button = Instance.new("TextButton")
	button.Name = props.name or "Button"
	button.AutoButtonColor = false -- hover handled explicitly
	button.BackgroundColor3 = variant.background
	button.BorderSizePixel = 0
	button.Size = props.size or UDim2.new(0, math.round(140 * uiScale), 0, math.round(38 * uiScale))
	button.Position = props.position or UDim2.fromScale(0, 0)
	button.AnchorPoint = props.anchor or Vector2.new(0, 0)
	button.LayoutOrder = props.layoutOrder or 0
	button.ZIndex = props.zIndex or 1
	button.Text = ""

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.radius.md)
	corner.Parent = button

	if variant.stroke then
		local stroke = Instance.new("UIStroke")
		stroke.Color = variant.stroke
		stroke.Thickness = Theme.stroke.hairline
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = button
	end

	local label = Components.text({
		parent = button,
		name = "Label",
		text = props.text,
		variant = "bodyStrong",
		color = variant.text,
		align = Enum.TextXAlignment.Center,
		size = UDim2.fromScale(1, 1),
		scale = uiScale,
		zIndex = (props.zIndex or 1) + 1,
	})

	local function applyEnabled(isEnabled: boolean)
		enabled = isEnabled
		button.Active = isEnabled
		button.Selectable = isEnabled
		button.BackgroundTransparency = if isEnabled then 0 else 0.45
		label.TextTransparency = if isEnabled then 0 else 0.5
	end

	applyEnabled(enabled)

	local function tweenBackground(color: Color3)
		if not enabled then
			return
		end
		TweenService:Create(button, Theme.tweenInfo(Theme.motion.fast), { BackgroundColor3 = color }):Play()
	end

	button.MouseEnter:Connect(function()
		tweenBackground(variant.backgroundHover)
	end)
	button.MouseLeave:Connect(function()
		tweenBackground(variant.background)
	end)
	button.MouseButton1Click:Connect(function()
		if enabled and props.onClick then
			props.onClick()
		end
	end)

	button.Parent = props.parent

	return {
		root = button,
		setEnabled = applyEnabled,
		setText = function(text: string)
			label.Text = text
		end,
	}
end

-- ============================================================================
-- Selectable tile
-- ============================================================================

--[[
	A selectable option: style presets, colourways, blanks, print methods,
	suppliers -- anywhere the player picks one of several.

	Selection is indicated with a ring and a lifted surface, never a fill colour,
	so a grid of colour swatches still reads correctly: the swatch keeps its own
	colour and the selection sits around it.
]]
export type TileProps = {
	name: string?,
	parent: Instance?,
	size: UDim2?,
	layoutOrder: number?,
	selected: boolean?,
	enabled: boolean?,
	onClick: (() -> ())?,
	scale: number?,
	zIndex: number?,
	transparentBackground: boolean?,
}

export type TileHandle = {
	root: TextButton,
	content: Frame,
	setSelected: (boolean) -> (),
	setEnabled: (boolean) -> (),
	isEnabled: () -> boolean,
}

function Components.tile(props: TileProps): TileHandle
	local uiScale = props.scale or 1
	local enabled = props.enabled ~= false
	local selected = props.selected or false

	local root = Instance.new("TextButton")
	root.Name = props.name or "Tile"
	root.AutoButtonColor = false
	root.Text = ""
	root.BackgroundColor3 = Theme.color.surfaceRaised
	root.BackgroundTransparency = if props.transparentBackground then 1 else 0
	root.BorderSizePixel = 0
	root.Size = props.size or UDim2.new(0, math.round(120 * uiScale), 0, math.round(96 * uiScale))
	root.LayoutOrder = props.layoutOrder or 0
	root.ZIndex = props.zIndex or 1

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.radius.lg)
	corner.Parent = root

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Theme.stroke.hairline
	stroke.Color = Theme.color.border
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = root

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1)
	content.ZIndex = root.ZIndex + 1
	content.Parent = root

	local function applySelected(isSelected: boolean)
		selected = isSelected
		TweenService:Create(stroke, Theme.tweenInfo(Theme.motion.fast), {
			Color = if isSelected then Theme.color.accent else Theme.color.border,
			Thickness = if isSelected then Theme.stroke.strong else Theme.stroke.hairline,
		}):Play()
		if not props.transparentBackground then
			TweenService:Create(root, Theme.tweenInfo(Theme.motion.fast), {
				BackgroundColor3 = if isSelected then Theme.color.surfaceActive else Theme.color.surfaceRaised,
			}):Play()
		end
	end

	local function applyEnabled(isEnabled: boolean)
		enabled = isEnabled
		root.Active = isEnabled
		root.Selectable = isEnabled
		for _, descendant in ipairs(content:GetDescendants()) do
			if descendant:IsA("TextLabel") then
				descendant.TextTransparency = if isEnabled then 0 else 0.55
			end
		end
	end

	applySelected(selected)
	applyEnabled(enabled)

	root.MouseEnter:Connect(function()
		if enabled and not selected then
			TweenService:Create(stroke, Theme.tweenInfo(Theme.motion.fast), {
				Color = Theme.color.borderStrong,
			}):Play()
		end
	end)
	root.MouseLeave:Connect(function()
		if enabled and not selected then
			TweenService:Create(stroke, Theme.tweenInfo(Theme.motion.fast), {
				Color = Theme.color.border,
			}):Play()
		end
	end)
	root.MouseButton1Click:Connect(function()
		if enabled and props.onClick then
			props.onClick()
		end
	end)

	root.Parent = props.parent

	return {
		root = root,
		content = content,
		setSelected = applySelected,
		setEnabled = applyEnabled,
		isEnabled = function()
			return enabled
		end,
	}
end

-- ============================================================================
-- Text field
-- ============================================================================

function Components.field(props: {
	name: string?,
	parent: Instance?,
	placeholder: string?,
	text: string?,
	maxLength: number?,
	size: UDim2?,
	layoutOrder: number?,
	onChanged: ((string) -> ())?,
	onSubmit: ((string) -> ())?,
	scale: number?,
}): TextBox
	local uiScale = props.scale or 1

	local container = Components.frame({
		name = (props.name or "Field") .. "Container",
		parent = props.parent,
		size = props.size or UDim2.new(1, 0, 0, math.round(44 * uiScale)),
		color = Theme.color.base,
		radius = Theme.radius.md,
		stroke = Theme.color.border,
		layoutOrder = props.layoutOrder,
	})

	Components.padding(container, { left = Theme.space.md, right = Theme.space.md }, uiScale)

	local box = Instance.new("TextBox")
	box.Name = props.name or "Field"
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Size = UDim2.fromScale(1, 1)
	box.Text = props.text or ""
	box.PlaceholderText = props.placeholder or ""
	box.PlaceholderColor3 = Theme.color.textTertiary
	box.TextColor3 = Theme.color.textPrimary
	box.FontFace = Theme.font(Enum.FontWeight.Medium)
	box.TextSize = math.round(Theme.type.body.size * uiScale)
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = false
	box.RichText = false
	box.Parent = container

	local stroke = container:FindFirstChildOfClass("UIStroke")

	box.Focused:Connect(function()
		if stroke then
			TweenService:Create(stroke, Theme.tweenInfo(Theme.motion.fast), { Color = Theme.color.accent }):Play()
		end
	end)

	box.FocusLost:Connect(function(enterPressed)
		if stroke then
			TweenService:Create(stroke, Theme.tweenInfo(Theme.motion.fast), { Color = Theme.color.border }):Play()
		end
		if enterPressed and props.onSubmit then
			props.onSubmit(box.Text)
		end
	end)

	--[[
		Length is clamped as the player types. The server validates independently;
		this only stops the field accepting text the server is certain to reject.
	]]
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if props.maxLength and #box.Text > props.maxLength then
			box.Text = string.sub(box.Text, 1, props.maxLength)
			return
		end
		if props.onChanged then
			props.onChanged(box.Text)
		end
	end)

	return box
end

-- ============================================================================
-- Data display
-- ============================================================================

function Components.statRow(props: {
	parent: Instance?,
	label: string,
	value: string,
	valueColor: Color3?,
	layoutOrder: number?,
	scale: number?,
}): Frame
	local uiScale = props.scale or 1

	local row = Components.frame({
		name = "StatRow",
		parent = props.parent,
		size = UDim2.new(1, 0, 0, math.round(24 * uiScale)),
		layoutOrder = props.layoutOrder,
	})

	Components.text({
		parent = row,
		text = props.label,
		variant = "small",
		color = Theme.color.textTertiary,
		size = UDim2.new(0.52, 0, 1, 0),
		scale = uiScale,
		truncate = true,
	})

	Components.text({
		parent = row,
		text = props.value,
		variant = "small",
		color = props.valueColor or Theme.color.textPrimary,
		size = UDim2.new(0.48, 0, 1, 0),
		position = UDim2.fromScale(0.52, 0),
		align = Enum.TextXAlignment.Right,
		data = true,
		scale = uiScale,
		truncate = true,
	})

	return row
end

--[[
	A labelled 0..1 bar, coloured by Theme.qualityColor so a weak score reads as
	weak without the player parsing a number. This is what makes an inspection
	scannable at a glance.
]]
function Components.meter(props: {
	parent: Instance?,
	label: string,
	value: number,
	caption: string?,
	layoutOrder: number?,
	scale: number?,
	animate: boolean?,
	delay: number?,
}): Frame
	local uiScale = props.scale or 1
	local value = math.clamp(props.value, 0, 1)

	local row = Components.frame({
		name = "Meter",
		parent = props.parent,
		size = UDim2.new(1, 0, 0, math.round(42 * uiScale)),
		layoutOrder = props.layoutOrder,
	})

	Components.text({
		parent = row,
		text = props.label,
		variant = "small",
		color = Theme.color.textSecondary,
		size = UDim2.new(0.6, 0, 0, math.round(18 * uiScale)),
		scale = uiScale,
	})

	Components.text({
		parent = row,
		text = props.caption or "",
		variant = "small",
		color = Theme.qualityColor(value),
		size = UDim2.new(0.4, 0, 0, math.round(18 * uiScale)),
		position = UDim2.fromScale(0.6, 0),
		align = Enum.TextXAlignment.Right,
		scale = uiScale,
	})

	local track = Components.frame({
		name = "Track",
		parent = row,
		size = UDim2.new(1, 0, 0, math.round(5 * uiScale)),
		position = UDim2.new(0, 0, 0, math.round(26 * uiScale)),
		color = Theme.color.base,
		radius = Theme.radius.pill,
	})

	local fill = Components.frame({
		name = "Fill",
		parent = track,
		size = UDim2.fromScale(if props.animate then 0 else value, 1),
		color = Theme.qualityColor(value),
		radius = Theme.radius.pill,
	})

	if props.animate then
		-- Staggering the bars makes an inspection feel like a reveal rather than
		-- a table appearing all at once.
		task.delay(props.delay or 0, function()
			if fill.Parent then
				TweenService:Create(fill, Theme.tweenInfo(Theme.motion.deliberate), {
					Size = UDim2.fromScale(value, 1),
				}):Play()
			end
		end)
	end

	return row
end

function Components.chip(props: {
	parent: Instance?,
	text: string,
	color: Color3?,
	background: Color3?,
	layoutOrder: number?,
	scale: number?,
}): Frame
	local uiScale = props.scale or 1

	local chip = Components.frame({
		name = "Chip",
		parent = props.parent,
		size = UDim2.new(0, 0, 0, math.round(22 * uiScale)),
		color = props.background or Theme.color.surfaceRaised,
		radius = Theme.radius.sm,
		layoutOrder = props.layoutOrder,
		automaticSize = Enum.AutomaticSize.X,
	})

	Components.padding(chip, { left = Theme.space.sm, right = Theme.space.sm }, uiScale)

	Components.text({
		parent = chip,
		text = props.text,
		variant = "micro",
		color = props.color or Theme.color.textSecondary,
		size = UDim2.new(0, 0, 1, 0),
		align = Enum.TextXAlignment.Center,
		automaticSize = Enum.AutomaticSize.X,
		scale = uiScale,
	})

	return chip
end

function Components.sectionHeader(props: {
	parent: Instance?,
	text: string,
	layoutOrder: number?,
	scale: number?,
}): TextLabel
	return Components.text({
		parent = props.parent,
		name = "SectionHeader",
		text = string.upper(props.text),
		variant = "micro",
		color = Theme.color.textTertiary,
		size = UDim2.new(1, 0, 0, math.round(20 * (props.scale or 1))),
		layoutOrder = props.layoutOrder,
		scale = props.scale,
	})
end

function Components.emptyState(props: {
	parent: Instance?,
	title: string,
	body: string?,
	layoutOrder: number?,
	scale: number?,
}): Frame
	local uiScale = props.scale or 1

	local container = Components.frame({
		name = "EmptyState",
		parent = props.parent,
		size = UDim2.new(1, 0, 0, math.round(120 * uiScale)),
		color = Theme.color.surface,
		radius = Theme.radius.lg,
		stroke = Theme.color.border,
		layoutOrder = props.layoutOrder,
	})

	Components.padding(container, Theme.space.xl, uiScale)
	Components.list(container, {
		padding = Theme.space.xs,
		verticalAlign = Enum.VerticalAlignment.Center,
		horizontalAlign = Enum.HorizontalAlignment.Center,
		scale = uiScale,
	})

	Components.text({
		parent = container,
		text = props.title,
		variant = "bodyStrong",
		color = Theme.color.textSecondary,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, math.round(20 * uiScale)),
		layoutOrder = 1,
		scale = uiScale,
	})

	if props.body then
		Components.text({
			parent = container,
			text = props.body,
			variant = "small",
			color = Theme.color.textTertiary,
			align = Enum.TextXAlignment.Center,
			size = UDim2.new(1, 0, 0, math.round(34 * uiScale)),
			wrap = true,
			layoutOrder = 2,
			scale = uiScale,
		})
	end

	return container
end

return Components
