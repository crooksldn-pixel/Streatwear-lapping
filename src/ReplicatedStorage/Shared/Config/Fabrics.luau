--!strict
--[[
	Config.Fabrics

	Fabric compositions and their legal GSM ranges.

	GSM (grams per square metre) is the weight of the knit and is the single most
	meaningful spec decision on a blank tee -- it is what separates a flimsy
	promotional shirt from a heavyweight boxy one. It is modelled properly
	because it drives three things at once:

	  * cost (more cotton costs more)
	  * which manufacturers can make it well (see Manufacturers.gsmSweetSpot)
	  * how the garment reads during inspection

	`costMultiplier` is applied per-GSM-step above the fabric's base weight, so
	asking a factory for 400gsm genuinely costs more than 180gsm.
]]

export type Fabric = {
	id: string,
	name: string,
	composition: string,
	description: string,

	allowedGsm: { number },
	defaultGsm: number,

	-- Pence per garment at the fabric's lightest allowed weight.
	baseCostPence: number,
	-- Added pence per 10gsm above the lightest weight.
	costPer10GsmPence: number,

	-- 0..1 ceiling this fabric imposes on achievable fabric quality. A cheap
	-- blend cannot feel premium no matter how good the factory is.
	qualityCeiling: number,

	-- How well graphics sit on it. Loose knits blur fine detail.
	printAffinity: number,

	tags: { string },
}

local Fabrics = {}

Fabrics.list = {
	{
		id = "cotton_carded",
		name = "Carded Cotton",
		composition = "100% carded cotton",
		description = "Standard open-end cotton. Honest, cheap, slightly coarse hand feel.",
		allowedGsm = { 150, 160, 180, 200 },
		defaultGsm = 180,
		baseCostPence = 180,
		costPer10GsmPence = 9,
		qualityCeiling = 0.62,
		printAffinity = 0.72,
		tags = { "budget", "lightweight" },
	},
	{
		id = "cotton_combed",
		name = "Combed Cotton",
		composition = "100% combed ringspun cotton",
		description = "Combed to remove short fibres. Smoother surface, takes print cleanly.",
		allowedGsm = { 180, 200, 220, 240 },
		defaultGsm = 200,
		baseCostPence = 280,
		costPer10GsmPence = 14,
		qualityCeiling = 0.84,
		printAffinity = 0.94,
		tags = { "versatile", "print" },
	},
	{
		id = "cotton_heavy",
		name = "Heavyweight Cotton",
		composition = "100% combed cotton, heavy knit",
		description = "Dense, structured, holds a boxy shape. The streetwear default.",
		allowedGsm = { 240, 260, 280, 300, 320 },
		defaultGsm = 280,
		baseCostPence = 430,
		costPer10GsmPence = 20,
		qualityCeiling = 0.93,
		printAffinity = 0.88,
		tags = { "streetwear", "heavyweight", "structured" },
	},
	{
		id = "cotton_supima",
		name = "Supima Cotton",
		composition = "100% Supima extra-long staple cotton",
		description = "Long-staple cotton with a soft, faintly lustrous finish. Expensive.",
		allowedGsm = { 200, 220, 240, 260 },
		defaultGsm = 220,
		baseCostPence = 690,
		costPer10GsmPence = 30,
		qualityCeiling = 1.0,
		printAffinity = 0.9,
		tags = { "premium", "luxury" },
	},
	{
		id = "cotton_poly",
		name = "Cotton / Poly Blend",
		composition = "60% cotton / 40% polyester",
		description = "Cheap and hard-wearing. Resists creasing, feels synthetic.",
		allowedGsm = { 150, 160, 180, 200 },
		defaultGsm = 160,
		baseCostPence = 140,
		costPer10GsmPence = 6,
		qualityCeiling = 0.5,
		printAffinity = 0.66,
		tags = { "budget", "durable" },
	},
}

-- Keyed index, built once.
Fabrics.byId = {} :: { [string]: Fabric }
for _, fabric in ipairs(Fabrics.list) do
	Fabrics.byId[fabric.id] = fabric
end

function Fabrics.get(id: string): Fabric?
	return Fabrics.byId[id]
end

function Fabrics.isGsmAllowed(fabricId: string, gsm: number): boolean
	local fabric = Fabrics.byId[fabricId]
	if not fabric then
		return false
	end
	return table.find(fabric.allowedGsm, gsm) ~= nil
end

-- Material cost of one garment in this fabric at this weight.
function Fabrics.costPence(fabricId: string, gsm: number): number
	local fabric = Fabrics.byId[fabricId]
	if not fabric then
		return 0
	end
	local lightest = fabric.allowedGsm[1]
	local steps = math.max(0, (gsm - lightest) / 10)
	return math.floor(fabric.baseCostPence + steps * fabric.costPer10GsmPence + 0.5)
end

return Fabrics
