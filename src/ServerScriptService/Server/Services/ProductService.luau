--!strict
--[[
	ProductService

	Owns Product entities and the stage machine.

	== Spec validation is the whole job ==

	The client sends design INTENT -- which blank, which fabric, which graphic,
	where. Everything else is derived here from config. The server never accepts
	a cost, a quality, a stage, or a resolved colour from the client, because
	those are exactly the fields an exploiter would want to set.

	Validation is also layered. Validate/Protocol has already checked SHAPE (is
	this a string, is this number in 0..1). This service checks MEANING:

	  * does this blank exist, and is it the right product type
	  * is this fabric offered on this blank
	  * is this GSM one of the weights that fabric is knitted in
	  * is this print method physically compatible with that weight
	  * is this placement available on this blank
	  * are there too many graphics

	A shape-valid payload referencing a nonexistent fabric is still rejected.

	== Locking ==

	A product cannot be edited while a sample of it is in production. The sample
	already froze a snapshot, so editing would not corrupt it -- but allowing the
	design to drift while a factory is making it breaks the player's mental model
	of what they ordered. The lock is a design decision, not a technical one.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Types = require(Shared.Types)
local Enums = require(Shared.Enums)
local Garments = require(Shared.Config.Garments)
local Fabrics = require(Shared.Config.Fabrics)
local PrintMethods = require(Shared.Config.PrintMethods)
local GraphicsConfig = require(Shared.Config.Graphics)
local Styles = require(Shared.Config.Styles)
local Progression = require(Shared.Config.Progression)
local Net = require(Shared.Net.Net)
local Ids = require(Shared.Util.Ids)
local TableKit = require(Shared.Util.TableKit)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("Product")

local ProductService = {}
ProductService.__index = ProductService

type Product = Types.Product

local DEFAULT_PRODUCT_TYPE = "Tee"
local MAX_PRODUCTS = 40

function ProductService.new(profileService: any)
	local self = setmetatable({}, ProductService)
	self.profiles = profileService
	return self
end

function ProductService:Init() end
function ProductService:Start() end

-- ============================================================================
-- Lookup
-- ============================================================================

function ProductService:Get(player: Player, productId: string): Product?
	local state = self.profiles:GetState(player)
	if not state then
		return nil
	end
	return state.products[productId]
end

-- Editing is blocked while a sample is being made; see the header note.
function ProductService:IsLocked(product: Product): boolean
	local stage = product.stage
	return stage == Enums.ProductStage.SampleRequested
		or stage == Enums.ProductStage.SampleInProduction
		or stage == Enums.ProductStage.SampleShipped
end

-- ============================================================================
-- Creation
-- ============================================================================

function ProductService:CreateProduct(player: Player, payload: any)
	local state = self.profiles:GetState(player)
	if not state then
		return Net.fail("NoProfile", "Your profile is still loading.")
	end

	if not state.identity.created then
		return Net.fail("NoBrand", "Set up your brand before designing anything.")
	end

	if #state.productOrder >= MAX_PRODUCTS then
		return Net.fail("TooMany", "You have too many products. Archive some first.")
	end

	local productType = payload.productType or DEFAULT_PRODUCT_TYPE
	if #Garments.blanksForType(productType) == 0 then
		return Net.fail("UnknownType", "That product type does not exist yet.")
	end

	--[[
		Seed the spec from the brand's chosen aesthetic direction. This is why
		picking "Luxury" at setup means your first product opens as a Supima
		classic tee rather than a blank form -- the direction is a set of
		suggestions, and every one of them is still freely changeable.
	]]
	local style = Styles.getOrDefault(state.identity.styleId)
	local suggested = style.suggested

	local spec = Garments.defaultSpec(productType)
	if Garments.getBlank(suggested.blankId) then
		spec.blankId = suggested.blankId
		spec.fabricId = suggested.fabricId
		spec.gsm = suggested.gsm
		spec.colorId = suggested.colorId
	end

	local productId
	local created = self.profiles:Mutate(player, function(s)
		productId = Ids.next(s.counters, Ids.PRODUCT)
		local now = os.time()

		local product: Product = {
			id = productId,
			createdAt = now,
			updatedAt = now,
			name = payload.name ~= nil and payload.name ~= "" and payload.name
				or ("Untitled " .. productType),
			productType = productType,
			stage = Enums.ProductStage.Concept,
			revision = 1,
			spec = spec,
			history = { { stage = Enums.ProductStage.Concept, at = now } },
			sampleOrderIds = {},
			activeSampleOrderId = nil,
			approvedSampleOrderId = nil,
		}

		s.products[productId] = product
		table.insert(s.productOrder, productId)
		return true
	end)

	if not created then
		return Net.fail("CreateFailed", "Could not create that product.")
	end

	self.profiles:SetFlag(player, Progression.Flags.firstProductCreated)
	self.profiles:Increment(player, Progression.Counters.productsCreated)
	log:info("%s created %s", player.Name, productId)

	return Net.ok({ productId = productId })
end

function ProductService:RenameProduct(player: Player, payload: any)
	local product = self:Get(player, payload.productId)
	if not product then
		return Net.fail("NotFound", "That product does not exist.")
	end

	self.profiles:Mutate(player, function(s)
		local target = s.products[payload.productId]
		if not target then
			return false
		end
		target.name = payload.name
		target.updatedAt = os.time()
		return true
	end)

	return Net.ok()
end

-- ============================================================================
-- Spec validation
-- ============================================================================

--[[
	Validates a complete candidate spec against config.
	Returns ok plus a player-facing reason for the first problem found.
]]
function ProductService:ValidateSpec(spec: any, productType: string): (boolean, string?)
	local blank = Garments.getBlank(spec.blankId)
	if not blank then
		return false, "That blank does not exist."
	end
	if blank.productType ~= productType then
		return false, "That blank is not available for this product type."
	end

	if not Garments.getColorway(spec.colorId) then
		return false, "That colour is not available."
	end

	if not Fabrics.get(spec.fabricId) then
		return false, "That fabric does not exist."
	end
	if not Garments.isFabricAllowed(spec.blankId, spec.fabricId) then
		return false, string.format("%s is not offered in that fabric.", blank.name)
	end
	if not Fabrics.isGsmAllowed(spec.fabricId, spec.gsm) then
		return false, "That fabric is not knitted at that weight."
	end

	local graphics = spec.graphics or {}
	if #graphics > GraphicsConfig.MAX_PER_GARMENT then
		return false, string.format("A garment can carry at most %d graphics.", GraphicsConfig.MAX_PER_GARMENT)
	end

	local usedPlacements: { [string]: boolean } = {}
	for _, graphic in ipairs(graphics) do
		local recipe = GraphicsConfig.getRecipe(graphic.recipeId)
		if not recipe then
			return false, "That graphic does not exist."
		end
		if not GraphicsConfig.getPalette(graphic.paletteId) then
			return false, "That ink colour is not available."
		end
		if not Garments.isPlacementAllowed(spec.blankId, graphic.placement) then
			return false, string.format("%s cannot be printed there.", blank.name)
		end

		-- Two graphics on the same panel would overlap into nonsense.
		if usedPlacements[graphic.placement] then
			return false, "You already have a graphic in that position."
		end
		usedPlacements[graphic.placement] = true

		local method = PrintMethods.get(graphic.printMethodId)
		if not method then
			return false, "That print method does not exist."
		end
		local compatible, reason = PrintMethods.isCompatible(graphic.printMethodId, spec.gsm)
		if not compatible then
			return false, reason
		end
	end

	return true
end

-- ============================================================================
-- Spec update
-- ============================================================================

function ProductService:UpdateProductSpec(player: Player, payload: any)
	local product = self:Get(player, payload.productId)
	if not product then
		return Net.fail("NotFound", "That product does not exist.")
	end

	if self:IsLocked(product) then
		return Net.fail("Locked", "This design is with the factory. Wait for the sample to arrive.")
	end

	-- Build the candidate from a COPY, so a rejected update leaves the stored
	-- product completely untouched.
	local candidate = TableKit.deepCopy(product.spec)

	if payload.blankId ~= nil then
		candidate.blankId = payload.blankId

		--[[
			Changing the blank can invalidate the current fabric and placements
			(a boxy heavyweight tee does not offer the lightest blends). Rather
			than reject the change, fall back to that blank's default fabric and
			drop any now-illegal placements -- the player asked for a different
			body, not an error message.
		]]
		local blank = Garments.getBlank(payload.blankId)
		if blank then
			if not Garments.isFabricAllowed(payload.blankId, candidate.fabricId) then
				candidate.fabricId = blank.defaultFabricId
				local fabric = Fabrics.get(blank.defaultFabricId)
				candidate.gsm = fabric and fabric.defaultGsm or candidate.gsm
			end
			local kept = {}
			for _, graphic in ipairs(candidate.graphics) do
				if Garments.isPlacementAllowed(payload.blankId, graphic.placement) then
					table.insert(kept, graphic)
				end
			end
			candidate.graphics = kept
		end
	end

	if payload.colorId ~= nil then
		candidate.colorId = payload.colorId
	end

	if payload.fabricId ~= nil then
		candidate.fabricId = payload.fabricId
		-- Snap GSM to a weight this fabric is actually knitted in.
		if not Fabrics.isGsmAllowed(payload.fabricId, candidate.gsm) then
			local fabric = Fabrics.get(payload.fabricId)
			candidate.gsm = fabric and fabric.defaultGsm or candidate.gsm
		end
	end

	if payload.gsm ~= nil then
		candidate.gsm = payload.gsm
	end

	if payload.graphics ~= nil then
		local rebuilt = {}
		for _, layer in ipairs(payload.graphics) do
			local recipe = GraphicsConfig.getRecipe(layer.recipeId)
			if recipe then
				table.insert(rebuilt, {
					-- `kind` is taken from the recipe, never from the client.
					kind = recipe.kind,
					recipeId = layer.recipeId,
					paletteId = layer.paletteId,
					placement = layer.placement,
					printMethodId = layer.printMethodId,
					scale = layer.scale,
					rotation = layer.rotation,
					offset = { x = layer.offsetX, y = layer.offsetY },
					text = layer.text,
					subtext = layer.subtext,
				})
			end
		end
		candidate.graphics = rebuilt
	end

	local valid, reason = self:ValidateSpec(candidate, product.productType)
	if not valid then
		return Net.fail("InvalidSpec", reason)
	end

	local hasGraphics = #candidate.graphics > 0

	self.profiles:Mutate(player, function(s)
		local target = s.products[payload.productId]
		if not target then
			return false
		end

		target.spec = candidate
		target.updatedAt = os.time()

		-- A concept becomes a design the moment it carries artwork.
		if hasGraphics and target.stage == Enums.ProductStage.Concept then
			target.stage = Enums.ProductStage.Design
			table.insert(target.history, { stage = Enums.ProductStage.Design, at = os.time() })
		end
		return true
	end)

	if hasGraphics then
		self.profiles:SetFlag(player, Progression.Flags.firstProductDesigned)
	end

	return Net.ok({ spec = candidate })
end

function ProductService:ArchiveProduct(player: Player, payload: any)
	local product = self:Get(player, payload.productId)
	if not product then
		return Net.fail("NotFound", "That product does not exist.")
	end
	if self:IsLocked(product) then
		return Net.fail("Locked", "You cannot archive a product with a sample in production.")
	end

	self.profiles:Mutate(player, function(s)
		local target = s.products[payload.productId]
		if not target then
			return false
		end
		target.stage = Enums.ProductStage.Archived
		target.updatedAt = os.time()
		table.insert(target.history, { stage = Enums.ProductStage.Archived, at = os.time() })
		-- The id stays in productOrder; ids are never reused and history is kept.
		return true
	end)

	return Net.ok()
end

-- ============================================================================
-- Stage transitions
-- ============================================================================

--[[
	Legal stage transitions. Declared as data so an illegal move is impossible
	rather than merely unlikely, and so the lifecycle is readable in one place.
]]
local ALLOWED_TRANSITIONS: { [string]: { string } } = {
	[Enums.ProductStage.Concept] = { Enums.ProductStage.Design, Enums.ProductStage.Archived },
	[Enums.ProductStage.Design] = {
		Enums.ProductStage.Concept,
		Enums.ProductStage.TechPack,
		Enums.ProductStage.SampleRequested,
		Enums.ProductStage.Archived,
	},
	[Enums.ProductStage.TechPack] = { Enums.ProductStage.SampleRequested, Enums.ProductStage.Design },
	[Enums.ProductStage.SampleRequested] = { Enums.ProductStage.SampleInProduction },
	[Enums.ProductStage.SampleInProduction] = { Enums.ProductStage.SampleShipped },
	[Enums.ProductStage.SampleShipped] = { Enums.ProductStage.SampleReceived },
	[Enums.ProductStage.SampleReceived] = {
		Enums.ProductStage.SampleApproved,
		Enums.ProductStage.SampleRejected,
	},
	-- A rejected sample returns to Design so the player can revise and re-order.
	[Enums.ProductStage.SampleRejected] = { Enums.ProductStage.Design, Enums.ProductStage.SampleRequested },
	[Enums.ProductStage.SampleApproved] = { Enums.ProductStage.BulkProduction, Enums.ProductStage.Design },
	[Enums.ProductStage.BulkProduction] = { Enums.ProductStage.Inventory },
	[Enums.ProductStage.Inventory] = { Enums.ProductStage.Live, Enums.ProductStage.Archived },
	[Enums.ProductStage.Live] = { Enums.ProductStage.Archived, Enums.ProductStage.Inventory },
	[Enums.ProductStage.Archived] = {},
}

function ProductService:CanTransition(from: string, to: string): boolean
	local allowed = ALLOWED_TRANSITIONS[from]
	return allowed ~= nil and table.find(allowed, to) ~= nil
end

--[[
	Moves a product to a new stage. Server-internal; never reachable from a
	remote. An illegal transition is refused and logged rather than applied,
	because a product in an impossible stage would corrupt every later decision
	made about it.
]]
function ProductService:SetStage(player: Player, productId: string, stage: string, note: string?): boolean
	local product = self:Get(player, productId)
	if not product then
		return false
	end

	if product.stage == stage then
		return true
	end

	if not self:CanTransition(product.stage, stage) then
		log:error("illegal transition %s -> %s for %s", product.stage, stage, productId)
		return false
	end

	return self.profiles:Mutate(player, function(s)
		local target = s.products[productId]
		if not target then
			return false
		end
		target.stage = stage
		target.updatedAt = os.time()
		table.insert(target.history, { stage = stage, at = os.time(), note = note })
		return true
	end)
end

-- Bumps the revision when a sample is rejected, so the next sample is clearly
-- a different attempt at the same product rather than a repeat of the old one.
function ProductService:BumpRevision(player: Player, productId: string): number?
	local newRevision: number? = nil
	self.profiles:Mutate(player, function(s)
		local target = s.products[productId]
		if not target then
			return false
		end
		target.revision += 1
		target.updatedAt = os.time()
		newRevision = target.revision
		return true
	end)
	return newRevision
end

return ProductService
