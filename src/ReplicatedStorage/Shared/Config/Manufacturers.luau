--!strict
--[[
	Config.Manufacturers

	Fictional suppliers.

	== Design rule: no manufacturer is strictly better than another ==

	Every factory here wins on at least one axis and loses on at least one. There
	is no dominant choice and no "trap" choice, so the decision is about fit --
	what this product needs, what the player can afford today, how long they are
	willing to wait.

	The axes in tension:

	  cost        sample fee and unit price
	  speed       production days + shipping days
	  capability  per-print-method skill (see `capabilities`)
	  quality     trait scores and their consistency
	  commitment  MOQ -- cheap unit prices behind a 100-piece minimum are no use
	              to someone with £400
	  comms       reply latency, which makes a cheap factory genuinely annoying

	Print Lab Manchester exists as a viable FIRST choice (MOQ 1, instant, no
	setup) without being the best: its blanks are mediocre and it only does DTF,
	so a player who uses it learns what a weak sample looks like. That is
	intentional onboarding -- affordable, not correct.

	== Trait semantics ==

	All traits are 0..1.

	  fabricQuality  how well they source/handle blanks
	  stitching      construction standard
	  sizing         how close the finished garment is to the spec measurements
	  consistency    INVERTED VARIANCE. High consistency = narrow spread around
	                 the expected result. A factory with high averages and low
	                 consistency is a gamble; one with lower averages and high
	                 consistency is predictable. This is what stops quality from
	                 feeling like arbitrary RNG -- the spread itself is a
	                 property of who you chose.
	  communication  drives simulated reply delay

	`capabilities[methodId]` is a MULTIPLIER on print quality for that method,
	not an absolute score. 1.0 means "as good as this factory gets"; 0.35 means
	they will technically do it and you will regret asking. A method absent from
	the table is one they refuse outright.
]]

export type ShippingBand = "Domestic" | "Regional" | "International" | "LongHaul"

export type Manufacturer = {
	id: string,
	name: string,
	city: string,
	country: string,
	countryCode: string,

	tagline: string,
	description: string,
	-- Shown on the supplier profile as a human would describe themselves.
	blurb: string,
	contactName: string,

	traits: {
		fabricQuality: number,
		stitching: number,
		sizing: number,
		consistency: number,
		communication: number,
	},

	capabilities: { [string]: number },

	-- Fabrics they stock well. Working outside this list carries a penalty.
	preferredFabricIds: { string },
	-- The GSM band they are set up for; outside it, quality suffers.
	gsmSweetSpot: { min: number, max: number },

	sampleFeePence: number,
	-- Multiplier applied to computed material + decoration cost for bulk unit price.
	unitCostMultiplier: number,
	moq: number,

	productionDays: number,
	shippingDays: number,
	shippingBand: ShippingBand,
	shippingCostPence: number,

	-- Seconds of simulated delay before they reply in a conversation.
	replyDelaySeconds: number,

	-- Surfaced verbatim on the profile so tradeoffs are legible BEFORE paying.
	strengths: { string },
	weaknesses: { string },

	-- Unlock gating. All four are available from the start in the slice.
	requiresBrandStage: string?,
}

local Manufacturers = {}

Manufacturers.list = {
	-- ------------------------------------------------------------------
	-- UK / local. Instant and tiny-MOQ, but mediocre and expensive per unit.
	-- The natural first sample. Not the best one.
	-- ------------------------------------------------------------------
	{
		id = "printlab_mcr",
		name = "Print Lab Manchester",
		city = "Manchester",
		country = "United Kingdom",
		countryCode = "GB",
		tagline = "Small-run DTF, next-day",
		description = "A two-room print shop working off bought-in blanks. No minimums, no setup, no frills.",
		blurb = "We'll run one piece or a hundred, same price per shirt. We don't do screens, we don't do stitch work, and we don't pretend our blanks are premium \u{2014} they're whatever the wholesaler had. If you need something on a body this week, we're your shop.",
		contactName = "Dale",
		traits = {
			fabricQuality = 0.42,
			stitching = 0.48,
			sizing = 0.61,
			consistency = 0.74,
			communication = 0.93,
		},
		capabilities = {
			dtf = 0.95,
			dtg = 0.6,
		},
		preferredFabricIds = { "cotton_poly", "cotton_carded" },
		gsmSweetSpot = { min = 150, max = 200 },
		sampleFeePence = 1400,
		unitCostMultiplier = 1.95,
		moq = 1,
		productionDays = 1,
		shippingDays = 1,
		shippingBand = "Domestic",
		shippingCostPence = 490,
		replyDelaySeconds = 2,
		strengths = { "No minimum order", "Fast turnaround", "Replies immediately" },
		weaknesses = { "Low-grade blanks", "DTF only", "Poor value at volume" },
	},

	-- ------------------------------------------------------------------
	-- Pakistan. Best heavyweight cotton and screen print for the money.
	-- Slow to reply, slow to ship, weak on technical decoration.
	-- ------------------------------------------------------------------
	{
		id = "noor_textiles",
		name = "Noor Textiles",
		city = "Faisalabad",
		country = "Pakistan",
		countryCode = "PK",
		tagline = "Heavyweight knits, screen print specialists",
		description = "Family-run mill with its own knitting and dyeing. Exceptional heavy cotton at a price nobody in Europe can match.",
		blurb = "We knit our own cloth, so when you ask for 280gsm you get 280gsm. Screen printing is what we are known for \u{2014} we have run the same presses for twenty years. We do not do embroidery to a standard we would put our name on, and we will tell you that rather than take your money.",
		contactName = "Imran",
		traits = {
			fabricQuality = 0.91,
			stitching = 0.78,
			sizing = 0.72,
			consistency = 0.79,
			communication = 0.38,
		},
		capabilities = {
			screen = 1.0,
			puff = 0.82,
			dtf = 0.58,
			embroidery = 0.34,
			dtg = 0.3,
		},
		preferredFabricIds = { "cotton_carded", "cotton_combed", "cotton_heavy" },
		gsmSweetSpot = { min = 220, max = 340 },
		sampleFeePence = 2600,
		unitCostMultiplier = 1.08,
		moq = 50,
		productionDays = 7,
		shippingDays = 11,
		shippingBand = "LongHaul",
		shippingCostPence = 1850,
		replyDelaySeconds = 14,
		strengths = { "Outstanding heavyweight cotton", "Best-in-class screen print", "Very low unit cost" },
		weaknesses = { "Slow to reply", "Long shipping", "Weak embroidery" },
	},

	-- ------------------------------------------------------------------
	-- Turkey. High all-round quality, fast, low-ish MOQ -- and expensive.
	-- Struggles above ~260gsm.
	-- ------------------------------------------------------------------
	{
		id = "atlas_konfeksiyon",
		name = "Atlas Konfeksiyon",
		city = "Istanbul",
		country = "T\u{00FC}rkiye",
		countryCode = "TR",
		tagline = "Premium mid-weight, quick turnaround",
		description = "Mid-size factory supplying European labels. Meticulous finishing and short lead times, at European prices.",
		blurb = "Our clients are labels that get returned if a collar is twisted, so we do not send those out. Two weeks door to door, properly packed, properly measured. We are not the cheapest and we are not trying to be. Above 260gsm you want a mill that knits heavy cloth \u{2014} that is not us.",
		contactName = "Sibel",
		traits = {
			fabricQuality = 0.86,
			stitching = 0.94,
			sizing = 0.91,
			consistency = 0.92,
			communication = 0.84,
		},
		capabilities = {
			screen = 0.9,
			dtf = 0.84,
			dtg = 0.8,
			embroidery = 0.86,
			puff = 0.78,
			applique = 0.72,
		},
		preferredFabricIds = { "cotton_combed", "cotton_supima" },
		gsmSweetSpot = { min = 180, max = 260 },
		sampleFeePence = 4800,
		unitCostMultiplier = 1.72,
		moq = 30,
		productionDays = 4,
		shippingDays = 4,
		shippingBand = "Regional",
		shippingCostPence = 1150,
		replyDelaySeconds = 5,
		strengths = { "Excellent finishing", "Highly consistent", "Fast for an overseas mill" },
		weaknesses = { "High sample fee", "Expensive per unit", "Not suited to heavy knits" },
	},

	-- ------------------------------------------------------------------
	-- China. The only route to real technical decoration. High MOQ, and the
	-- sample fee is steep because they are set up for volume, not one-offs.
	-- ------------------------------------------------------------------
	{
		id = "yuecheng_apparel",
		name = "Yuecheng Apparel",
		city = "Guangzhou",
		country = "China",
		countryCode = "CN",
		tagline = "Technical decoration, cut-and-sew, scale",
		description = "Large vertically integrated plant. Embroidery, appliqu\u{00E9}, puff and full cut-and-sew under one roof.",
		blurb = "Whatever construction you have drawn, we can make it \u{2014} embroidery, appliqu\u{00E9}, panelled cut-and-sew, custom trims. Our minimum is one hundred pieces because our lines are built for production, and a single sample costs us a line changeover, which is why the sample fee is what it is. Once you are ordering properly, nobody will beat us.",
		contactName = "Wei",
		traits = {
			fabricQuality = 0.8,
			stitching = 0.88,
			sizing = 0.83,
			consistency = 0.85,
			communication = 0.69,
		},
		capabilities = {
			embroidery = 1.0,
			applique = 0.98,
			puff = 0.94,
			screen = 0.87,
			dtf = 0.81,
			dtg = 0.74,
		},
		preferredFabricIds = { "cotton_combed", "cotton_heavy", "cotton_poly", "cotton_supima" },
		gsmSweetSpot = { min = 180, max = 320 },
		sampleFeePence = 5400,
		unitCostMultiplier = 1.0,
		moq = 100,
		productionDays = 5,
		shippingDays = 8,
		shippingBand = "International",
		shippingCostPence = 1480,
		replyDelaySeconds = 8,
		strengths = { "Unmatched technical decoration", "Cheapest at volume", "Handles any construction" },
		weaknesses = { "100-piece minimum", "Highest sample fee", "Built for scale, not one-offs" },
	},
}

Manufacturers.byId = {} :: { [string]: Manufacturer }
for _, manufacturer in ipairs(Manufacturers.list) do
	Manufacturers.byId[manufacturer.id] = manufacturer
end

function Manufacturers.get(id: string): Manufacturer?
	return Manufacturers.byId[id]
end

function Manufacturers.exists(id: unknown): boolean
	return typeof(id) == "string" and Manufacturers.byId[id :: string] ~= nil
end

function Manufacturers.all(): { Manufacturer }
	return Manufacturers.list
end

-- 0 means "will not do it". Callers must treat 0 as a refusal, not a bad score.
function Manufacturers.capabilityFor(manufacturerId: string, printMethodId: string): number
	local manufacturer = Manufacturers.byId[manufacturerId]
	if not manufacturer then
		return 0
	end
	return manufacturer.capabilities[printMethodId] or 0
end

function Manufacturers.canPrint(manufacturerId: string, printMethodId: string): boolean
	return Manufacturers.capabilityFor(manufacturerId, printMethodId) > 0
end

--[[
	How far outside their comfortable weight band a request sits, 0..1.
	0 = within the sweet spot. Used as a quality penalty AND surfaced as a
	warning on the quote, so the player can see the mismatch before ordering.
]]
function Manufacturers.gsmDeviation(manufacturerId: string, gsm: number): number
	local manufacturer = Manufacturers.byId[manufacturerId]
	if not manufacturer then
		return 1
	end
	local band = manufacturer.gsmSweetSpot
	if gsm >= band.min and gsm <= band.max then
		return 0
	end
	local distance = if gsm < band.min then band.min - gsm else gsm - band.max
	-- 120gsm outside the band is treated as maximally wrong.
	return math.clamp(distance / 120, 0, 1)
end

function Manufacturers.prefersFabric(manufacturerId: string, fabricId: string): boolean
	local manufacturer = Manufacturers.byId[manufacturerId]
	if not manufacturer then
		return false
	end
	return table.find(manufacturer.preferredFabricIds, fabricId) ~= nil
end

return Manufacturers
