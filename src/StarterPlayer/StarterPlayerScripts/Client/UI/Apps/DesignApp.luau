--!strict
--[[
	Apps.DesignApp

	The product designer.

	== The preview is the real garment ==

	The preview is NOT an illustration of the product. It is the actual garment
	model, built by Shared.Garment.GarmentBuilder from the same spec the server
	holds, rendered into a ViewportFrame. The identical function builds the
	sample that arrives in the parcel.

	That is the whole point of the architecture: what the player sees here and
	what turns up in the box cannot drift apart, because there is only one
	construction path.

	The preview omits `quality`, so it always shows the design as intended. Only
	a manufactured sample carries defects.

	== Every edit is a server round-trip ==

	The client never mutates the spec locally. A change sends UpdateProductSpec,
	the server validates it against config and returns the spec it actually
	stored, and the preview rebuilds from THAT. So an illegal combination is
	visibly rejected rather than shown locally and silently dropped -- and the
	player sees the server's corrections (a fabric snapping to a legal GSM, say)
	immediately.
]]

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Garments = require(Shared.Config.Garments)
local Fabrics = require(Shared.Config.Fabrics)
local PrintMethods = require(Shared.Config.PrintMethods)
local GraphicsConfig = require(Shared.Config.Graphics)
local Styles = require(Shared.Config.Styles)
local GarmentBuilder = require(Shared.Garment.GarmentBuilder)
local Net = require(Shared.Net.Net)
local Format = require(Shared.Util.Format)

local Theme = require(script.Parent.Parent.Theme)
local Components = require(script.Parent.Parent.Components)

local DesignApp = {}

function DesignApp.mount(container: Frame, context: any)
	local uiScale = context.scale

	local selectedProductId: string? = nil
	local previewModel: Model? = nil
	local destroyed = false
	local pendingRequest = false

	-- ---------------------------------------------------------------- layout
	-- Left: product list. Centre: preview. Right: spec controls.
	local LIST_WIDTH = 200
	local PANEL_WIDTH = 300

	local listColumn = Components.frame({
		parent = container,
		name = "Products",
		size = UDim2.new(0, math.round(LIST_WIDTH * uiScale), 1, 0),
		color = Theme.color.base,
	})
	Components.divider(listColumn, { vertical = true }).Position = UDim2.new(1, -1, 0, 0)

	local previewColumn = Components.frame({
		parent = container,
		name = "Preview",
		size = UDim2.new(
			1, -math.round((LIST_WIDTH + PANEL_WIDTH) * uiScale),
			1, 0
		),
		position = UDim2.fromOffset(math.round(LIST_WIDTH * uiScale), 0),
		color = Color3.fromRGB(30, 30, 34),
	})

	--[[
		A soft vertical falloff behind the garment.

		The preview sat on a near-black panel, which meant a BLACK tee -- the
		default for the streetwear direction, so the first thing most players
		see -- was almost invisible against it. Lifting the backdrop and grading
		it gives every colourway something to read against, darkest at the
		bottom so the garment still feels grounded.
	]]
	local backdrop = Instance.new("UIGradient")
	backdrop.Rotation = 90
	backdrop.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(46, 46, 52)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(30, 30, 34)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(18, 18, 21)),
	})
	backdrop.Parent = previewColumn

	local panelColumn = Components.frame({
		parent = container,
		name = "Spec",
		size = UDim2.new(0, math.round(PANEL_WIDTH * uiScale), 1, 0),
		position = UDim2.new(1, -math.round(PANEL_WIDTH * uiScale), 0, 0),
		color = Theme.color.base,
	})
	Components.divider(panelColumn, { vertical = true })

	-- ---------------------------------------------------------------- preview
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "GarmentViewport"
	-- Transparent so the graded backdrop above shows through.
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Size = UDim2.fromScale(1, 1)
	-- Lifted ambient so dark colourways keep their form instead of going flat.
	viewport.Ambient = Color3.fromRGB(188, 188, 196)
	viewport.LightColor = Color3.fromRGB(255, 252, 245)
	viewport.LightDirection = Vector3.new(-0.3, -1, -0.6)
	viewport.Parent = previewColumn

	local world = Instance.new("WorldModel")
	world.Parent = viewport

	local viewportCamera = Instance.new("Camera")
	viewportCamera.Parent = viewport
	viewport.CurrentCamera = viewportCamera

	--[[
		Graphic overlay.

		ViewportFrame does not render SurfaceGui content, so the print cannot be
		drawn on the model itself in here. It is composited as a flat UI layer
		projected exactly onto the garment's front panel instead -- by the same
		GraphicRenderer that prints the physical sample, from the same spec. See
		the long note in GarmentBuilder.
	]]
	local graphicOverlay = Components.frame({
		parent = previewColumn,
		name = "GraphicOverlay",
		size = UDim2.fromScale(1, 1),
		zIndex = 2,
	})

	local previewCaption = Components.text({
		parent = previewColumn,
		name = "Caption",
		text = "",
		variant = "small",
		color = Theme.color.textTertiary,
		size = UDim2.new(1, 0, 0, math.round(20 * uiScale)),
		position = UDim2.new(0, 0, 1, -math.round(34 * uiScale)),
		align = Enum.TextXAlignment.Center,
		scale = uiScale,
		zIndex = 3,
	})

	--[[
		Rebuilds the preview from a spec.

		The old model is destroyed rather than mutated: GarmentBuilder is cheap,
		and rebuilding guarantees the preview is a pure function of the spec with
		no stale leftovers from a previous configuration.
	]]
	local PREVIEW_FOV = 42

	local function renderPreview(spec: any, brandName: string)
		if previewModel then
			previewModel:Destroy()
			previewModel = nil
		end
		graphicOverlay:ClearAllChildren()

		if not spec then
			return
		end

		local model, cameraCFrame = GarmentBuilder.buildForViewport(spec, {
			brandName = brandName,
			-- No quality: a design preview always shows the intended result.
		})
		model.Parent = world
		previewModel = model

		-- Pull back slightly so the garment sits in the frame rather than
		-- filling it edge to edge.
		local finalCamera = cameraCFrame * CFrame.new(0, 0, 0.9)
		viewportCamera.CFrame = finalCamera
		viewportCamera.FieldOfView = PREVIEW_FOV

		local colorway = Garments.getColorway(spec.colorId)

		--[[
			Composite on the next frame: the overlay's AbsoluteSize is only
			correct once layout has run, and the projection needs it to work out
			the aspect ratio.
		]]
		task.defer(function()
			if destroyed or previewModel ~= model or not model.Parent then
				return
			end
			GarmentBuilder.compositeViewportGraphics(
				graphicOverlay,
				model,
				spec,
				finalCamera,
				PREVIEW_FOV,
				{
					brandName = brandName,
					garmentColor = colorway and colorway.color or Color3.new(0, 0, 0),
					garmentIsDark = colorway and colorway.isDark or true,
				}
			)
		end)
	end

	-- ---------------------------------------------------------------- product list
	local listScroll = Components.scroll({ parent = listColumn })
	Components.padding(listScroll, Theme.space.md, uiScale)
	Components.list(listScroll, { padding = Theme.space.xs, scale = uiScale })

	local productTiles: { [string]: any } = {}

	local function renderPanel() end -- forward declaration

	local function selectProduct(productId: string)
		selectedProductId = productId
		for id, tile in pairs(productTiles) do
			tile.setSelected(id == productId)
		end
		renderPanel()
	end

	local function renderProductList(state: any)
		for _, child in ipairs(listScroll:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		table.clear(productTiles)

		Components.sectionHeader({
			parent = listScroll,
			text = "Products",
			layoutOrder = 1,
			scale = uiScale,
		})

		local order = 2
		local any = false

		for _, productId in ipairs(state.productOrder) do
			local product = state.products[productId]
			if product and product.stage ~= "Archived" then
				any = true
				local tile = Components.tile({
					parent = listScroll,
					name = productId,
					size = UDim2.new(1, 0, 0, math.round(54 * uiScale)),
					layoutOrder = order,
					selected = productId == selectedProductId,
					scale = uiScale,
					onClick = function()
						selectProduct(productId)
					end,
				})
				productTiles[productId] = tile
				order += 1

				Components.padding(tile.content, Theme.space.md, uiScale)

				Components.text({
					parent = tile.content,
					text = product.name,
					variant = "bodyStrong",
					size = UDim2.new(1, 0, 0, math.round(17 * uiScale)),
					scale = uiScale,
					truncate = true,
				})

				-- Stage is shown on every product so the pipeline is legible from
				-- the list alone.
				Components.text({
					parent = tile.content,
					text = product.stage,
					variant = "micro",
					color = Theme.color.textTertiary,
					size = UDim2.new(1, 0, 0, math.round(14 * uiScale)),
					position = UDim2.fromOffset(0, math.round(20 * uiScale)),
					scale = uiScale,
					truncate = true,
				})
			end
		end

		if not any then
			Components.text({
				parent = listScroll,
				text = "No products yet.",
				variant = "small",
				color = Theme.color.textTertiary,
				size = UDim2.new(1, 0, 0, math.round(20 * uiScale)),
				layoutOrder = order,
				scale = uiScale,
			})
			order += 1
		end

		Components.spacer(listScroll, Theme.space.sm, order, uiScale)
		order += 1

		Components.button({
			parent = listScroll,
			text = "+  New product",
			variant = "secondary",
			size = UDim2.new(1, 0, 0, math.round(38 * uiScale)),
			layoutOrder = order,
			scale = uiScale,
			onClick = function()
				task.spawn(function()
					local response = Net.invoke("CreateProduct", { name = "" })
					if response.ok then
						selectedProductId = response.data.productId
					else
						context.notify({
							title = "Could not create that",
							body = response.message,
							kind = "warning",
						})
					end
				end)
			end,
		})
	end

	-- ---------------------------------------------------------------- spec panel
	local panelScroll = Components.scroll({ parent = panelColumn })
	Components.padding(panelScroll, Theme.space.lg, uiScale)
	Components.list(panelScroll, { padding = Theme.space.md, scale = uiScale })

	--[[
		Sends a spec patch and rebuilds from the server's response.

		`pendingRequest` serialises edits: without it, dragging a slider or
		clicking quickly through swatches could land responses out of order and
		leave the preview showing an older spec than the server holds.
	]]
	local function patchSpec(patch: any)
		if not selectedProductId or pendingRequest then
			return
		end
		pendingRequest = true
		patch.productId = selectedProductId

		task.spawn(function()
			local response = Net.invoke("UpdateProductSpec", patch)
			pendingRequest = false

			if destroyed then
				return
			end

			if not response.ok then
				context.notify({
					title = "Cannot do that",
					body = response.message,
					kind = "warning",
				})
			end
			-- Either way the server pushes new state, which re-renders the panel.
		end)
	end

	-- Builds a labelled row of selectable options.
	local function optionRow(props: {
		label: string,
		layoutOrder: number,
		options: { { id: string, label: string, swatch: Color3?, enabled: boolean?, hint: string? } },
		selectedId: string?,
		onSelect: (string) -> (),
		columns: number?,
	})
		Components.sectionHeader({
			parent = panelScroll,
			text = props.label,
			layoutOrder = props.layoutOrder,
			scale = uiScale,
		})

		local columns = props.columns or 2
		local rows = math.ceil(#props.options / columns)
		local cellHeight = if props.options[1] and props.options[1].swatch then 42 else 34

		local holder = Components.frame({
			parent = panelScroll,
			name = props.label,
			size = UDim2.new(1, 0, 0, math.round((rows * (cellHeight + 6)) * uiScale)),
			layoutOrder = props.layoutOrder + 1,
		})
		Components.grid(holder, {
			cellSize = UDim2.new(1 / columns, -math.round(5 * uiScale), 0, math.round(cellHeight * uiScale)),
			padding = 6,
			scale = uiScale,
		})

		for index, option in ipairs(props.options) do
			local tile = Components.tile({
				parent = holder,
				name = option.id,
				layoutOrder = index,
				selected = option.id == props.selectedId,
				enabled = option.enabled ~= false,
				scale = uiScale,
				onClick = function()
					props.onSelect(option.id)
				end,
			})

			if option.swatch then
				-- Colour swatch above its name, so the colour is the primary signal.
				Components.frame({
					parent = tile.content,
					name = "Swatch",
					size = UDim2.new(1, -math.round(14 * uiScale), 0, math.round(16 * uiScale)),
					position = UDim2.fromOffset(math.round(7 * uiScale), math.round(6 * uiScale)),
					color = option.swatch,
					radius = Theme.radius.sm,
				})
				Components.text({
					parent = tile.content,
					text = option.label,
					variant = "micro",
					color = Theme.color.textSecondary,
					size = UDim2.new(1, -math.round(8 * uiScale), 0, math.round(14 * uiScale)),
					position = UDim2.fromOffset(math.round(4 * uiScale), math.round(24 * uiScale)),
					align = Enum.TextXAlignment.Center,
					scale = uiScale,
					truncate = true,
				})
			else
				Components.text({
					parent = tile.content,
					text = option.label,
					variant = "small",
					color = Theme.color.textPrimary,
					size = UDim2.fromScale(1, 1),
					align = Enum.TextXAlignment.Center,
					scale = uiScale,
					truncate = true,
				})
			end
		end
	end

	-- Rebuilds the whole right-hand panel for the selected product.
	function renderPanel()
		for _, child in ipairs(panelScroll:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		local state = context.getState()
		if not state then
			return
		end

		local product = selectedProductId and state.products[selectedProductId]
		if not product then
			Components.emptyState({
				parent = panelScroll,
				title = "Nothing selected",
				body = "Create a product or pick one from the list.",
				layoutOrder = 1,
				scale = uiScale,
			})
			renderPreview(nil, "")
			previewCaption.Text = ""
			return
		end

		local spec = product.spec
		local blank = Garments.getBlank(spec.blankId)
		local fabric = Fabrics.get(spec.fabricId)
		local locked = product.stage == "SampleRequested"
			or product.stage == "SampleInProduction"
			or product.stage == "SampleShipped"

		renderPreview(spec, state.identity.name)
		previewCaption.Text = string.format(
			"%s  \u{2022}  %s  \u{2022}  %s",
			blank and blank.name or "?",
			fabric and fabric.name or "?",
			Format.gsm(spec.gsm)
		)

		local order = 1
		local function nextOrder(): number
			order += 1
			return order
		end

		-- ---- name ----
		Components.text({
			parent = panelScroll,
			text = product.name,
			variant = "title",
			size = UDim2.new(1, 0, 0, math.round(28 * uiScale)),
			layoutOrder = nextOrder(),
			scale = uiScale,
			truncate = true,
		})

		local nameField = Components.field({
			parent = panelScroll,
			name = "ProductName",
			text = product.name,
			placeholder = "Product name",
			maxLength = 32,
			layoutOrder = nextOrder(),
			scale = uiScale,
			onSubmit = function(value)
				if value ~= "" and value ~= product.name then
					task.spawn(function()
						Net.invoke("RenameProduct", { productId = product.id, name = value })
					end)
				end
			end,
		})

		if locked then
			-- A clear, non-blocking explanation beats greying controls with no reason.
			local notice = Components.frame({
				parent = panelScroll,
				name = "LockedNotice",
				size = UDim2.new(1, 0, 0, math.round(54 * uiScale)),
				color = Theme.color.surface,
				radius = Theme.radius.md,
				stroke = Theme.color.warning,
				layoutOrder = nextOrder(),
			})
			Components.padding(notice, Theme.space.md, uiScale)
			Components.text({
				parent = notice,
				text = "With the factory. You cannot change this design until the sample arrives.",
				variant = "small",
				color = Theme.color.warning,
				size = UDim2.fromScale(1, 1),
				wrap = true,
				scale = uiScale,
			})
		end

		-- ---- blank ----
		local blankOptions = {}
		for _, candidate in ipairs(Garments.blanksForType(product.productType)) do
			table.insert(blankOptions, {
				id = candidate.id,
				label = candidate.name,
				enabled = not locked,
			})
		end
		local blankOrder = nextOrder()
		optionRow({
			label = "Body",
			layoutOrder = blankOrder,
			options = blankOptions,
			selectedId = spec.blankId,
			columns = 1,
			onSelect = function(id)
				patchSpec({ blankId = id })
			end,
		})
		nextOrder()

		-- ---- fabric ----
		local fabricOptions = {}
		if blank then
			for _, fabricId in ipairs(blank.allowedFabricIds) do
				local candidate = Fabrics.get(fabricId)
				if candidate then
					table.insert(fabricOptions, {
						id = candidate.id,
						label = candidate.name,
						enabled = not locked,
					})
				end
			end
		end
		local fabricOrder = nextOrder()
		optionRow({
			label = "Fabric",
			layoutOrder = fabricOrder,
			options = fabricOptions,
			selectedId = spec.fabricId,
			columns = 1,
			onSelect = function(id)
				patchSpec({ fabricId = id })
			end,
		})
		nextOrder()

		-- ---- gsm ----
		local gsmOptions = {}
		if fabric then
			for _, weight in ipairs(fabric.allowedGsm) do
				table.insert(gsmOptions, {
					id = tostring(weight),
					label = tostring(weight),
					enabled = not locked,
				})
			end
		end
		local gsmOrder = nextOrder()
		optionRow({
			label = "Weight (gsm)",
			layoutOrder = gsmOrder,
			options = gsmOptions,
			selectedId = tostring(spec.gsm),
			columns = 4,
			onSelect = function(id)
				patchSpec({ gsm = tonumber(id) })
			end,
		})
		nextOrder()

		-- ---- colour ----
		local colourOptions = {}
		for _, colorway in ipairs(Garments.colorways) do
			table.insert(colourOptions, {
				id = colorway.id,
				label = colorway.name,
				swatch = colorway.color,
				enabled = not locked,
			})
		end
		local colourOrder = nextOrder()
		optionRow({
			label = "Colour",
			layoutOrder = colourOrder,
			options = colourOptions,
			selectedId = spec.colorId,
			columns = 3,
			onSelect = function(id)
				patchSpec({ colorId = id })
			end,
		})
		nextOrder()

		-- ---- graphic ----
		local currentGraphic = spec.graphics[1]

		local graphicOptions = { { id = "__none", label = "None", enabled = not locked } }
		for _, recipe in ipairs(GraphicsConfig.recipes) do
			table.insert(graphicOptions, {
				id = recipe.id,
				label = recipe.name,
				enabled = not locked,
			})
		end

		local colorway = Garments.getColorway(spec.colorId)
		local garmentIsDark = colorway and colorway.isDark or true

		local graphicOrder = nextOrder()
		optionRow({
			label = "Graphic",
			layoutOrder = graphicOrder,
			options = graphicOptions,
			selectedId = currentGraphic and currentGraphic.recipeId or "__none",
			columns = 2,
			onSelect = function(id)
				if id == "__none" then
					patchSpec({ graphics = {} })
					return
				end

				local recipe = GraphicsConfig.getRecipe(id)
				if not recipe then
					return
				end

				-- Preserve the player's existing choices where they still apply,
				-- so switching recipe does not silently reset placement and ink.
				local method = currentGraphic and currentGraphic.printMethodId or "dtf"
				local compatible = PrintMethods.isCompatible(method, spec.gsm)
				if not compatible then
					method = "dtf"
				end

				patchSpec({ graphics = { {
					recipeId = id,
					paletteId = currentGraphic and currentGraphic.paletteId
						or (if garmentIsDark then "white" else "black"),
					placement = currentGraphic and currentGraphic.placement or recipe.defaultPlacement,
					printMethodId = method,
					scale = recipe.defaultScale,
					rotation = 0,
					offsetX = 0,
					offsetY = 0,
				} } })
			end,
		})
		nextOrder()

		-- Graphic-dependent controls only appear when there IS a graphic.
		if currentGraphic then
			local function patchGraphic(changes: any)
				local layer = {
					recipeId = currentGraphic.recipeId,
					paletteId = currentGraphic.paletteId,
					placement = currentGraphic.placement,
					printMethodId = currentGraphic.printMethodId,
					scale = currentGraphic.scale,
					rotation = currentGraphic.rotation,
					offsetX = currentGraphic.offset.x,
					offsetY = currentGraphic.offset.y,
					text = currentGraphic.text,
					subtext = currentGraphic.subtext,
				}
				for key, value in pairs(changes) do
					layer[key] = value
				end
				patchSpec({ graphics = { layer } })
			end

			-- ---- placement ----
			local placementOptions = {}
			if blank then
				for _, placementId in ipairs(blank.allowedPlacements) do
					local panel = Garments.getPlacement(placementId)
					if panel and panel.face ~= "Sleeve" then
						table.insert(placementOptions, {
							id = placementId,
							label = panel.label,
							enabled = not locked,
						})
					end
				end
			end
			local placementOrder = nextOrder()
			optionRow({
				label = "Placement",
				layoutOrder = placementOrder,
				options = placementOptions,
				selectedId = currentGraphic.placement,
				columns = 2,
				onSelect = function(id)
					patchGraphic({ placement = id })
				end,
			})
			nextOrder()

			-- ---- ink ----
			local paletteOptions = {}
			for _, palette in ipairs(GraphicsConfig.palettes) do
				table.insert(paletteOptions, {
					id = palette.id,
					label = palette.name,
					swatch = palette.ink,
					enabled = not locked,
				})
			end
			local paletteOrder = nextOrder()
			optionRow({
				label = "Ink",
				layoutOrder = paletteOrder,
				options = paletteOptions,
				selectedId = currentGraphic.paletteId,
				columns = 3,
				onSelect = function(id)
					patchGraphic({ paletteId = id })
				end,
			})
			nextOrder()

			-- ---- print method ----
			--[[
				Incompatible methods are shown DISABLED with the reason, not hidden.
				The player should learn that puff print needs weight behind it,
				which they cannot do if the option silently disappears.
			]]
			local methodOptions = {}
			for _, method in ipairs(PrintMethods.list) do
				local compatible = PrintMethods.isCompatible(method.id, spec.gsm)
				table.insert(methodOptions, {
					id = method.id,
					label = method.shortName,
					enabled = compatible and not locked,
				})
			end
			local methodOrder = nextOrder()
			optionRow({
				label = "Print method",
				layoutOrder = methodOrder,
				options = methodOptions,
				selectedId = currentGraphic.printMethodId,
				columns = 3,
				onSelect = function(id)
					patchGraphic({ printMethodId = id })
				end,
			})
			nextOrder()

			local method = PrintMethods.get(currentGraphic.printMethodId)
			if method then
				Components.text({
					parent = panelScroll,
					text = method.description,
					variant = "small",
					color = Theme.color.textTertiary,
					size = UDim2.new(1, 0, 0, math.round(46 * uiScale)),
					wrap = true,
					layoutOrder = nextOrder(),
					scale = uiScale,
				})
			end

			-- ---- scale ----
			local scaleOptions = {}
			for _, preset in ipairs({
				{ id = "0.45", label = "Small" },
				{ id = "0.65", label = "Medium" },
				{ id = "0.85", label = "Large" },
				{ id = "1", label = "Max" },
			}) do
				table.insert(scaleOptions, {
					id = preset.id,
					label = preset.label,
					enabled = not locked,
				})
			end

			-- Match the stored scale to the nearest preset for selection display.
			local nearestPreset = "0.65"
			local smallestDelta = math.huge
			for _, option in ipairs(scaleOptions) do
				local delta = math.abs(tonumber(option.id) - currentGraphic.scale)
				if delta < smallestDelta then
					smallestDelta = delta
					nearestPreset = option.id
				end
			end

			local scaleOrder = nextOrder()
			optionRow({
				label = "Print size",
				layoutOrder = scaleOrder,
				options = scaleOptions,
				selectedId = nearestPreset,
				columns = 4,
				onSelect = function(id)
					patchGraphic({ scale = tonumber(id) })
				end,
			})
			nextOrder()
		end

		-- ---- send to suppliers ----
		Components.spacer(panelScroll, Theme.space.md, nextOrder(), uiScale)

		local canQuote = currentGraphic ~= nil and not locked
		Components.button({
			parent = panelScroll,
			text = "Get quotes \u{2192}",
			variant = "primary",
			size = UDim2.new(1, 0, 0, math.round(42 * uiScale)),
			layoutOrder = nextOrder(),
			scale = uiScale,
			enabled = canQuote,
			onClick = function()
				context.navigate("suppliers", { productId = product.id })
			end,
		})

		if not currentGraphic and not locked then
			Components.text({
				parent = panelScroll,
				text = "Add a graphic before sending this to a factory.",
				variant = "small",
				color = Theme.color.textTertiary,
				size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
				layoutOrder = nextOrder(),
				scale = uiScale,
			})
		end
	end

	-- ---------------------------------------------------------------- lifecycle
	local function refresh(state: any)
		if destroyed or not state then
			return
		end

		-- Default to the most recently created product so the app is never empty
		-- when one exists.
		if not selectedProductId or not state.products[selectedProductId] then
			for index = #state.productOrder, 1, -1 do
				local candidate = state.products[state.productOrder[index]]
				if candidate and candidate.stage ~= "Archived" then
					selectedProductId = candidate.id
					break
				end
			end
		end

		renderProductList(state)
		renderPanel()
	end

	-- If the app was opened with a product in mind, honour it.
	if context.params and context.params.productId then
		selectedProductId = context.params.productId
	end

	refresh(context.getState())

	return {
		destroy = function()
			destroyed = true
			if previewModel then
				previewModel:Destroy()
				previewModel = nil
			end
		end,
		onStateChanged = refresh,
		onParams = function(params)
			if params and params.productId then
				selectProduct(params.productId)
			end
		end,
	}
end

return DesignApp
