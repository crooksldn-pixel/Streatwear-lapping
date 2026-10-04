--!strict
--[[
	InspectionController

	The sample inspection: look at what the factory made, read the assessment,
	approve it or send it back.

	== Showing before telling ==

	The garment is rendered large, built from the order's frozen spec snapshot
	WITH the quality report applied, and it can be rotated. The defects are
	visible -- crooked sleeves, off-shade cloth, a misregistered print -- before
	the player reads a single score. The numbers confirm what they can already
	see, rather than substituting for it.

	The notes are written by QualityService in plain language and name the cause
	("Puff print cannot hold the fine detail in Collegiate Arch"), so a bad
	sample teaches the player something actionable instead of feeling arbitrary.

	== Approve or revise ==

	Requesting a revision bumps the product revision server-side and returns the
	product to Design. The architecture already records which revision each
	sample was made from, so multiple rounds work without further work here.
]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Manufacturers = require(Shared.Config.Manufacturers)
local Garments = require(Shared.Config.Garments)
local Fabrics = require(Shared.Config.Fabrics)
local PrintMethods = require(Shared.Config.PrintMethods)
local GraphicsConfig = require(Shared.Config.Graphics)
local Enums = require(Shared.Enums)
local GarmentBuilder = require(Shared.Garment.GarmentBuilder)
local Net = require(Shared.Net.Net)
local Ids = require(Shared.Util.Ids)
local Format = require(Shared.Util.Format)

local UI = script.Parent.Parent.UI
local Theme = require(UI.Theme)
local Components = require(UI.Components)

local InspectionController = {}
InspectionController.__index = InspectionController

function InspectionController.new(controllers: any)
	local self = setmetatable({}, InspectionController)
	self.controllers = controllers
	self.open = false
	self.orderId = nil :: string?
	self.garment = nil :: Model?
	self.scale = 1
	return self
end

function InspectionController:Init()
	self.scale = Theme.scale(workspace.CurrentCamera.ViewportSize)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "Inspection"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 15
	gui.Enabled = false
	gui.Parent = playerGui
	self.gui = gui
end

function InspectionController:Start()
	-- Q, not Escape: Escape is reserved by CoreGUI and never reaches game code.
	-- See the note in OSController.
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Q and self.open then
			self:Close()
		end
	end)
end

-- ============================================================================
-- Open
-- ============================================================================

function InspectionController:Open(orderId: string)
	if self.open then
		return
	end

	task.spawn(function()
		local response = Net.invoke("GetSampleReport", { orderId = orderId })
		if not response.ok then
			self.controllers.notifications:Push({
				title = response.message or "Could not open that sample",
				kind = "warning",
			})
			return
		end

		self.open = true
		self.orderId = orderId
		self.controllers.interactions:SetPromptsEnabled(false)
		self:Build(response.data)
	end)
end

function InspectionController:Build(report: any)
	local gui = self.gui :: ScreenGui
	gui:ClearAllChildren()
	gui.Enabled = true

	local uiScale = self.scale
	local spec = report.specSnapshot
	local quality = report.quality
	local manufacturer = Manufacturers.get(report.manufacturerId)

	local state = self.controllers.state:Get()
	local brandName = state and state.identity.name ~= "" and state.identity.name or "YOUR BRAND"
	local product = state and state.products[report.productId]

	-- ---- backdrop ----
	local scrim = Components.frame({
		name = "Scrim",
		parent = gui,
		size = UDim2.fromScale(1, 1),
		color = Theme.color.void,
		transparency = 1,
	})
	TweenService:Create(scrim, Theme.tweenInfo(Theme.motion.slow), {
		BackgroundTransparency = 0.08,
	}):Play()

	-- ---- garment viewport (left) ----
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "GarmentView"
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Size = UDim2.new(0.46, 0, 1, 0)
	-- Lifted so dark colourways keep their form; see the note in DesignApp.
	viewport.Ambient = Color3.fromRGB(192, 192, 200)
	viewport.LightColor = Color3.fromRGB(255, 251, 242)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.5)
	viewport.ZIndex = 2
	viewport.Parent = gui

	local world = Instance.new("WorldModel")
	world.Parent = viewport

	local viewportCamera = Instance.new("Camera")
	viewportCamera.Parent = viewport
	viewport.CurrentCamera = viewportCamera

	--[[
		The garment, with the real quality applied and seeded from the order id,
		so the defects match exactly what the parcel reveal showed and will be
		identical if this view is reopened.
	]]
	local garment, cameraCFrame = GarmentBuilder.buildForViewport(spec, {
		brandName = brandName,
		quality = quality and quality.dimensions or nil,
		seed = Ids.hash(report.orderId),
	})
	garment.Parent = world
	self.garment = garment

	local INSPECT_FOV = 40
	local finalCamera = cameraCFrame * CFrame.new(0, 0, 0.4)
	viewportCamera.CFrame = finalCamera
	viewportCamera.FieldOfView = INSPECT_FOV

	--[[
		The print, composited over the viewport.

		ViewportFrame does not render SurfaceGui content, so the graphic is drawn
		as a projected UI layer -- with the REAL print quality applied, so a
		misregistered or washed-out print is visible here exactly as it is on the
		physical garment. See the note in GarmentBuilder.
	]]
	local graphicOverlay = Components.frame({
		parent = gui,
		name = "GraphicOverlay",
		size = viewport.Size,
		position = viewport.Position,
		zIndex = 3,
	})

	local colorway = Garments.getColorway(spec.colorId)

	task.defer(function()
		if not self.open or not garment.Parent then
			return
		end
		GarmentBuilder.compositeViewportGraphics(
			graphicOverlay,
			garment,
			spec,
			finalCamera,
			INSPECT_FOV,
			{
				brandName = brandName,
				garmentColor = colorway and colorway.color or Color3.new(0, 0, 0),
				garmentIsDark = colorway and colorway.isDark or true,
				quality = quality and quality.dimensions and quality.dimensions.Print or nil,
				seed = Ids.hash(report.orderId),
			}
		)
	end)

	--[[
		The garment is NOT spun.

		An earlier version rotated it slowly to show the whole piece. That cannot
		work alongside the composited print: the overlay is a flat projection of a
		static pose, so a rotating garment would slide out from under its own
		graphic. A still, square-on presentation is also the better read for an
		inspection -- it is how a sample is actually photographed and checked.
	]]

	Components.text({
		parent = gui,
		name = "RotateHint",
		text = "Sample \u{2014} revision " .. tostring(report.productRevision),
		variant = "small",
		color = Theme.color.textTertiary,
		size = UDim2.new(0.46, 0, 0, math.round(20 * uiScale)),
		position = UDim2.new(0, 0, 1, -math.round(50 * uiScale)),
		align = Enum.TextXAlignment.Center,
		scale = uiScale,
		zIndex = 3,
	})

	-- ---- report panel (right) ----
	local panel = Components.frame({
		name = "Report",
		parent = gui,
		size = UDim2.new(0.42, 0, 0.86, 0),
		position = UDim2.new(0.5, 0, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		color = Theme.color.base,
		radius = Theme.radius.xl,
		stroke = Theme.color.border,
		zIndex = 3,
		clip = true,
	})

	local scroll = Components.scroll({ parent = panel, zIndex = 3 })
	Components.padding(scroll, Theme.space.xxl, uiScale)
	Components.list(scroll, { padding = Theme.space.md, scale = uiScale })

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	-- ---- header ----
	Components.text({
		parent = scroll,
		text = product and product.name or "Sample",
		variant = "title",
		size = UDim2.new(1, 0, 0, math.round(30 * uiScale)),
		layoutOrder = nextOrder(),
		scale = uiScale,
		truncate = true,
	})

	Components.text({
		parent = scroll,
		text = string.format(
			"Made by %s \u{2022} %s",
			manufacturer and manufacturer.name or "supplier",
			manufacturer and manufacturer.city or ""
		),
		variant = "small",
		color = Theme.color.textTertiary,
		size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
		layoutOrder = nextOrder(),
		scale = uiScale,
	})

	-- ---- overall verdict ----
	local overall = quality and quality.overall or 0

	local verdictPanel = Components.frame({
		parent = scroll,
		name = "Verdict",
		size = UDim2.new(1, 0, 0, math.round(72 * uiScale)),
		color = Theme.color.surface,
		radius = Theme.radius.lg,
		stroke = Theme.qualityColor(overall),
		layoutOrder = nextOrder(),
	})
	Components.padding(verdictPanel, Theme.space.lg, uiScale)

	Components.text({
		parent = verdictPanel,
		text = "OVERALL",
		variant = "micro",
		color = Theme.color.textTertiary,
		size = UDim2.new(1, 0, 0, math.round(14 * uiScale)),
		scale = uiScale,
	})

	Components.text({
		parent = verdictPanel,
		text = Format.qualityGrade(overall),
		variant = "title",
		color = Theme.qualityColor(overall),
		size = UDim2.new(1, 0, 0, math.round(28 * uiScale)),
		position = UDim2.fromOffset(0, math.round(18 * uiScale)),
		scale = uiScale,
	})

	Components.text({
		parent = verdictPanel,
		text = Format.percent(overall),
		variant = "title",
		color = Theme.color.textSecondary,
		size = UDim2.new(0, math.round(80 * uiScale), 1, 0),
		position = UDim2.new(1, -math.round(80 * uiScale), 0, 0),
		align = Enum.TextXAlignment.Right,
		data = true,
		scale = uiScale,
	})

	-- ---- dimensions ----
	Components.sectionHeader({
		parent = scroll,
		text = "Assessment",
		layoutOrder = nextOrder(),
		scale = uiScale,
	})

	local DIMENSION_LABELS = {
		[Enums.QualityDimension.Print] = "Print quality",
		[Enums.QualityDimension.Fabric] = "Fabric",
		[Enums.QualityDimension.Stitching] = "Stitching",
		[Enums.QualityDimension.Sizing] = "Sizing accuracy",
	}

	if quality then
		for index, dimension in ipairs(Enums.QualityDimension.ordered()) do
			local score = quality.dimensions[dimension] or 0
			Components.meter({
				parent = scroll,
				label = DIMENSION_LABELS[dimension] or dimension,
				value = score,
				caption = Format.qualityGrade(score),
				layoutOrder = nextOrder(),
				scale = uiScale,
				animate = true,
				-- Staggered so the report reads as a reveal.
				delay = 0.12 * index,
			})
		end
	end

	-- ---- notes ----
	if quality and #quality.notes > 0 then
		Components.sectionHeader({
			parent = scroll,
			text = "Notes",
			layoutOrder = nextOrder(),
			scale = uiScale,
		})

		local notesPanel = Components.frame({
			parent = scroll,
			name = "Notes",
			size = UDim2.new(1, 0, 0, 0),
			color = Theme.color.surface,
			radius = Theme.radius.lg,
			stroke = Theme.color.border,
			layoutOrder = nextOrder(),
			automaticSize = Enum.AutomaticSize.Y,
		})
		Components.padding(notesPanel, Theme.space.lg, uiScale)
		Components.list(notesPanel, { padding = Theme.space.sm, scale = uiScale })

		for index, note in ipairs(quality.notes) do
			Components.text({
				parent = notesPanel,
				text = "\u{2022}  " .. note,
				variant = "small",
				color = Theme.color.textSecondary,
				size = UDim2.new(1, 0, 0, 0),
				automaticSize = Enum.AutomaticSize.Y,
				wrap = true,
				layoutOrder = index,
				scale = uiScale,
			})
		end
	end

	-- ---- spec sheet ----
	Components.sectionHeader({
		parent = scroll,
		text = "Specification",
		layoutOrder = nextOrder(),
		scale = uiScale,
	})

	local specPanel = Components.frame({
		parent = scroll,
		name = "Spec",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.color.surface,
		radius = Theme.radius.lg,
		stroke = Theme.color.border,
		layoutOrder = nextOrder(),
		automaticSize = Enum.AutomaticSize.Y,
	})
	Components.padding(specPanel, Theme.space.lg, uiScale)
	Components.list(specPanel, { padding = Theme.space.xs, scale = uiScale })

	local blank = Garments.getBlank(spec.blankId)
	local colorway = Garments.getColorway(spec.colorId)
	local fabric = Fabrics.get(spec.fabricId)
	local graphic = spec.graphics and spec.graphics[1]
	local method = graphic and PrintMethods.get(graphic.printMethodId)
	local recipe = graphic and GraphicsConfig.getRecipe(graphic.recipeId)

	local specRows = {
		{ "Body", blank and blank.name or "\u{2014}" },
		{ "Colour", colorway and colorway.name or "\u{2014}" },
		{ "Fabric", fabric and fabric.composition or "\u{2014}" },
		{ "Weight", Format.gsm(spec.gsm) },
		{ "Graphic", recipe and recipe.name or "None" },
		{ "Print method", method and method.name or "\u{2014}" },
		{ "Sample cost", Format.money(report.costPence) },
	}

	for index, row in ipairs(specRows) do
		Components.statRow({
			parent = specPanel,
			label = row[1],
			value = row[2],
			layoutOrder = index,
			scale = uiScale,
		})
	end

	-- ---- decision ----
	Components.spacer(scroll, Theme.space.md, nextOrder(), uiScale)

	local resolved = report.status == Enums.OrderStatus.Approved
		or report.status == Enums.OrderStatus.RevisionRequested

	if resolved then
		Components.text({
			parent = scroll,
			text = if report.status == Enums.OrderStatus.Approved
				then "You approved this sample."
				else "You sent this back for revision.",
			variant = "body",
			color = Theme.color.textSecondary,
			size = UDim2.new(1, 0, 0, math.round(22 * uiScale)),
			layoutOrder = nextOrder(),
			scale = uiScale,
		})
	else
		local actions = Components.frame({
			parent = scroll,
			name = "Actions",
			size = UDim2.new(1, 0, 0, math.round(44 * uiScale)),
			layoutOrder = nextOrder(),
		})
		Components.list(actions, {
			direction = Enum.FillDirection.Horizontal,
			padding = Theme.space.sm,
			scale = uiScale,
		})

		local approveButton, reviseButton

		local function resolve(decision: string)
			approveButton.setEnabled(false)
			reviseButton.setEnabled(false)

			task.spawn(function()
				local response = Net.invoke("ResolveSample", {
					orderId = report.orderId,
					decision = decision,
					note = "",
				})

				if response.ok then
					if decision == "Approve" then
						self.controllers.notifications:Push({
							title = "Sample approved",
							body = "This piece is ready to go into production.",
							kind = "positive",
						})
					else
						self.controllers.notifications:Push({
							title = "Revision requested",
							body = "Change the spec in Design and order another sample.",
							kind = "info",
						})
					end
					self:Close()
				else
					self.controllers.notifications:Push({
						title = response.message or "That did not work",
						kind = "warning",
					})
					approveButton.setEnabled(true)
					reviseButton.setEnabled(true)
				end
			end)
		end

		approveButton = Components.button({
			parent = actions,
			text = "Approve sample",
			variant = "primary",
			size = UDim2.new(0, math.round(170 * uiScale), 0, math.round(42 * uiScale)),
			layoutOrder = 1,
			scale = uiScale,
			onClick = function()
				resolve("Approve")
			end,
		})

		reviseButton = Components.button({
			parent = actions,
			text = "Request revision",
			variant = "secondary",
			size = UDim2.new(0, math.round(170 * uiScale), 0, math.round(42 * uiScale)),
			layoutOrder = 2,
			scale = uiScale,
			onClick = function()
				resolve("Revise")
			end,
		})
	end

	-- ---- close ----
	Components.button({
		parent = scroll,
		text = "Put it down",
		variant = "ghost",
		size = UDim2.new(0, math.round(130 * uiScale), 0, math.round(34 * uiScale)),
		layoutOrder = nextOrder(),
		scale = uiScale,
		onClick = function()
			self:Close()
		end,
	})
end

-- ============================================================================
-- Close
-- ============================================================================

function InspectionController:Close()
	if not self.open then
		return
	end
	self.open = false
	self.orderId = nil

	if self.garment then
		self.garment:Destroy()
		self.garment = nil
	end

	local gui = self.gui
	if gui then
		gui.Enabled = false
		gui:ClearAllChildren()
	end

	self.controllers.camera:Release()
	self.controllers.interactions:SetPromptsEnabled(true)
end

return InspectionController
