--!strict
--[[
	Enums

	String-valued enums. Strings (not integers) because they survive DataStore
	round-trips legibly, make saved data human-readable when debugging, and
	do not silently shift meaning if a list is reordered.

	Every enum exposes `isValid(value)` so remote payloads can be checked
	without callers hand-writing comparisons.
]]

local Enums = {}

local function makeEnum(name: string, values: { string })
	local set = {}
	local ordered = table.clone(values)
	for index, value in ipairs(values) do
		set[value] = index
	end

	local enum = {
		_name = name,
		_set = set,
		_ordered = ordered,
	}

	for _, value in ipairs(values) do
		enum[value] = value
	end

	function enum.isValid(value: unknown): boolean
		return typeof(value) == "string" and set[value :: string] ~= nil
	end

	function enum.indexOf(value: string): number?
		return set[value]
	end

	function enum.ordered(): { string }
		return table.clone(ordered)
	end

	-- Ordering comparison, for "has the product reached at least stage X" checks.
	function enum.atLeast(value: string, threshold: string): boolean
		local a, b = set[value], set[threshold]
		if not a or not b then
			return false
		end
		return a >= b
	end

	return table.freeze(enum)
end

Enums.makeEnum = makeEnum

--[[
	ProductStage -- the lifecycle of a Product entity.

	The full ladder is declared now even though the vertical slice only drives
	the first several stages. Declaring them up front means the stage machine's
	transition table is the only thing that needs extending later, not the enum
	and every `atLeast` comparison written against it.
]]
Enums.ProductStage = makeEnum("ProductStage", {
	"Concept",
	"Design",
	"TechPack",
	"SampleRequested",
	"SampleInProduction",
	"SampleShipped",
	"SampleReceived",
	"SampleRejected",
	"SampleApproved",
	"BulkProduction",
	"Inventory",
	"Live",
	"Archived",
})

--[[
	OrderStatus -- the lifecycle of a sample order.

	`Opened` is distinct from `Delivered` on purpose: delivery is a world event
	(a parcel exists), opening is a player action. The quality report is withheld
	from the client until `Opened`, so the physical act of opening the box is what
	reveals the outcome rather than it being knowable the moment it ships.
]]
Enums.OrderStatus = makeEnum("OrderStatus", {
	"Requested",
	"Accepted",
	"InProduction",
	"Shipped",
	"Delivered",
	"Opened",
	"Approved",
	"RevisionRequested",
	"Cancelled",
})

Enums.OrderKind = makeEnum("OrderKind", {
	"Sample",
	"Bulk",
})

--[[
	Placement -- where a graphic sits on a garment.
	Values map to a panel + anchor rectangle in Config.Garments.
]]
Enums.Placement = makeEnum("Placement", {
	"FrontCentre",
	"FrontChestLeft",
	"FrontChestRight",
	"Back",
	"BackNeck",
	"Sleeve",
})

Enums.GraphicKind = makeEnum("GraphicKind", {
	"Wordmark",
	"ArchText",
	"BoxLogo",
	"Emblem",
	"StripeStack",
	"Monogram",
	-- Reserved: an image-backed graphic (EditableImage or uploaded decal).
	-- GraphicRenderer already branches on kind, so adding this later is additive.
	"Image",
})

Enums.QualityDimension = makeEnum("QualityDimension", {
	"Print",
	"Stitching",
	"Fabric",
	"Sizing",
})

Enums.LedgerKind = makeEnum("LedgerKind", {
	"SampleOrder",
	"BulkOrder",
	"Sale",
	"Refund",
	"Marketing",
	"Wage",
	"Rent",
	"DevGrant",
})

Enums.InteractionKind = makeEnum("InteractionKind", {
	"Laptop",
	"Parcel",
	"Garment",
	"Bed",
	"Door",
	"Moodboard",
	"Mirror",
})

-- Progression stage of the brand as a whole (gates which apps/world areas exist).
Enums.BrandStage = makeEnum("BrandStage", {
	"Unbranded",
	"Bedroom",
	"FirstSample",
	"PreLaunch",
	"Launched",
	"Scaling",
})

return table.freeze(Enums)
