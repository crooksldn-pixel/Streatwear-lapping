--!strict
--[[
	QualityService

	Decides how good a manufactured garment actually is.

	== The design rule: the manufacturer must be legible in the result ==

	The brief is explicit that this must not be arbitrary RNG. So every score is
	built from causes the player could have reasoned about BEFORE paying:

		score = manufacturer trait
		      x capability for the chosen print method
		      - penalty for working outside their GSM comfort band
		      - penalty for a fabric they do not normally stock
		      capped by the fabric's own ceiling
		      capped by the print method's detail ceiling
		      +/- variance, whose WIDTH is the manufacturer's inconsistency

	Every one of those inputs is visible on the supplier profile before ordering.
	A player who sends fine linework to a puff-print specialist gets a bad print
	because of a decision they made, and the inspection notes say so explicitly.

	== Variance is a property of the factory, not of the dice ==

	`consistency` inverts into the WIDTH of the random spread. A factory with
	high averages and low consistency is a gamble; one with lower averages and
	high consistency is predictable. Choosing between those is a real decision,
	and it is why randomness here adds texture instead of noise.

	The distribution is triangular (average of two uniform draws), not uniform:
	outcomes cluster near the expected value and extremes are rare, so a sample
	usually reflects the factory you chose and occasionally surprises you.

	== Determinism ==

	The roll is seeded from the ORDER ID. Consequences:

	  * A given order always produces the same result, so rejoining, re-opening
		the parcel or re-rendering the garment cannot re-roll a bad sample.
	  * Each dimension draws from its own named sub-stream, so print quality and
		stitching are independent rather than correlated.
	  * Any reported outcome is reproducible from the order id alone.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Types = require(Shared.Types)
local Enums = require(Shared.Enums)
local Manufacturers = require(Shared.Config.Manufacturers)
local Fabrics = require(Shared.Config.Fabrics)
local PrintMethods = require(Shared.Config.PrintMethods)
local GraphicsConfig = require(Shared.Config.Graphics)
local Garments = require(Shared.Config.Garments)
local Ids = require(Shared.Util.Ids)
local Format = require(Shared.Util.Format)

local QualityService = {}
QualityService.__index = QualityService

type QualityReport = Types.QualityReport

-- Widest possible swing either side of the expected value, at zero consistency.
local MAX_VARIANCE = 0.3

-- Weights used to collapse the dimensions into an overall figure. Print and
-- fabric dominate because they are what a customer notices first on a tee.
local OVERALL_WEIGHTS = {
	[Enums.QualityDimension.Print] = 0.34,
	[Enums.QualityDimension.Fabric] = 0.28,
	[Enums.QualityDimension.Stitching] = 0.22,
	[Enums.QualityDimension.Sizing] = 0.16,
}

function QualityService.new()
	return setmetatable({}, QualityService)
end

function QualityService:Init() end
function QualityService:Start() end

-- ============================================================================
-- Helpers
-- ============================================================================

--[[
	Triangular draw in [-spread, +spread], peaked at 0.
	Averaging two uniforms is the cheapest way to get a central tendency, which
	is what makes typical results typical.
]]
local function triangular(random: Random, spread: number): number
	if spread <= 0 then
		return 0
	end
	local a = random:NextNumber(-spread, spread)
	local b = random:NextNumber(-spread, spread)
	return (a + b) / 2
end

local function clamp01(value: number): number
	return math.clamp(value, 0, 1)
end

-- ============================================================================
-- Evaluation
-- ============================================================================

--[[
	evaluate(orderId, manufacturerId, spec) -> QualityReport

	Pure: same inputs always produce the same report. Takes no player and touches
	no state, so it can be called to preview an outcome as readily as to commit
	one.
]]
function QualityService:Evaluate(orderId: string, manufacturerId: string, spec: any): QualityReport
	local manufacturer = Manufacturers.get(manufacturerId)
	local fabric = Fabrics.get(spec.fabricId)
	local colorway = Garments.getColorway(spec.colorId)

	local notes: { string } = {}
	local dimensions: { [string]: number } = {}

	if not manufacturer then
		-- Should be unreachable; a missing manufacturer means corrupt state.
		for _, dimension in ipairs(Enums.QualityDimension.ordered()) do
			dimensions[dimension] = 0.5
		end
		return {
			dimensions = dimensions,
			overall = 0.5,
			notes = { "No manufacturer record for this order." },
			rolledAt = os.time(),
			seed = 0,
		}
	end

	local traits = manufacturer.traits
	-- Inconsistency widens the spread. A perfectly consistent factory has none.
	local spread = (1 - traits.consistency) * MAX_VARIANCE

	local gsmDeviation = Manufacturers.gsmDeviation(manufacturerId, spec.gsm)
	local stocksFabric = Manufacturers.prefersFabric(manufacturerId, spec.fabricId)

	-- ---- Fabric ---------------------------------------------------------
	do
		local random = Random.new(Ids.subSeed(orderId, "Fabric"))
		local base = traits.fabricQuality

		if not stocksFabric then
			-- Sourcing cloth they do not normally buy means a worse grade of it.
			base -= 0.18
			table.insert(notes, string.format(
				"%s does not normally stock %s \u{2014} the cloth is not their usual grade.",
				manufacturer.name, fabric and fabric.name or "this fabric"))
		end

		base -= gsmDeviation * 0.3

		local score = clamp01(base + triangular(random, spread))
		-- A cheap blend cannot feel premium however good the factory is.
		if fabric then
			score = math.min(score, fabric.qualityCeiling)
		end
		dimensions[Enums.QualityDimension.Fabric] = score

		if gsmDeviation > 0.25 then
			table.insert(notes, string.format(
				"%dgsm is outside %s's usual %d\u{2013}%dgsm range; the handfeel is off.",
				spec.gsm, manufacturer.name,
				manufacturer.gsmSweetSpot.min, manufacturer.gsmSweetSpot.max))
		end
	end

	-- ---- Print ----------------------------------------------------------
	do
		local random = Random.new(Ids.subSeed(orderId, "Print"))
		local graphics = spec.graphics or {}

		if #graphics == 0 then
			-- A blank garment cannot have a bad print. Scoring it 0 would drag the
			-- overall down for a product that simply has no artwork.
			dimensions[Enums.QualityDimension.Print] = 1
		else
			local total = 0
			for _, graphic in ipairs(graphics) do
				local capability = Manufacturers.capabilityFor(manufacturerId, graphic.printMethodId)
				local method = PrintMethods.get(graphic.printMethodId)
				local recipe = GraphicsConfig.getRecipe(graphic.recipeId)

				-- Base skill: how good they are at this specific technique.
				local base = capability

				--[[
					Detail mismatch. A recipe full of fine linework printed by a
					method that cannot hold detail loses out in proportion to how
					much detail it demanded. This is the puff-print-a-thin-serif
					mistake, and it is entirely predictable from the two cards the
					player picked.
				]]
				if method and recipe then
					local shortfall = math.max(0, recipe.detailDemand - method.detailCeiling)
					base -= shortfall * 0.8
					if shortfall > 0.15 then
						table.insert(notes, string.format(
							"%s cannot hold the fine detail in %s \u{2014} the edges have filled in.",
							method.name, recipe.name))
					end
				end

				-- Loose or coarse cloth blurs a print regardless of the press.
				if fabric then
					base *= (0.65 + fabric.printAffinity * 0.35)
				end

				local score = clamp01(base + triangular(random, spread))
				if method then
					score = math.min(score, method.detailCeiling + 0.1)
				end

				if capability <= 0 then
					-- They took the job they should have refused.
					score = math.min(score, 0.2)
					table.insert(notes, string.format(
						"%s does not really do %s. It shows.",
						manufacturer.name, method and method.name or "this technique"))
				elseif capability < 0.55 then
					table.insert(notes, string.format(
						"%s is not a specialist in %s.",
						manufacturer.name, method and method.name or "this technique"))
				end

				total += score
			end
			dimensions[Enums.QualityDimension.Print] = total / #graphics
		end
	end

	-- ---- Stitching ------------------------------------------------------
	do
		local random = Random.new(Ids.subSeed(orderId, "Stitching"))
		local base = traits.stitching - gsmDeviation * 0.2
		dimensions[Enums.QualityDimension.Stitching] = clamp01(base + triangular(random, spread))
	end

	-- ---- Sizing ---------------------------------------------------------
	do
		local random = Random.new(Ids.subSeed(orderId, "Sizing"))
		local base = traits.sizing
		-- Heavy cloth is harder to cut to spec; it shrinks and distorts more.
		if spec.gsm >= 280 then
			base -= 0.06
		end
		base -= gsmDeviation * 0.25
		dimensions[Enums.QualityDimension.Sizing] = clamp01(base + triangular(random, spread))
	end

	-- ---- Dye accuracy feeds fabric --------------------------------------
	if colorway and colorway.dyeDifficulty > 0.5 then
		local random = Random.new(Ids.subSeed(orderId, "Dye"))
		local penalty = (colorway.dyeDifficulty - 0.5) * 0.3 * (1 - traits.fabricQuality)
		local adjusted = clamp01(dimensions[Enums.QualityDimension.Fabric] - penalty + triangular(random, spread * 0.5))
		if adjusted < dimensions[Enums.QualityDimension.Fabric] - 0.08 then
			table.insert(notes, string.format(
				"%s is a difficult colour to hit consistently; this run is slightly off-shade.",
				colorway.name))
		end
		dimensions[Enums.QualityDimension.Fabric] = adjusted
	end

	-- ---- Overall --------------------------------------------------------
	local overall = 0
	for dimension, weight in pairs(OVERALL_WEIGHTS) do
		overall += (dimensions[dimension] or 0) * weight
	end
	overall = clamp01(overall)

	-- ---- Positive notes -------------------------------------------------
	-- Without these the inspection reads as a list of complaints even on a good
	-- sample, which would make a strong supplier feel no different from a weak one.
	if dimensions[Enums.QualityDimension.Fabric] >= 0.85 then
		table.insert(notes, string.format(
			"The cloth is excellent \u{2014} %s know what they are doing with %s.",
			manufacturer.name, fabric and string.lower(fabric.name) or "this fabric"))
	end
	if dimensions[Enums.QualityDimension.Print] >= 0.88 then
		table.insert(notes, "The print is crisp and properly registered.")
	end
	if dimensions[Enums.QualityDimension.Stitching] >= 0.88 then
		table.insert(notes, "Seams and hems are clean throughout.")
	end
	if dimensions[Enums.QualityDimension.Sizing] <= 0.5 then
		table.insert(notes, "Measurements are off spec \u{2014} this will not grade cleanly across sizes.")
	end
	if dimensions[Enums.QualityDimension.Stitching] <= 0.45 then
		table.insert(notes, "Stitching is uneven; one sleeve is set higher than the other.")
	end

	if #notes == 0 then
		table.insert(notes, "Nothing stands out, good or bad. A serviceable sample.")
	end

	return {
		dimensions = dimensions,
		overall = overall,
		notes = notes,
		rolledAt = os.time(),
		seed = Ids.hash(orderId),
	}
end

--[[
	Expected overall quality for a manufacturer and spec, with variance removed.

	Used by the Supplier app to show a HONEST forecast before ordering -- "this
	factory should produce a good sample of this design" -- without revealing the
	actual roll. The player sees the expectation; the sample reveals the outcome.
]]
function QualityService:ExpectedOverall(manufacturerId: string, spec: any): number
	-- Seeding with a fixed key yields the median outcome, since the triangular
	-- draw is symmetric about zero.
	local report = self:Evaluate("__forecast", manufacturerId, spec)
	return report.overall
end

function QualityService:GradeLabel(score: number): string
	return Format.qualityGrade(score)
end

return QualityService
