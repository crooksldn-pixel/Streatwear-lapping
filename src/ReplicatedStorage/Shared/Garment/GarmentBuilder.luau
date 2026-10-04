--!strict
--[[
	Shared.Garment.GarmentBuilder

	Builds a physical garment Model from a GarmentSpec.

	== The single construction path ==

	Every garment that exists anywhere in the game comes from here:

	  * the Design app's live preview (into a ViewportFrame)
	  * the sample inside a delivered parcel (into Workspace)
	  * the inspection view (into a ViewportFrame, close up)
	  * later: photography, product listings, inventory

	There is deliberately no second way to make a shirt. The sample a player
	receives is built from the order's frozen spec snapshot by this function, so
	it cannot diverge from what they designed.

	== Geometry ==

	The tee is built as a FLAT LAID-OUT garment -- body panel, two sleeves, a
	collar rib -- rather than a worn/draped one. Reasons:

	  * It is how a sample actually arrives: folded flat in a poly bag.
	  * A flat front face is a clean, undistorted surface for a SurfaceGui, so
		the graphic renders exactly as designed with no projection error.
	  * It avoids depending on Roblox's layered-clothing or Shirt texture
		pipeline, both of which would require uploaded image assets.

	The model is assembled around a PrimaryPart (the body) and welded, so callers
	can move it with one PivotTo and it holds together.

	== Quality is applied here, not baked into the spec ==

	`context.quality` degrades the PRESENTATION: fabric colour drifts, the hem
	sits crooked, sleeves mismatch. The spec is unchanged. A design preview omits
	quality and therefore always shows the intent; a manufactured sample includes
	it and shows what the factory actually produced.
]]

local Shared = script.Parent.Parent
local Garments = require(Shared.Config.Garments)
local Fabrics = require(Shared.Config.Fabrics)
local GraphicRenderer = require(script.Parent.GraphicRenderer)

local GarmentBuilder = {}

--[[
	Canvas pixels per stud of garment.

	Not a quality dial -- it sets how large the engine's hard 100px glyph ceiling
	is RELATIVE to the garment. At 384 px/stud a tee canvas is ~960px tall, so a
	capped glyph is only ~10% of the shirt and every print rendered small no
	matter what scale the player chose. At 200 the ceiling stops binding for
	realistic print sizes while the canvas stays dense enough to read crisply in
	the close-up inspection view.
]]
local CANVAS_RESOLUTION = 200

export type BuildContext = {
	brandName: string,

	-- Present only for manufactured garments. See the note above.
	quality: {
		Print: number?,
		Stitching: number?,
		Fabric: number?,
		Sizing: number?,
	}?,

	-- Deterministic flaw placement. Same seed, same defects, every time.
	seed: number?,

	-- Skips welds and collision for viewport use, where physics is pointless.
	forViewport: boolean?,
}

-- ============================================================================
-- Part helpers
-- ============================================================================

local function newPanel(name: string, size: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.Fabric
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Reflectance = 0
	return part
end

--[[
	Creates a SurfaceGui on one face of a part and returns it.

	CanvasSize is derived from the part's real dimensions so pixel density is
	constant across differently sized blanks -- a graphic on a boxy tee is not
	softer than the same graphic on a classic one.
]]
local function newFace(part: Part, face: Enum.NormalId, widthStuds: number, heightStuds: number): SurfaceGui
	local surface = Instance.new("SurfaceGui")
	surface.Name = tostring(face.Name) .. "Face"
	surface.Face = face
	surface.CanvasSize = Vector2.new(
		math.floor(widthStuds * CANVAS_RESOLUTION),
		math.floor(heightStuds * CANVAS_RESOLUTION)
	)
	surface.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	surface.AlwaysOnTop = false
	--[[
		Ink is rendered unlit.

		At LightInfluence = 1 the print is lit exactly like the fabric, which is
		physically correct and looked wrong in practice: a white graphic on a
		black tee went near-black whenever the front panel faced away from the
		sun, so the thing the player designed was unreadable from half the room.
		Intermediate values still lost it in interior shadow, which is where this
		game is played.

		The graphic IS the product here, so legibility outranks lighting
		realism. The fabric itself remains fully lit, so the garment still sits
		in the scene -- only the ink is exempt.
	]]
	surface.LightInfluence = 0
	surface.ZOffset = 0
	surface.Parent = part
	return surface
end

-- ============================================================================
-- Build
-- ============================================================================

--[[
	build(spec, context) -> Model

	The returned model is Anchored and parentless. The caller parents and
	positions it. PrimaryPart is the body panel.
]]
function GarmentBuilder.build(spec: any, context: BuildContext): Model
	local blank = Garments.getBlank(spec.blankId) or Garments.blanks[1]
	local colorway = Garments.getColorway(spec.colorId) or Garments.colorways[1]
	local fabric = Fabrics.get(spec.fabricId)

	local quality = context.quality
	local random = Random.new(context.seed or 0)

	-- ---- fabric colour -------------------------------------------------
	--[[
		Dye accuracy. A factory that dyes badly produces cloth that is visibly
		off the specified colour -- the single most noticeable sign of a cheap
		sample. Drift direction is seeded so it is consistent for this garment.
	]]
	local bodyColor = colorway.color
	local fabricQuality = quality and quality.Fabric or nil
	if fabricQuality and fabricQuality < 0.8 then
		local drift = (0.8 - fabricQuality) * 0.22
		bodyColor = Color3.new(
			math.clamp(bodyColor.R + random:NextNumber(-drift, drift), 0, 1),
			math.clamp(bodyColor.G + random:NextNumber(-drift, drift), 0, 1),
			math.clamp(bodyColor.B + random:NextNumber(-drift, drift), 0, 1)
		)
	end

	-- Heavier cloth reads denser and slightly less reflective.
	local dimensions = blank.dimensions
	local gsm = spec.gsm or (fabric and fabric.defaultGsm) or 200
	local thickness = math.clamp(dimensions.depth * (gsm / 240), 0.12, 0.6)

	-- ---- sizing accuracy -----------------------------------------------
	--[[
		A factory with poor sizing returns a garment that is simply the wrong
		size. This is a real, visible defect and it is why `Sizing` is a quality
		dimension rather than a cosmetic note.
	]]
	local widthScale, heightScale = 1, 1
	local sizingQuality = quality and quality.Sizing or nil
	if sizingQuality and sizingQuality < 0.9 then
		local tolerance = (0.9 - sizingQuality) * 0.14
		widthScale = 1 + random:NextNumber(-tolerance, tolerance)
		heightScale = 1 + random:NextNumber(-tolerance, tolerance)
	end

	local bodyWidth = dimensions.width * widthScale
	local bodyHeight = dimensions.height * heightScale

	local model = Instance.new("Model")
	model.Name = "Garment"

	-- ---- body ----------------------------------------------------------
	local body = newPanel("Body", Vector3.new(bodyWidth, bodyHeight, thickness), bodyColor)
	body.Parent = model
	model.PrimaryPart = body

	-- Front and back print faces.
	local frontFace = newFace(body, Enum.NormalId.Front, bodyWidth, bodyHeight)
	local backFace = newFace(body, Enum.NormalId.Back, bodyWidth, bodyHeight)

	-- ---- sleeves -------------------------------------------------------
	local sleeveLength = if blank.id == "tee_longsleeve" then bodyHeight * 0.62 else bodyWidth * 0.3
	local sleeveHeight = bodyHeight * 0.3

	for _, side in ipairs({ -1, 1 }) do
		local sleeve = newPanel(
			if side < 0 then "SleeveLeft" else "SleeveRight",
			Vector3.new(sleeveLength, sleeveHeight, thickness * 0.95),
			bodyColor
		)

		--[[
			Poor stitching shows as sleeves set on at inconsistent angles. Each
			sleeve draws its own offset, so a bad sample is visibly asymmetric
			rather than uniformly wrong.
		]]
		local droopDegrees = -12
		local stitchQuality = quality and quality.Stitching or nil
		if stitchQuality and stitchQuality < 0.85 then
			droopDegrees += random:NextNumber(-1, 1) * (0.85 - stitchQuality) * 26
		end

		sleeve.CFrame = body.CFrame
			* CFrame.new(side * (bodyWidth / 2 + sleeveLength / 2 * 0.92), bodyHeight * 0.26, 0)
			* CFrame.Angles(0, 0, math.rad(droopDegrees * side))
		sleeve.Parent = model
	end

	-- ---- collar --------------------------------------------------------
	local collarWidth = bodyWidth * 0.3
	local collar = newPanel(
		"Collar",
		Vector3.new(collarWidth, bodyHeight * 0.07, thickness * 1.5),
		bodyColor:Lerp(Color3.new(0, 0, 0), 0.12)
	)
	collar.CFrame = body.CFrame * CFrame.new(0, bodyHeight / 2 - bodyHeight * 0.03, 0)
	collar.Parent = model

	-- ---- neck label ----------------------------------------------------
	-- A small branded label inside the collar. Tiny detail, but it is the thing
	-- that makes a blank feel like the player's product rather than a blank.
	local label = newPanel(
		"NeckLabel",
		Vector3.new(collarWidth * 0.5, bodyHeight * 0.05, thickness * 0.4),
		if colorway.isDark then Color3.fromRGB(226, 223, 214) else Color3.fromRGB(32, 32, 34)
	)
	label.CFrame = body.CFrame
		* CFrame.new(0, bodyHeight / 2 - bodyHeight * 0.1, -thickness / 2 - 0.01)
	label.Parent = model

	local labelSurface = newFace(label, Enum.NormalId.Back, collarWidth * 0.5, bodyHeight * 0.05)
	local labelText = Instance.new("TextLabel")
	labelText.Size = UDim2.fromScale(1, 1)
	labelText.BackgroundTransparency = 1
	labelText.Text = string.upper(context.brandName)
	labelText.FontFace = GraphicRenderer.font(Enum.FontWeight.Bold)
	labelText.TextScaled = true
	labelText.RichText = false
	labelText.TextColor3 = if colorway.isDark then Color3.fromRGB(28, 28, 30) else Color3.fromRGB(232, 230, 224)
	labelText.Parent = labelSurface

	-- ---- graphics ------------------------------------------------------
	GarmentBuilder.applyGraphics(frontFace, backFace, spec, {
		brandName = context.brandName,
		garmentColor = bodyColor,
		garmentIsDark = colorway.isDark,
		quality = quality and quality.Print or nil,
		seed = context.seed,
	})

	-- ---- assembly ------------------------------------------------------
	if not context.forViewport then
		-- Weld everything to the body so the garment moves as one object.
		for _, descendant in ipairs(model:GetChildren()) do
			if descendant:IsA("BasePart") and descendant ~= body then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = body
				weld.Part1 = descendant
				weld.Parent = body
			end
		end
	end

	-- Spec provenance, readable from the instance. Useful for debugging a
	-- garment in the world without tracing back through state.
	model:SetAttribute("BlankId", spec.blankId)
	model:SetAttribute("ColorId", spec.colorId)
	model:SetAttribute("FabricId", spec.fabricId)
	model:SetAttribute("Gsm", gsm)

	return model
end

--[[
	Renders a spec's graphics onto prepared front/back surfaces.

	Split out from `build` because the Design app re-renders graphics constantly
	while the player drags a layer, and rebuilding the whole garment for every
	frame of a drag would be wasteful.
]]
function GarmentBuilder.applyGraphics(
	frontFace: SurfaceGui,
	backFace: SurfaceGui,
	spec: any,
	renderContext: GraphicRenderer.RenderContext
)
	frontFace:ClearAllChildren()
	backFace:ClearAllChildren()

	for index, graphic in ipairs(spec.graphics or {}) do
		local panel = Garments.getPlacement(graphic.placement)
		if panel then
			local surface = if panel.face == "Back" then backFace else frontFace

			--[[
				The panel rectangle comes from Config.Garments, so the design
				canvas and the physical garment place the graphic using the SAME
				geometry. This is what guarantees a left-chest hit lands on the
				left chest of the real sample.
			]]
			local region = Instance.new("Frame")
			region.Name = "Panel_" .. graphic.placement .. "_" .. index
			region.BackgroundTransparency = 1
			region.BorderSizePixel = 0
			region.AnchorPoint = Vector2.new(0.5, 0.5)
			region.Position = UDim2.fromScale(panel.centre.x, panel.centre.y)
			region.Size = UDim2.fromScale(panel.size.x, panel.size.y)
			region.ZIndex = index
			region.Parent = surface

			-- Sleeve placements have no dedicated surface in this geometry; they
			-- are accepted by the spec but not drawn. Declared here rather than
			-- silently skipped so the omission is visible in review.
			if panel.face ~= "Sleeve" then
				GraphicRenderer.render(region, graphic, renderContext)
			end
		end
	end
end

--[[
	Convenience: builds a garment ready to sit inside a ViewportFrame, framed by
	a camera that fits it. Returns the model and a suitable CFrame for the
	viewport camera.

	The model's PrimaryPart (the body) sits exactly at the origin, which is what
	makes `panelViewportRect` below able to project its panels analytically.
]]
function GarmentBuilder.buildForViewport(spec: any, context: BuildContext): (Model, CFrame)
	local viewportContext = table.clone(context)
	viewportContext.forViewport = true

	local model = GarmentBuilder.build(spec, viewportContext)
	model:PivotTo(CFrame.new(0, 0, 0))

	local _, size = model:GetBoundingBox()
	local extent = math.max(size.X, size.Y)
	-- 1.35 leaves a margin so the garment never touches the viewport edge.
	local distance = extent * 1.35

	return model, CFrame.new(Vector3.new(0, 0, distance), Vector3.new(0, 0, 0))
end

-- ============================================================================
-- Viewport graphic compositing
-- ============================================================================

--[[
	== Why this exists ==

	ViewportFrame DOES NOT RENDER SurfaceGui CONTENT. It draws parts, meshes and
	decals only. The engine still lays the SurfaceGui out -- its canvas and its
	labels report correct AbsoluteSize and TextBounds -- it simply never
	reaches the screen. Verified directly rather than assumed: a garment in the
	world shows its print, the identical model inside a ViewportFrame shows a
	blank shirt.

	That matters because the Design preview and the Inspection view are both
	ViewportFrames, and the print is the single most important thing in each.

	The fix keeps ONE renderer and one spec. The viewport draws the garment's
	three-dimensional form -- cut, colour, weight, how the sleeves hang -- and
	the graphic is composited as a flat UI layer positioned exactly over the
	front panel. GraphicRenderer already renders into any GuiObject, so the same
	function that prints the physical sample draws the preview.

	The projection is analytic rather than measured, which it can be because the
	body sits at the origin and the camera looks straight down -Z at it.
]]

--[[
	Projects a world point into 0..1 viewport coordinates for a given camera.
	Returns nil for points behind the camera.

	Roblox's Camera:WorldToViewportPoint only works for the Workspace camera, so
	a ViewportFrame's camera has to be projected by hand.
]]
local function projectPoint(
	cameraCFrame: CFrame,
	fieldOfView: number,
	aspect: number,
	worldPoint: Vector3
): Vector2?
	local view = cameraCFrame:PointToObjectSpace(worldPoint)
	-- The camera looks down its own -Z, so depth is the negated local Z.
	local depth = -view.Z
	if depth <= 0.01 then
		return nil
	end

	local halfHeight = math.tan(math.rad(fieldOfView) / 2) * depth
	local halfWidth = halfHeight * aspect

	return Vector2.new(
		(view.X / halfWidth + 1) / 2,
		(1 - view.Y / halfHeight) / 2
	)
end

--[[
	Where a placement panel lands on screen, as scale-based position and size
	for a Frame overlaid on the ViewportFrame.

	Returns nil when the panel is not on the front face or is off camera, so
	callers can simply skip drawing.
]]
function GarmentBuilder.panelViewportRect(
	model: Model,
	placementId: string,
	cameraCFrame: CFrame,
	fieldOfView: number,
	viewportSize: Vector2
): (UDim2?, UDim2?)
	local panel = Garments.getPlacement(placementId)
	local body = model.PrimaryPart
	if not panel or not body or viewportSize.Y <= 0 then
		return nil, nil
	end

	-- Only the front face is composited; the back is not visible from this camera.
	if panel.face ~= "Front" then
		return nil, nil
	end

	local aspect = viewportSize.X / viewportSize.Y
	local bodySize = body.Size

	-- Panel centre in body-local space. Normalised panel coordinates have their
	-- origin at the TOP-left of the face, so Y inverts.
	local centreX = (panel.centre.x - 0.5) * bodySize.X
	local centreY = (0.5 - panel.centre.y) * bodySize.Y
	-- Just in front of the face (NormalId.Front faces -Z).
	local faceZ = -(bodySize.Z / 2) - 0.01

	local halfW = panel.size.x * bodySize.X / 2
	local halfH = panel.size.y * bodySize.Y / 2

	local basis = body.CFrame
	local topLeft = projectPoint(cameraCFrame, fieldOfView, aspect,
		(basis * CFrame.new(centreX - halfW, centreY + halfH, faceZ)).Position)
	local bottomRight = projectPoint(cameraCFrame, fieldOfView, aspect,
		(basis * CFrame.new(centreX + halfW, centreY - halfH, faceZ)).Position)

	if not topLeft or not bottomRight then
		return nil, nil
	end

	return UDim2.fromScale(topLeft.X, topLeft.Y),
		UDim2.fromScale(bottomRight.X - topLeft.X, bottomRight.Y - topLeft.Y)
end

--[[
	Draws a spec's front-face graphics as a UI layer over a ViewportFrame.

	`overlay` is a Frame sized to the viewport. Existing children are cleared, so
	this can be called repeatedly as the design changes.
]]
function GarmentBuilder.compositeViewportGraphics(
	overlay: GuiObject,
	model: Model,
	spec: any,
	cameraCFrame: CFrame,
	fieldOfView: number,
	renderContext: GraphicRenderer.RenderContext
)
	overlay:ClearAllChildren()

	local viewportSize = overlay.AbsoluteSize
	if viewportSize.X <= 0 or viewportSize.Y <= 0 then
		return
	end

	for index, graphic in ipairs(spec.graphics or {}) do
		local position, size = GarmentBuilder.panelViewportRect(
			model, graphic.placement, cameraCFrame, fieldOfView, viewportSize)

		if position and size then
			local region = Instance.new("Frame")
			region.Name = "CompositePanel_" .. index
			region.BackgroundTransparency = 1
			region.BorderSizePixel = 0
			region.Position = position
			region.Size = size
			region.ZIndex = overlay.ZIndex + index
			region.Parent = overlay

			-- The SAME renderer that prints the physical garment.
			GraphicRenderer.render(region, graphic, renderContext)
		end
	end
end

--[[
	Distinct ink colours used by a spec, for per-colour screen printing cost.
	A recipe declares how many inks it needs; two layers sharing a palette share
	screens, so the count is over distinct palettes rather than layers.
]]
function GarmentBuilder.countColours(spec: any): number
	local Graphics = require(Shared.Config.Graphics)
	local palettes: { [string]: boolean } = {}
	local total = 0

	for _, graphic in ipairs(spec.graphics or {}) do
		if not palettes[graphic.paletteId] then
			palettes[graphic.paletteId] = true
			local recipe = Graphics.getRecipe(graphic.recipeId)
			total += if recipe then recipe.colourCount else 1
		end
	end

	return math.max(1, total)
end

GarmentBuilder.CANVAS_RESOLUTION = CANVAS_RESOLUTION

return GarmentBuilder
