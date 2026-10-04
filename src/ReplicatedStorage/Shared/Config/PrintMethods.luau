--!strict
--[[
	Config.PrintMethods

	Decoration techniques. This is the table that makes manufacturer choice
	matter, because `Manufacturers.capabilities` scores each factory PER METHOD.
	A factory that is superb at screen printing can be poor at embroidery, so
	"which supplier" and "which print method" are a joint decision rather than
	two independent ones.

	Each method declares:

	  setupCostPence  one-off origination (screens to burn, a digitised
	                  embroidery file). Dominates the cost of a single sample --
	                  which is exactly why screen printing is uneconomic for one
	                  shirt and DTF is not.
	  unitCostPence   per-garment application cost.
	  detailCeiling   0..1 cap on achievable print quality regardless of factory
	                  skill. Puff print physically cannot hold fine linework.
	  durability      how the print survives wear; surfaces in inspection.
	  renderStyle     how GraphicRenderer should present it (raised, stitched,
	                  flat...). Presentation only -- never gameplay logic.
]]

export type PrintMethod = {
	id: string,
	name: string,
	shortName: string,
	description: string,

	setupCostPence: number,
	unitCostPence: number,

	detailCeiling: number,
	durability: number,

	-- Multiplier on production lead time.
	timeMultiplier: number,

	-- Some methods cannot be applied below/above certain fabric weights.
	minGsm: number?,
	maxGsm: number?,

	-- Number of distinct ink colours the method handles well. Screen printing
	-- charges per colour; digital methods are colour-agnostic.
	perColourCostPence: number,

	renderStyle: string, -- "flat" | "raised" | "stitched" | "patch" | "soft"
	tags: { string },
}

local PrintMethods = {}

PrintMethods.list = {
	{
		id = "dtf",
		name = "DTF Transfer",
		shortName = "DTF",
		description = "Direct-to-film transfer heat-pressed onto the garment. No setup, full colour, sits on top of the fabric.",
		setupCostPence = 0,
		unitCostPence = 320,
		detailCeiling = 0.86,
		durability = 0.62,
		timeMultiplier = 0.8,
		perColourCostPence = 0,
		renderStyle = "flat",
		tags = { "no-setup", "full-colour", "low-moq" },
	},
	{
		id = "screen",
		name = "Screen Print",
		shortName = "Screen",
		description = "Plastisol or water-based ink pushed through a mesh screen. One screen per colour. The industry standard at volume.",
		setupCostPence = 2200,
		unitCostPence = 85,
		detailCeiling = 0.95,
		durability = 0.9,
		timeMultiplier = 1.0,
		perColourCostPence = 1100,
		renderStyle = "flat",
		tags = { "volume", "durable", "setup-heavy" },
	},
	{
		id = "puff",
		name = "Puff Print",
		shortName = "Puff",
		description = "Screen print with a blowing agent that rises under heat. Bold and tactile, but swallows fine detail.",
		setupCostPence = 2600,
		unitCostPence = 140,
		detailCeiling = 0.58,
		durability = 0.74,
		timeMultiplier = 1.2,
		perColourCostPence = 1400,
		renderStyle = "raised",
		tags = { "tactile", "bold", "low-detail" },
	},
	{
		id = "embroidery",
		name = "Embroidery",
		shortName = "Embroidery",
		description = "Stitched directly into the fabric from a digitised file. Premium feel, poor at fine text and gradients.",
		setupCostPence = 3400,
		unitCostPence = 210,
		detailCeiling = 0.64,
		durability = 0.97,
		timeMultiplier = 1.45,
		minGsm = 180,
		perColourCostPence = 600,
		renderStyle = "stitched",
		tags = { "premium", "durable", "technical" },
	},
	{
		id = "applique",
		name = "Appliqu\u{00E9}",
		shortName = "Appliqu\u{00E9}",
		description = "Cut fabric panels stitched onto the garment, often edged with satin stitch. Heavy, expensive, unmistakably considered.",
		setupCostPence = 4200,
		unitCostPence = 380,
		detailCeiling = 0.55,
		durability = 0.93,
		timeMultiplier = 1.7,
		minGsm = 200,
		perColourCostPence = 900,
		renderStyle = "patch",
		tags = { "premium", "technical", "heavyweight-only" },
	},
	{
		id = "dtg",
		name = "DTG Print",
		shortName = "DTG",
		description = "Inkjet printed straight into the cotton fibres. Soft hand feel, unlimited colour, fades faster than screen.",
		setupCostPence = 0,
		unitCostPence = 260,
		detailCeiling = 0.9,
		durability = 0.5,
		timeMultiplier = 0.85,
		maxGsm = 300,
		perColourCostPence = 0,
		renderStyle = "soft",
		tags = { "no-setup", "full-colour", "soft-feel" },
	},
}

PrintMethods.byId = {} :: { [string]: PrintMethod }
for _, method in ipairs(PrintMethods.list) do
	PrintMethods.byId[method.id] = method
end

function PrintMethods.get(id: string): PrintMethod?
	return PrintMethods.byId[id]
end

--[[
	Whether a method can be applied to a fabric at a given weight.
	Returns false plus a reason the Design app can show inline, so the player
	learns the constraint rather than just finding the option greyed out.
]]
function PrintMethods.isCompatible(methodId: string, gsm: number): (boolean, string?)
	local method = PrintMethods.byId[methodId]
	if not method then
		return false, "Unknown print method"
	end
	if method.minGsm and gsm < method.minGsm then
		return false,
			string.format("%s needs at least %dgsm to hold its shape", method.name, method.minGsm)
	end
	if method.maxGsm and gsm > method.maxGsm then
		return false,
			string.format("%s cannot be applied above %dgsm", method.name, method.maxGsm)
	end
	return true
end

--[[
	Cost of decorating `quantity` garments with this method.

	Setup is charged ONCE across the run, which is what produces the real-world
	economics: a single screen-printed sample carries the whole £22 screen cost
	and is therefore absurd, while 200 units amortise it to pennies.
]]
function PrintMethods.costPence(methodId: string, quantity: number, colourCount: number): number
	local method = PrintMethods.byId[methodId]
	if not method then
		return 0
	end
	local colours = math.max(1, colourCount)
	local setup = method.setupCostPence + method.perColourCostPence * (colours - 1)
	local perUnit = method.unitCostPence * math.max(1, quantity)
	return math.floor(setup + perUnit + 0.5)
end

return PrintMethods
