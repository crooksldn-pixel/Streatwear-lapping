--!strict
--[[
	Config.Garments

	Blank garments, colourways, and the placement geometry that maps a graphic's
	normalised transform onto a physical panel of the garment.

	== Placement geometry ==

	A `GraphicSpec` stores placement as a panel name plus a normalised offset and
	scale. This module turns that into real dimensions. Keeping the geometry here
	(rather than in the renderer) means the design canvas and the physical
	garment derive their layout from the SAME numbers, so what the player
	positions in the Design app is exactly where it lands on the sample.

	Panel rects are expressed in studs relative to the garment's front/back face,
	and `print areas` cap how large a graphic may be -- a real factory has a
	maximum platen size, and it stops a player scaling a logo over the whole
	shirt.
]]

local Enums = require(script.Parent.Parent.Enums)

export type PlacementPanel = {
	id: string,
	face: string, -- "Front" | "Back" | "Sleeve"
	label: string,

	-- Centre of the panel on its face, in normalised face coordinates (0..1),
	-- origin top-left.
	centre: { x: number, y: number },
	-- Usable print rectangle as a fraction of the face.
	size: { x: number, y: number },

	-- Maximum print width in centimetres, as a factory would specify.
	maxWidthCm: number,

	-- Placements that cost more to print (awkward positioning on the platen).
	costMultiplier: number,
}

export type Colorway = {
	id: string,
	name: string,
	color: Color3,
	-- Dark garments need light ink and vice versa; the renderer uses this to
	-- pick a sensible default ink so a new graphic is never invisible.
	isDark: boolean,
	-- Dyeing a deep black or a true white consistently is harder and costs more.
	dyeCostPence: number,
	-- 0..1 difficulty; feeds the sizing/fabric quality roll slightly.
	dyeDifficulty: number,
}

export type Blank = {
	id: string,
	name: string,
	productType: string,
	description: string,
	fitNote: string,

	allowedFabricIds: { string },
	defaultFabricId: string,

	-- Studs, used by GarmentBuilder to construct the placeholder model.
	dimensions: { width: number, height: number, depth: number },

	allowedPlacements: { string },
	baseMakeCostPence: number,
}

local Garments = {}

-- ============================================================================
-- Placement panels
-- ============================================================================

Garments.placements = {
	[Enums.Placement.FrontCentre] = {
		id = Enums.Placement.FrontCentre,
		face = "Front",
		label = "Front Centre",
		centre = { x = 0.5, y = 0.46 },
		size = { x = 0.62, y = 0.5 },
		maxWidthCm = 30,
		costMultiplier = 1.0,
	},
	[Enums.Placement.FrontChestLeft] = {
		id = Enums.Placement.FrontChestLeft,
		face = "Front",
		label = "Left Chest",
		centre = { x = 0.33, y = 0.27 },
		size = { x = 0.2, y = 0.16 },
		maxWidthCm = 10,
		costMultiplier = 0.85,
	},
	[Enums.Placement.FrontChestRight] = {
		id = Enums.Placement.FrontChestRight,
		face = "Front",
		label = "Right Chest",
		centre = { x = 0.67, y = 0.27 },
		size = { x = 0.2, y = 0.16 },
		maxWidthCm = 10,
		costMultiplier = 0.85,
	},
	[Enums.Placement.Back] = {
		id = Enums.Placement.Back,
		face = "Back",
		label = "Full Back",
		centre = { x = 0.5, y = 0.42 },
		size = { x = 0.7, y = 0.56 },
		maxWidthCm = 35,
		costMultiplier = 1.1,
	},
	[Enums.Placement.BackNeck] = {
		id = Enums.Placement.BackNeck,
		face = "Back",
		label = "Back Neck",
		centre = { x = 0.5, y = 0.14 },
		size = { x = 0.26, y = 0.1 },
		maxWidthCm = 12,
		costMultiplier = 0.9,
	},
	[Enums.Placement.Sleeve] = {
		id = Enums.Placement.Sleeve,
		face = "Sleeve",
		label = "Sleeve",
		centre = { x = 0.5, y = 0.5 },
		size = { x = 0.5, y = 0.3 },
		maxWidthCm = 8,
		costMultiplier = 1.25,
	},
} :: { [string]: PlacementPanel }

Garments.placementOrder = {
	Enums.Placement.FrontCentre,
	Enums.Placement.FrontChestLeft,
	Enums.Placement.FrontChestRight,
	Enums.Placement.Back,
	Enums.Placement.BackNeck,
	Enums.Placement.Sleeve,
}

function Garments.getPlacement(id: string): PlacementPanel?
	return Garments.placements[id]
end

-- ============================================================================
-- Colourways
-- ============================================================================

Garments.colorways = {
	{
		id = "black",
		name = "Black",
		color = Color3.fromRGB(24, 24, 26),
		isDark = true,
		dyeCostPence = 30,
		dyeDifficulty = 0.45,
	},
	{
		id = "vintage_black",
		name = "Vintage Black",
		color = Color3.fromRGB(46, 45, 48),
		isDark = true,
		dyeCostPence = 55,
		dyeDifficulty = 0.6,
	},
	{
		id = "white",
		name = "White",
		color = Color3.fromRGB(242, 241, 237),
		isDark = false,
		dyeCostPence = 20,
		dyeDifficulty = 0.5,
	},
	{
		id = "bone",
		name = "Bone",
		color = Color3.fromRGB(226, 220, 206),
		isDark = false,
		dyeCostPence = 35,
		dyeDifficulty = 0.35,
	},
	{
		id = "ash_grey",
		name = "Ash Grey",
		color = Color3.fromRGB(154, 153, 150),
		isDark = false,
		dyeCostPence = 25,
		dyeDifficulty = 0.25,
	},
	{
		id = "charcoal",
		name = "Charcoal",
		color = Color3.fromRGB(69, 70, 74),
		isDark = true,
		dyeCostPence = 30,
		dyeDifficulty = 0.3,
	},
	{
		id = "sand",
		name = "Sand",
		color = Color3.fromRGB(198, 178, 148),
		isDark = false,
		dyeCostPence = 40,
		dyeDifficulty = 0.4,
	},
	{
		id = "sage",
		name = "Sage",
		color = Color3.fromRGB(138, 146, 122),
		isDark = false,
		dyeCostPence = 45,
		dyeDifficulty = 0.5,
	},
	{
		id = "navy",
		name = "Navy",
		color = Color3.fromRGB(38, 48, 74),
		isDark = true,
		dyeCostPence = 35,
		dyeDifficulty = 0.35,
	},
	{
		id = "washed_brown",
		name = "Washed Brown",
		color = Color3.fromRGB(96, 74, 60),
		isDark = true,
		dyeCostPence = 50,
		dyeDifficulty = 0.55,
	},
	{
		id = "forest",
		name = "Forest",
		color = Color3.fromRGB(44, 66, 52),
		isDark = true,
		dyeCostPence = 45,
		dyeDifficulty = 0.45,
	},
	{
		id = "cherry",
		name = "Cherry",
		color = Color3.fromRGB(142, 44, 46),
		isDark = true,
		dyeCostPence = 60,
		dyeDifficulty = 0.65,
	},
} :: { Colorway }

Garments.colorwaysById = {} :: { [string]: Colorway }
for _, colorway in ipairs(Garments.colorways) do
	Garments.colorwaysById[colorway.id] = colorway
end

function Garments.getColorway(id: string): Colorway?
	return Garments.colorwaysById[id]
end

-- ============================================================================
-- Blanks
-- ============================================================================

Garments.blanks = {
	{
		id = "tee_classic",
		name = "Classic Tee",
		productType = "Tee",
		description = "Standard regular-fit crew neck. Set-in sleeves, tubular body.",
		fitNote = "Regular fit",
		allowedFabricIds = { "cotton_poly", "cotton_carded", "cotton_combed", "cotton_supima" },
		defaultFabricId = "cotton_combed",
		dimensions = { width = 2.0, height = 2.6, depth = 0.22 },
		allowedPlacements = {
			Enums.Placement.FrontCentre,
			Enums.Placement.FrontChestLeft,
			Enums.Placement.FrontChestRight,
			Enums.Placement.Back,
			Enums.Placement.BackNeck,
			Enums.Placement.Sleeve,
		},
		baseMakeCostPence = 120,
	},
	{
		id = "tee_boxy",
		name = "Boxy Heavyweight Tee",
		productType = "Tee",
		description = "Wide body, dropped shoulder, ribbed collar. Built for heavy knits.",
		fitNote = "Boxy / oversized",
		allowedFabricIds = { "cotton_combed", "cotton_heavy", "cotton_supima" },
		defaultFabricId = "cotton_heavy",
		dimensions = { width = 2.35, height = 2.5, depth = 0.3 },
		allowedPlacements = {
			Enums.Placement.FrontCentre,
			Enums.Placement.FrontChestLeft,
			Enums.Placement.FrontChestRight,
			Enums.Placement.Back,
			Enums.Placement.BackNeck,
			Enums.Placement.Sleeve,
		},
		baseMakeCostPence = 190,
	},
	{
		id = "tee_longsleeve",
		name = "Long Sleeve Tee",
		productType = "Tee",
		description = "Crew neck with full-length sleeves. More fabric, more print area.",
		fitNote = "Regular fit",
		allowedFabricIds = { "cotton_carded", "cotton_combed", "cotton_heavy" },
		defaultFabricId = "cotton_combed",
		dimensions = { width = 2.1, height = 2.6, depth = 0.24 },
		allowedPlacements = {
			Enums.Placement.FrontCentre,
			Enums.Placement.FrontChestLeft,
			Enums.Placement.FrontChestRight,
			Enums.Placement.Back,
			Enums.Placement.BackNeck,
			Enums.Placement.Sleeve,
		},
		baseMakeCostPence = 240,
	},
} :: { Blank }

Garments.blanksById = {} :: { [string]: Blank }
for _, blank in ipairs(Garments.blanks) do
	Garments.blanksById[blank.id] = blank
end

function Garments.getBlank(id: string): Blank?
	return Garments.blanksById[id]
end

function Garments.blanksForType(productType: string): { Blank }
	local out = {}
	for _, blank in ipairs(Garments.blanks) do
		if blank.productType == productType then
			table.insert(out, blank)
		end
	end
	return out
end

function Garments.isFabricAllowed(blankId: string, fabricId: string): boolean
	local blank = Garments.blanksById[blankId]
	if not blank then
		return false
	end
	return table.find(blank.allowedFabricIds, fabricId) ~= nil
end

function Garments.isPlacementAllowed(blankId: string, placement: string): boolean
	local blank = Garments.blanksById[blankId]
	if not blank then
		return false
	end
	return table.find(blank.allowedPlacements, placement) ~= nil
end

-- Default spec for a newly created product of a given type.
function Garments.defaultSpec(productType: string)
	local candidates = Garments.blanksForType(productType)
	local blank = candidates[1] or Garments.blanks[1]
	local Fabrics = require(script.Parent.Fabrics)
	local fabric = Fabrics.get(blank.defaultFabricId)

	return {
		blankId = blank.id,
		colorId = "black",
		fabricId = blank.defaultFabricId,
		gsm = fabric and fabric.defaultGsm or 200,
		graphics = {},
	}
end

return Garments
