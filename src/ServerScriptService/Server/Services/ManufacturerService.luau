--!strict
--[[
	ManufacturerService

	Quoting, supplier relationships, and simulated conversation.

	== Quoting is the honest-information layer ==

	A quote tells the player everything knowable BEFORE they commit money: the
	price, the lead time, whether this factory can even do what is being asked,
	and where the mismatches are. QualityService then decides the outcome using
	the same inputs.

	That pairing is what makes the simulation feel fair rather than random. If a
	quote warns "400gsm is outside our range" and the sample arrives with poor
	fabric, the player connects cause to effect. Hiding the warning and then
	punishing the choice would just feel arbitrary.

	== Cost model ==

		materials  fabric cost at the chosen weight + dye cost
		make       blank construction cost
		decoration print setup + per-unit, per placement multiplier
		           (setup DOMINATES a one-off sample, which is why screen
		            printing a single shirt is absurd and DTF is not)
		x margin   the manufacturer's unitCostMultiplier
		+ sample fee and shipping, which are flat per order

	Everything is integer pence throughout.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Types = require(Shared.Types)
local Manufacturers = require(Shared.Config.Manufacturers)
local Fabrics = require(Shared.Config.Fabrics)
local Garments = require(Shared.Config.Garments)
local PrintMethods = require(Shared.Config.PrintMethods)
local GraphicsConfig = require(Shared.Config.Graphics)
local Timings = require(Shared.Config.Timings)
local Progression = require(Shared.Config.Progression)
local Net = require(Shared.Net.Net)
local Format = require(Shared.Util.Format)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("Manufacturer")

local ManufacturerService = {}
ManufacturerService.__index = ManufacturerService

type Quote = Types.Quote

function ManufacturerService.new(profileService: any, productService: any, qualityService: any)
	local self = setmetatable({}, ManufacturerService)
	self.profiles = profileService
	self.products = productService
	self.quality = qualityService
	return self
end

function ManufacturerService:Init() end
function ManufacturerService:Start() end

-- ============================================================================
-- Relationships
-- ============================================================================

function ManufacturerService:EnsureRelationship(player: Player, manufacturerId: string)
	self.profiles:Mutate(player, function(state)
		if state.manufacturers[manufacturerId] then
			return false -- no change; skip replication
		end
		state.manufacturers[manufacturerId] = {
			discovered = true,
			ordersPlaced = 0,
			samplesApproved = 0,
			relationship = 0,
			lastContactAt = os.time(),
		}
		return true
	end)
end

-- ============================================================================
-- Costing
-- ============================================================================

--[[
	Per-garment production cost before the manufacturer's margin.
	Setup costs are passed back separately because they are charged once per run,
	not per unit -- that distinction is the whole economics of print methods.
]]
function ManufacturerService:ComputeUnitCost(spec: any, quantity: number): (number, number)
	local fabricCost = Fabrics.costPence(spec.fabricId, spec.gsm)

	local colorway = Garments.getColorway(spec.colorId)
	local dyeCost = colorway and colorway.dyeCostPence or 0

	local blank = Garments.getBlank(spec.blankId)
	local makeCost = blank and blank.baseMakeCostPence or 0

	local setupTotal = 0
	local decorationPerUnit = 0

	for _, graphic in ipairs(spec.graphics or {}) do
		local method = PrintMethods.get(graphic.printMethodId)
		local recipe = GraphicsConfig.getRecipe(graphic.recipeId)
		local placement = Garments.getPlacement(graphic.placement)

		if method then
			local colours = recipe and recipe.colourCount or 1
			local placementMultiplier = placement and placement.costMultiplier or 1

			setupTotal += method.setupCostPence + method.perColourCostPence * (colours - 1)
			decorationPerUnit += method.unitCostPence * placementMultiplier
		end
	end

	local perUnit = fabricCost + dyeCost + makeCost + decorationPerUnit
	return math.floor(perUnit + 0.5), math.floor(setupTotal + 0.5)
end

-- ============================================================================
-- Quoting
-- ============================================================================

function ManufacturerService:BuildQuote(productId: string, spec: any, manufacturerId: string): Quote?
	local manufacturer = Manufacturers.get(manufacturerId)
	if not manufacturer then
		return nil
	end

	local notes: { string } = {}
	local canFulfil = true
	local rejectionReason: string? = nil

	-- ---- capability checks ---------------------------------------------
	for _, graphic in ipairs(spec.graphics or {}) do
		local method = PrintMethods.get(graphic.printMethodId)
		local capability = Manufacturers.capabilityFor(manufacturerId, graphic.printMethodId)

		if capability <= 0 then
			-- A refusal, not a bad score. They will not take the job at all.
			canFulfil = false
			rejectionReason = string.format(
				"%s does not offer %s.",
				manufacturer.name, method and method.name or "that technique")
		elseif capability < 0.6 then
			table.insert(notes, string.format(
				"%s is not a specialist in %s \u{2014} expect compromises.",
				manufacturer.name, method and method.name or "this technique"))
		elseif capability >= 0.95 then
			table.insert(notes, string.format(
				"%s is among the best at %s.",
				manufacturer.name, method and method.name or "this technique"))
		end
	end

	-- ---- fit warnings ---------------------------------------------------
	local gsmDeviation = Manufacturers.gsmDeviation(manufacturerId, spec.gsm)
	if gsmDeviation > 0.05 then
		table.insert(notes, string.format(
			"%s works best between %dgsm and %dgsm; you have specified %dgsm.",
			manufacturer.name, manufacturer.gsmSweetSpot.min, manufacturer.gsmSweetSpot.max, spec.gsm))
	end

	if not Manufacturers.prefersFabric(manufacturerId, spec.fabricId) then
		local fabric = Fabrics.get(spec.fabricId)
		table.insert(notes, string.format(
			"They do not normally stock %s and would have to source it.",
			fabric and fabric.name or "this fabric"))
	end

	-- ---- cost -----------------------------------------------------------
	local perUnit, setupTotal = self:ComputeUnitCost(spec, 1)

	--[[
		A sample is ONE garment, so it carries the entire setup cost. That is
		real: a factory burning a screen for a single shirt charges for the
		screen. It is also what makes Print Lab's no-setup DTF the affordable
		first sample despite being the worst value at volume.
	]]
	local sampleProductionCost = math.floor((perUnit + setupTotal) * manufacturer.unitCostMultiplier + 0.5)
	local sampleCost = sampleProductionCost + manufacturer.sampleFeePence + manufacturer.shippingCostPence

	-- Indicative bulk unit cost at their MOQ, where setup amortises away.
	local bulkPerUnit = math.floor(
		(perUnit + setupTotal / math.max(1, manufacturer.moq)) * manufacturer.unitCostMultiplier + 0.5)

	-- ---- lead time ------------------------------------------------------
	local slowestMethodMultiplier = 1
	for _, graphic in ipairs(spec.graphics or {}) do
		local method = PrintMethods.get(graphic.printMethodId)
		if method then
			slowestMethodMultiplier = math.max(slowestMethodMultiplier, method.timeMultiplier)
		end
	end

	local productionSeconds = Timings.daysToSeconds(manufacturer.productionDays * slowestMethodMultiplier)
	local shippingSeconds = Timings.daysToSeconds(manufacturer.shippingDays)

	if manufacturer.moq > 1 then
		table.insert(notes, string.format(
			"Minimum bulk order is %d pieces at about %s each.",
			manufacturer.moq, Format.money(bulkPerUnit)))
	end

	return {
		manufacturerId = manufacturerId,
		productId = productId,
		sampleCostPence = sampleCost,
		unitCostPence = bulkPerUnit,
		moq = manufacturer.moq,
		productionSeconds = productionSeconds,
		shippingSeconds = shippingSeconds,
		capabilityNotes = notes,
		canFulfil = canFulfil,
		rejectionReason = rejectionReason,
	}
end

function ManufacturerService:GetQuote(player: Player, payload: any)
	local product = self.products:Get(player, payload.productId)
	if not product then
		return Net.fail("NotFound", "That product does not exist.")
	end

	if not Manufacturers.exists(payload.manufacturerId) then
		return Net.fail("UnknownManufacturer", "That supplier does not exist.")
	end

	local quote = self:BuildQuote(product.id, product.spec, payload.manufacturerId)
	if not quote then
		return Net.fail("QuoteFailed", "Could not price that.")
	end

	self:EnsureRelationship(player, payload.manufacturerId)
	self.profiles:SetFlag(player, Progression.Flags.firstSupplierViewed)

	-- An honest forecast of the expected result, without revealing the roll.
	local expected = self.quality:ExpectedOverall(payload.manufacturerId, product.spec)

	return Net.ok({
		quote = quote,
		expectedQuality = expected,
		expectedQualityLabel = Format.qualityGrade(expected),
	})
end

-- ============================================================================
-- Conversation
-- ============================================================================

--[[
	Simulated supplier messaging.

	Replies are composed from the manufacturer's own data, so a factory's answer
	is always consistent with how it actually behaves. `replyDelaySeconds` is
	surfaced to the client so a poor communicator visibly takes longer to come
	back -- which is what makes Noor's cheap pricing cost something real.
]]
function ManufacturerService:ContactSupplier(player: Player, payload: any)
	local manufacturer = Manufacturers.get(payload.manufacturerId)
	if not manufacturer then
		return Net.fail("UnknownManufacturer", "That supplier does not exist.")
	end

	self:EnsureRelationship(player, payload.manufacturerId)

	local product = nil
	if payload.productId then
		product = self.products:Get(player, payload.productId)
	end

	local reply: string
	local intent = payload.intent

	if intent == "Introduce" then
		reply = manufacturer.blurb
	elseif intent == "AskCapability" then
		local best: { string } = {}
		for methodId, capability in pairs(manufacturer.capabilities) do
			if capability >= 0.85 then
				local method = PrintMethods.get(methodId)
				if method then
					table.insert(best, method.name)
				end
			end
		end
		table.sort(best)
		reply = string.format(
			"We handle %s to a standard we are happy to put our name on. Minimum order is %d pieces.",
			#best > 0 and table.concat(best, ", ") or "basic decoration",
			manufacturer.moq)
	elseif intent == "AskLeadTime" then
		reply = string.format(
			"Sampling takes about %d working days once the artwork is approved, then %d days in transit to you.",
			manufacturer.productionDays, manufacturer.shippingDays)
	elseif intent == "AskPricing" then
		if product then
			local quote = self:BuildQuote(product.id, product.spec, payload.manufacturerId)
			if quote and quote.canFulfil then
				reply = string.format(
					"For that piece: %s for a sample delivered. At %d pieces we would be around %s each.",
					Format.money(quote.sampleCostPence), quote.moq, Format.money(quote.unitCostPence))
			elseif quote then
				reply = quote.rejectionReason or "We cannot make that piece, sorry."
			else
				reply = "Send the spec over and we will price it."
			end
		else
			reply = "Send a tech pack or a spec and we will come back with a number."
		end
	else
		reply = "Send the artwork and the spec and we will get a sample moving."
	end

	self.profiles:Mutate(player, function(state)
		local relationship = state.manufacturers[payload.manufacturerId]
		if relationship then
			relationship.lastContactAt = os.time()
		end
		return true
	end)

	return Net.ok({
		manufacturerId = payload.manufacturerId,
		contactName = manufacturer.contactName,
		reply = reply,
		-- The client uses this to stage a realistic typing delay.
		replyDelaySeconds = manufacturer.replyDelaySeconds * Timings.supplierReplyDelayScale,
	})
end

return ManufacturerService
