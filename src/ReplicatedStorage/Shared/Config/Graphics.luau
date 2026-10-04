--!strict
--[[
	Config.Graphics

	Graphic recipes and ink palettes.

	== Why recipes instead of image assets ==

	A graphic is a declarative recipe rendered from UI primitives (TextLabel,
	Frame, UIStroke, UIGradient) by Shared.Garment.GraphicRenderer. It is not an
	image asset. That choice buys:

	  * No asset dependency and no moderation risk on a per-graphic basis.
	  * Identical rendering in the design canvas (into a Frame) and on the
		physical garment (into a SurfaceGui) -- one renderer, one result, so what
		the player designs is literally what arrives.
	  * The recipe interpolates the BRAND NAME. The player's first tee says their
		own brand on it, which is the whole point of the game.
	  * It serialises as a few fields in the save rather than pixel data.

	Enums.GraphicKind reserves "Image" for a future EditableImage or uploaded-
	decal backend; GraphicRenderer branches on `kind`, so adding it is additive.

	== colourCount ==

	Each recipe declares how many distinct inks it needs. Screen printing charges
	per colour, so a two-colour recipe genuinely costs more to screen print than
	a one-colour one. This is read by PrintMethods.costPence.
]]

local Enums = require(script.Parent.Parent.Enums)

export type GraphicRecipe = {
	id: string,
	name: string,
	kind: string, -- Enums.GraphicKind
	description: string,

	-- Inks required. Drives per-colour screen printing cost.
	colourCount: number,

	-- Sensible starting transform when the player first adds it.
	defaultScale: number,
	defaultPlacement: string,

	-- Whether the recipe uses the brand name, a fixed string, or custom text.
	textSource: string, -- "brand" | "custom" | "none"
	defaultText: string?,
	defaultSubtext: string?,
	maxTextLength: number,

	-- How much fine detail the recipe contains. A recipe with thin linework
	-- loses more when printed by a low-detail method such as puff, so this
	-- feeds the print quality calculation rather than being cosmetic.
	detailDemand: number, -- 0..1

	-- Which aesthetic directions this reads as. Used only for sorting/suggesting
	-- in the Design app; never gates anything.
	styleAffinity: { string },
}

export type Palette = {
	id: string,
	name: string,
	-- Primary ink, plus optional secondary for two-colour recipes.
	ink: Color3,
	secondary: Color3,
	-- Whether this palette is intended for dark or light garments.
	forDarkGarment: boolean,
}

local Graphics = {}

-- ============================================================================
-- Ink palettes
-- ============================================================================

Graphics.palettes = {
	{
		id = "white",
		name = "White",
		ink = Color3.fromRGB(246, 246, 243),
		secondary = Color3.fromRGB(176, 176, 172),
		forDarkGarment = true,
	},
	{
		id = "black",
		name = "Black",
		ink = Color3.fromRGB(18, 18, 20),
		secondary = Color3.fromRGB(88, 88, 92),
		forDarkGarment = false,
	},
	{
		id = "bone",
		name = "Bone",
		ink = Color3.fromRGB(230, 223, 207),
		secondary = Color3.fromRGB(166, 156, 136),
		forDarkGarment = true,
	},
	{
		id = "acid",
		name = "Acid Yellow",
		ink = Color3.fromRGB(214, 232, 58),
		secondary = Color3.fromRGB(28, 28, 24),
		forDarkGarment = true,
	},
	{
		id = "rust",
		name = "Rust",
		ink = Color3.fromRGB(176, 86, 44),
		secondary = Color3.fromRGB(240, 226, 206),
		forDarkGarment = true,
	},
	{
		id = "cobalt",
		name = "Cobalt",
		ink = Color3.fromRGB(54, 86, 204),
		secondary = Color3.fromRGB(226, 232, 248),
		forDarkGarment = true,
	},
	{
		id = "crimson",
		name = "Crimson",
		ink = Color3.fromRGB(168, 40, 48),
		secondary = Color3.fromRGB(242, 230, 224),
		forDarkGarment = true,
	},
	{
		id = "sage_ink",
		name = "Sage",
		ink = Color3.fromRGB(146, 158, 126),
		secondary = Color3.fromRGB(42, 46, 38),
		forDarkGarment = true,
	},
	{
		id = "tonal",
		name = "Tonal",
		-- Resolved against the garment colour at render time for a subtle,
		-- same-colour print. GraphicRenderer special-cases this id.
		ink = Color3.fromRGB(128, 128, 128),
		secondary = Color3.fromRGB(128, 128, 128),
		forDarkGarment = true,
	},
} :: { Palette }

Graphics.palettesById = {} :: { [string]: Palette }
for _, palette in ipairs(Graphics.palettes) do
	Graphics.palettesById[palette.id] = palette
end

function Graphics.getPalette(id: string): Palette?
	return Graphics.palettesById[id]
end

-- ============================================================================
-- Recipes
-- ============================================================================

Graphics.recipes = {
	{
		id = "wordmark_heavy",
		name = "Heavy Wordmark",
		kind = Enums.GraphicKind.Wordmark,
		description = "Your brand name set large and tight in heavy weight. The simplest thing that works.",
		colourCount = 1,
		defaultScale = 0.78,
		defaultPlacement = Enums.Placement.FrontCentre,
		textSource = "brand",
		maxTextLength = 20,
		detailDemand = 0.3,
		styleAffinity = { "streetwear", "minimal", "skate" },
	},
	{
		id = "wordmark_small",
		name = "Small Wordmark",
		kind = Enums.GraphicKind.Wordmark,
		description = "Restrained lettering, sized for a chest hit. Reads as confidence rather than volume.",
		colourCount = 1,
		defaultScale = 0.85,
		defaultPlacement = Enums.Placement.FrontChestLeft,
		textSource = "brand",
		maxTextLength = 20,
		detailDemand = 0.55,
		styleAffinity = { "minimal", "luxury" },
	},
	{
		id = "arch_collegiate",
		name = "Collegiate Arch",
		kind = Enums.GraphicKind.ArchText,
		description = "Brand name curved over a strapline. Borrowed from varsity teamwear, now permanent streetwear furniture.",
		colourCount = 2,
		defaultScale = 0.84,
		defaultPlacement = Enums.Placement.FrontCentre,
		textSource = "brand",
		defaultSubtext = "EST. 2026",
		maxTextLength = 16,
		detailDemand = 0.6,
		styleAffinity = { "streetwear", "graphic", "skate" },
	},
	{
		id = "box_logo",
		name = "Box Logo",
		kind = Enums.GraphicKind.BoxLogo,
		description = "Name reversed out of a solid rectangle. Hard to get wrong, hard to make interesting.",
		colourCount = 2,
		defaultScale = 0.6,
		defaultPlacement = Enums.Placement.FrontCentre,
		textSource = "brand",
		maxTextLength = 14,
		detailDemand = 0.25,
		styleAffinity = { "streetwear", "skate" },
	},
	{
		id = "emblem_circle",
		name = "Circle Emblem",
		kind = Enums.GraphicKind.Emblem,
		description = "Ringed roundel with the name inside and a date beneath. Workwear and heritage cues.",
		colourCount = 2,
		defaultScale = 0.55,
		defaultPlacement = Enums.Placement.FrontCentre,
		textSource = "brand",
		defaultSubtext = "LONDON",
		maxTextLength = 12,
		detailDemand = 0.75,
		styleAffinity = { "luxury", "minimal", "graphic" },
	},
	{
		id = "monogram",
		name = "Monogram",
		kind = Enums.GraphicKind.Monogram,
		description = "Initials only, set as a mark. Works embroidered; works small.",
		colourCount = 1,
		defaultScale = 0.7,
		defaultPlacement = Enums.Placement.FrontChestLeft,
		textSource = "brand",
		maxTextLength = 4,
		detailDemand = 0.4,
		styleAffinity = { "luxury", "minimal" },
	},
	{
		id = "stripe_stack",
		name = "Stripe Stack",
		kind = Enums.GraphicKind.StripeStack,
		description = "Name banded between heavy rules, repeated down the chest. Loud and cheap to print.",
		colourCount = 2,
		defaultScale = 0.88,
		defaultPlacement = Enums.Placement.FrontCentre,
		textSource = "brand",
		maxTextLength = 14,
		detailDemand = 0.35,
		styleAffinity = { "y2k", "graphic", "streetwear" },
	},
	{
		id = "back_hit_text",
		name = "Back Hit",
		kind = Enums.GraphicKind.ArchText,
		description = "Large text across the shoulders with a line of small type under it. Built for the back panel.",
		colourCount = 2,
		defaultScale = 0.92,
		defaultPlacement = Enums.Placement.Back,
		textSource = "brand",
		defaultSubtext = "ALL RIGHTS RESERVED",
		maxTextLength = 18,
		detailDemand = 0.5,
		styleAffinity = { "streetwear", "graphic", "y2k" },
	},
} :: { GraphicRecipe }

Graphics.recipesById = {} :: { [string]: GraphicRecipe }
for _, recipe in ipairs(Graphics.recipes) do
	Graphics.recipesById[recipe.id] = recipe
end

function Graphics.getRecipe(id: string): GraphicRecipe?
	return Graphics.recipesById[id]
end

function Graphics.exists(id: unknown): boolean
	return typeof(id) == "string" and Graphics.recipesById[id :: string] ~= nil
end

-- Maximum graphics permitted on one garment in the slice. A real tee rarely
-- carries more than a chest hit, a back hit and a sleeve.
Graphics.MAX_PER_GARMENT = 3

--[[
	Default graphic spec for a freshly added graphic.
	The palette is chosen from the garment's darkness so the result is visible
	immediately -- a new graphic should never render invisible against the shirt.
]]
function Graphics.defaultSpec(recipeId: string, garmentIsDark: boolean, printMethodId: string)
	local recipe = Graphics.recipesById[recipeId]
	if not recipe then
		return nil
	end

	return {
		kind = recipe.kind,
		recipeId = recipe.id,
		text = nil, -- nil means "use the brand name"
		subtext = recipe.defaultSubtext,
		paletteId = if garmentIsDark then "white" else "black",
		placement = recipe.defaultPlacement,
		scale = recipe.defaultScale,
		offset = { x = 0, y = 0 },
		rotation = 0,
		printMethodId = printMethodId,
	}
end

return Graphics
