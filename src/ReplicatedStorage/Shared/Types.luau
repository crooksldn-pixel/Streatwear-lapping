--!strict
--[[
	Types

	Shared Luau type surface for the simulation. Exported so server services and
	client controllers describe the same shapes rather than each re-deriving them.

	Schema notes that matter:

	* All money is INTEGER PENCE. Never a float. Formatting to "£" happens only
	  at the display edge (Util.Format). Floats drift across many transactions
	  and make balance verification fuzzy.

	* Timestamps are `os.time()` seconds (absolute, UTC). Durations are seconds.
	  Absolute deadlines are stored (not "time remaining") so timers survive a
	  rejoin without the player gaining or losing progress by leaving.

	* `GarmentSpec` is the single description of a garment in the entire game.
	  The Design app writes it; a sample order freezes a copy; the parcel
	  references the order; the world model is built from that copy; inspection
	  reads it. No system keeps a parallel representation of "what this shirt is".
]]

local Types = {}

-- ============================================================================
-- Primitives
-- ============================================================================

export type Pence = number
export type Timestamp = number
export type Seconds = number

export type ProductId = string
export type OrderId = string
export type ManufacturerId = string

-- Normalised 0..1 coordinate inside a placement panel.
export type UV = { x: number, y: number }

-- ============================================================================
-- Garment specification -- the shared truth
-- ============================================================================

export type GraphicSpec = {
	kind: string, -- Enums.GraphicKind
	recipeId: string, -- key into Config.Graphics.recipes

	-- Recipe inputs. Which fields are meaningful depends on `kind`;
	-- GraphicRenderer owns that interpretation.
	-- `text == nil` means "use the brand name", which is resolved at render time
	-- rather than copied in, so renaming the brand updates every garment.
	text: string?,
	subtext: string?,
	paletteId: string, -- key into Config.Graphics.palettes

	-- Transform within the placement panel.
	placement: string, -- Enums.Placement
	scale: number, -- 0..1 fraction of the panel's usable width
	offset: UV, -- -0.5..0.5 from panel centre
	rotation: number, -- degrees

	printMethodId: string, -- key into Config.PrintMethods
}

export type GarmentSpec = {
	blankId: string, -- key into Config.Garments.blanks
	colorId: string, -- key into Config.Garments.colorways
	fabricId: string, -- key into Config.Fabrics
	gsm: number, -- must be an allowed value for the chosen fabric
	graphics: { GraphicSpec }, -- ordered; slice permits a small cap per garment
}

-- ============================================================================
-- Product entity
-- ============================================================================

export type StageEvent = {
	stage: string, -- Enums.ProductStage
	at: Timestamp,
	note: string?,
}

export type Product = {
	id: ProductId,
	createdAt: Timestamp,
	updatedAt: Timestamp,

	name: string,
	productType: string, -- "Tee" in the slice; drives which blanks are legal
	stage: string, -- Enums.ProductStage
	revision: number, -- increments when a revision is requested after a sample

	spec: GarmentSpec,

	history: { StageEvent },

	-- Sample orders raised against this product, oldest first.
	sampleOrderIds: { OrderId },
	activeSampleOrderId: OrderId?,
	approvedSampleOrderId: OrderId?,
}

-- ============================================================================
-- Quality
-- ============================================================================

--[[
	A quality score is 0..1. `QualityService` derives each dimension from the
	manufacturer's traits, how well that manufacturer handles the specific
	choices in the spec, and bounded variance seeded from the order id -- so a
	given order always evaluates to the same result and cannot be re-rolled.
]]
export type QualityReport = {
	dimensions: { [string]: number }, -- Enums.QualityDimension -> 0..1
	overall: number, -- 0..1, weighted
	notes: { string }, -- human-readable observations shown during inspection
	rolledAt: Timestamp,
	seed: number,
}

-- ============================================================================
-- Orders
-- ============================================================================

export type Quote = {
	manufacturerId: ManufacturerId,
	productId: ProductId,

	sampleCostPence: Pence,
	unitCostPence: Pence, -- indicative bulk unit cost at the manufacturer's MOQ
	moq: number,

	productionSeconds: Seconds,
	shippingSeconds: Seconds,

	-- Surfaced so the player can reason about fit before committing money.
	capabilityNotes: { string },
	canFulfil: boolean,
	rejectionReason: string?,
}

export type SampleOrder = {
	id: OrderId,
	kind: string, -- Enums.OrderKind
	productId: ProductId,
	manufacturerId: ManufacturerId,

	-- The revision of the product this sample represents, and a FROZEN copy of
	-- the spec as it was when the order was placed. Editing the product after
	-- ordering must not retroactively change what the factory made.
	productRevision: number,
	specSnapshot: GarmentSpec,

	status: string, -- Enums.OrderStatus
	costPence: Pence,

	placedAt: Timestamp,
	productionEndsAt: Timestamp,
	shippingEndsAt: Timestamp,
	deliveredAt: Timestamp?,
	openedAt: Timestamp?,
	resolvedAt: Timestamp?,

	-- Server-only until the parcel is physically opened. Stripped from the
	-- client projection while status is below `Opened`.
	quality: QualityReport?,

	parcelSpawned: boolean,
}

-- ============================================================================
-- Brand state (the persisted root)
-- ============================================================================

export type LedgerEntry = {
	at: Timestamp,
	kind: string, -- Enums.LedgerKind
	amountPence: Pence, -- negative = outgoing
	balancePence: Pence, -- balance AFTER the entry, for statement rendering
	label: string,
}

export type Identity = {
	created: boolean,
	name: string, -- raw, as typed
	displayName: string, -- filtered for display to other players
	tagline: string,
	displayTagline: string,
	styleId: string, -- key into Config.Styles; aesthetic direction, not a class
	createdAt: Timestamp?,
}

export type Finances = {
	cashPence: Pence,
	lifetimeSpendPence: Pence,
	lifetimeRevenuePence: Pence,
	ledger: { LedgerEntry }, -- capped; oldest trimmed
}

export type ManufacturerRelationship = {
	discovered: boolean,
	ordersPlaced: number,
	samplesApproved: number,
	relationship: number, -- 0..1, affects pricing/priority later
	lastContactAt: Timestamp?,
}

export type Progression = {
	stage: string, -- Enums.BrandStage
	flags: { [string]: boolean },
	counters: { [string]: number },
}

--[[
	BrandState -- the persisted root document.

	Future sections (inventory, audience, social, customers, reputation,
	properties, employees) are declared and defaulted EMPTY from v1 rather than
	being absent. Adding a field to an existing table is a no-op migration;
	introducing a whole new top-level section to live saves is not. This costs a
	few bytes now and avoids a migration per system later.
]]
export type BrandState = {
	schemaVersion: number,
	createdAt: Timestamp,
	lastSavedAt: Timestamp,
	playTimeSeconds: Seconds,

	identity: Identity,
	finances: Finances,

	products: { [ProductId]: Product },
	productOrder: { ProductId }, -- stable display ordering

	orders: { [OrderId]: SampleOrder },
	orderIndex: { OrderId }, -- newest-last

	manufacturers: { [ManufacturerId]: ManufacturerRelationship },

	progression: Progression,

	-- Reserved, intentionally empty in v1.
	inventory: { [string]: any },
	audience: { [string]: any },
	social: { [string]: any },
	customers: { [string]: any },
	reputation: { [string]: any },
	properties: { [string]: any },
	employees: { [string]: any },

	counters: { [string]: number }, -- id sequences, kept with the save
}

-- ============================================================================
-- Transport
-- ============================================================================

--[[
	Every remote returns this shape rather than raising or returning bare values.
	The client can therefore render a failure reason without guessing, and the
	server never leaks an error string it did not deliberately author.
]]
export type Response<T> = {
	ok: boolean,
	data: T?,
	error: string?, -- machine-readable code
	message: string?, -- player-facing text
}

-- What an interaction resolves to. The server decides; the client obeys.
export type InteractionDirective = {
	action: string, -- "OpenOS" | "OpenParcel" | "InspectGarment" | "Message"
	payload: { [string]: any }?,
}

return Types
