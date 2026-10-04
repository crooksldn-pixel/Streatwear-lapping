--!strict
--[[
	Config.Styles

	Brand aesthetic directions chosen during brand setup.

	== These are NOT classes ==

	The brief is explicit that style direction must not lock mechanics, and
	nothing here gates anything. A style provides:

	  * suggested defaults (which blank, fabric, colourway and graphic the Design
		app pre-selects, so the first product is already coherent)
	  * sort ordering for graphic recipes
	  * flavour text

	A player who picks Minimal can still make a loud y2k puff-print tee. The
	style just means the app stops making them undo defaults that fight their
	intent. It is changeable later, which is why `locked` does not exist.

	`audienceAffinity` is declared for the future social/audience system: a
	coherent brand will grow faster with an aligned audience than an incoherent
	one. Unused in the slice, but recorded so the data exists when that system
	arrives rather than needing a migration.
]]

export type Style = {
	id: string,
	name: string,
	tagline: string,
	description: string,

	-- Pre-selections for a new product. Suggestions only.
	suggested: {
		blankId: string,
		fabricId: string,
		gsm: number,
		colorId: string,
		graphicRecipeId: string,
		printMethodId: string,
		paletteId: string,
	},

	-- Graphic recipe tags this direction gravitates toward, used for ordering.
	affinityTags: { string },

	-- Accent colour used by the OS to tint the player's own brand surfaces.
	accent: Color3,

	-- Reserved for the audience system.
	audienceAffinity: { [string]: number },
}

local Styles = {}

Styles.list = {
	{
		id = "streetwear",
		name = "Streetwear",
		tagline = "Heavyweight, boxy, graphic-led",
		description = "Built on heavy cotton and bold chest hits. The default language of the modern independent label.",
		suggested = {
			blankId = "tee_boxy",
			fabricId = "cotton_heavy",
			gsm = 280,
			colorId = "black",
			graphicRecipeId = "arch_collegiate",
			printMethodId = "screen",
			paletteId = "white",
		},
		affinityTags = { "streetwear", "graphic", "skate" },
		accent = Color3.fromRGB(226, 222, 212),
		audienceAffinity = { streetwear = 1.0, skate = 0.6, hype = 0.7 },
	},
	{
		id = "minimal",
		name = "Minimal",
		tagline = "Quiet, considered, nothing spare",
		description = "Small marks, tonal prints, better cloth. Sells on fabric and fit rather than on the graphic.",
		suggested = {
			blankId = "tee_classic",
			fabricId = "cotton_supima",
			gsm = 220,
			colorId = "bone",
			graphicRecipeId = "wordmark_small",
			printMethodId = "screen",
			paletteId = "black",
		},
		affinityTags = { "minimal", "luxury" },
		accent = Color3.fromRGB(208, 206, 198),
		audienceAffinity = { minimal = 1.0, luxury = 0.5 },
	},
	{
		id = "y2k",
		name = "Y2K",
		tagline = "Loud, chromed, early-2000s",
		description = "Stacked type, hard colour, prints that fill the panel. Nostalgia as a design brief.",
		suggested = {
			blankId = "tee_classic",
			fabricId = "cotton_combed",
			gsm = 200,
			colorId = "white",
			graphicRecipeId = "stripe_stack",
			printMethodId = "dtf",
			paletteId = "cobalt",
		},
		affinityTags = { "y2k", "graphic" },
		accent = Color3.fromRGB(132, 158, 236),
		audienceAffinity = { y2k = 1.0, hype = 0.8 },
	},
	{
		id = "luxury",
		name = "Luxury",
		tagline = "Expensive cloth, invisible branding",
		description = "Supima, embroidery, monograms. Costs more to make and asks the customer to know why.",
		suggested = {
			blankId = "tee_classic",
			fabricId = "cotton_supima",
			gsm = 240,
			colorId = "charcoal",
			graphicRecipeId = "monogram",
			printMethodId = "embroidery",
			paletteId = "bone",
		},
		affinityTags = { "luxury", "minimal" },
		accent = Color3.fromRGB(198, 178, 142),
		audienceAffinity = { luxury = 1.0, minimal = 0.6 },
	},
	{
		id = "skate",
		name = "Skate",
		tagline = "Hardwearing, irreverent, back hits",
		description = "Mid-weight cotton, back panel graphics, screen print. Made to be worn out rather than kept.",
		suggested = {
			blankId = "tee_classic",
			fabricId = "cotton_combed",
			gsm = 220,
			colorId = "ash_grey",
			graphicRecipeId = "back_hit_text",
			printMethodId = "screen",
			paletteId = "black",
		},
		affinityTags = { "skate", "streetwear", "graphic" },
		accent = Color3.fromRGB(214, 206, 188),
		audienceAffinity = { skate = 1.0, streetwear = 0.7 },
	},
	{
		id = "graphic",
		name = "Graphic-Heavy",
		tagline = "The print is the product",
		description = "Full-panel artwork front and back. Lives or dies on the strength of the graphic.",
		suggested = {
			blankId = "tee_boxy",
			fabricId = "cotton_heavy",
			gsm = 260,
			colorId = "vintage_black",
			graphicRecipeId = "box_logo",
			printMethodId = "dtf",
			paletteId = "acid",
		},
		affinityTags = { "graphic", "streetwear", "y2k" },
		accent = Color3.fromRGB(206, 224, 86),
		audienceAffinity = { graphic = 1.0, hype = 0.6 },
	},
} :: { Style }

Styles.byId = {} :: { [string]: Style }
for _, style in ipairs(Styles.list) do
	Styles.byId[style.id] = style
end

Styles.DEFAULT_ID = "streetwear"

function Styles.get(id: string): Style?
	return Styles.byId[id]
end

function Styles.exists(id: unknown): boolean
	return typeof(id) == "string" and Styles.byId[id :: string] ~= nil
end

function Styles.getOrDefault(id: string?): Style
	if id and Styles.byId[id] then
		return Styles.byId[id]
	end
	return Styles.byId[Styles.DEFAULT_ID]
end

return Styles
