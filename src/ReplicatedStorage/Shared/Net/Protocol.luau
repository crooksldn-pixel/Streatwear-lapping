--!strict
--[[
	Shared.Net.Protocol

	The single declaration of every remote route: its name, direction, payload
	schema and rate limit.

	Why one table instead of handlers declaring their own remotes:

	  * The set of entry points into the server is auditable in one place. If a
		route is not here, it does not exist.
	  * Every route is FORCED to declare a schema and a rate limit. There is no
		code path that creates a remote without them, so "I forgot to validate
		that one" is not possible.
	  * Client and server derive remote names from the same constants, so a typo
		is a nil index at startup rather than a silently dead feature.

	== Rate limits ==

	`maxPerMinute` is enforced server-side per player per route. The numbers are
	sized to generous human use, not to UI convenience: UpdateProductSpec is high
	because dragging a graphic produces a burst, while OrderSample is low because
	no human orders ten samples a minute and a flood there means an exploit
	attempt against the money path.

	A route marked `authoritativeOnly` must never be reachable in a published
	place without passing DevService's authorisation check.
]]

local Shared = script.Parent.Parent
local Enums = require(Shared.Enums)
local Validate = require(Shared.Util.Validate)

type FieldSpec = Validate.FieldSpec

local Protocol = {}

Protocol.FOLDER_NAME = "Remotes"

-- Route kinds.
Protocol.FUNCTION = "RemoteFunction"
Protocol.EVENT = "RemoteEvent"

export type Route = {
	name: string,
	kind: string,
	-- Direction is documentation for events: "ToServer" | "ToClient".
	direction: string,
	schema: Validate.Schema?,
	maxPerMinute: number,
	authoritativeOnly: boolean?,
	description: string,
}

-- ============================================================================
-- Reusable field specs
-- ============================================================================

local productId: FieldSpec = Validate.entityId("PRD")
local orderId: FieldSpec = Validate.entityId("ORD")

--[[
	A graphic layer as submitted by the Design app.

	Note what is NOT accepted: no inkColor, no resolved cost, no quality, no
	stage. The client sends design INTENT only (which recipe, where, how big).
	Everything derived -- colours, costs, print legality -- is computed on the
	server from config. A client cannot send a graphic that costs £0 or prints at
	perfect quality because those fields are not part of the message.
]]
local graphicLayerSpec: FieldSpec = {
	type = "table",
	fields = {
		recipeId = Validate.configKey(),
		paletteId = Validate.configKey(),
		placement = { type = "string", enum = Enums.Placement },
		printMethodId = Validate.configKey(),

		-- Bounded so a hostile value cannot produce a graphic the size of the
		-- level or an off-garment print.
		scale = { type = "number", min = 0.05, max = 1 },
		rotation = { type = "number", min = -180, max = 180 },
		offsetX = { type = "number", min = -0.5, max = 0.5 },
		offsetY = { type = "number", min = -0.5, max = 0.5 },

		-- Custom text is optional; nil means "use the brand name".
		text = Validate.freeText(24, true),
		subtext = Validate.freeText(28, true),
	},
}

-- ============================================================================
-- Routes
-- ============================================================================

Protocol.routes = {

	-- ---------------------------------------------------------------- state

	GetState = {
		name = "GetState",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = { fields = {} },
		maxPerMinute = 30,
		description = "Returns the client projection of the player's brand state.",
	},

	StateChanged = {
		name = "StateChanged",
		kind = Protocol.EVENT,
		direction = "ToClient",
		maxPerMinute = 0, -- server-originated; not rate limited
		description = "Pushes a fresh state projection after any authoritative change.",
	},

	Notify = {
		name = "Notify",
		kind = Protocol.EVENT,
		direction = "ToClient",
		maxPerMinute = 0,
		description = "Transient notification (sample shipped, parcel arrived).",
	},

	WorldEvent = {
		name = "WorldEvent",
		kind = Protocol.EVENT,
		direction = "ToClient",
		maxPerMinute = 0,
		description = "World-level cue the client should present (parcel arrived, courier knocked).",
	},

	-- ---------------------------------------------------------------- brand

	CreateBrand = {
		name = "CreateBrand",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = {
			fields = {
				name = Validate.brandName(),
				tagline = Validate.freeText(48, true),
				styleId = Validate.configKey(),
			},
		},
		-- Low: this succeeds once. Repeated calls are either UI bugs or probing.
		maxPerMinute = 6,
		description = "Creates the brand identity. Rejected if one already exists.",
	},

	-- -------------------------------------------------------------- product

	CreateProduct = {
		name = "CreateProduct",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = {
			fields = {
				name = Validate.freeText(32, true),
				productType = Validate.configKey(true),
			},
		},
		maxPerMinute = 12,
		description = "Creates a Concept-stage product seeded from the brand's style defaults.",
	},

	RenameProduct = {
		name = "RenameProduct",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = {
			fields = {
				productId = productId,
				name = Validate.freeText(32),
			},
		},
		maxPerMinute = 30,
		description = "Renames a product.",
	},

	UpdateProductSpec = {
		name = "UpdateProductSpec",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = {
			fields = {
				productId = productId,

				-- Partial patch: every field optional, so the app can send just
				-- what changed instead of the whole spec.
				blankId = Validate.configKey(true),
				colorId = Validate.configKey(true),
				fabricId = Validate.configKey(true),
				gsm = { type = "integer", optional = true, min = 100, max = 500 },

				-- Whole-list replacement. Simpler to validate than per-index
				-- mutations, and a garment carries at most a few layers.
				graphics = {
					type = "array",
					optional = true,
					maxItems = 3,
					item = graphicLayerSpec,
				},
			},
		},
		-- High: dragging a graphic in the canvas commits on release, but a
		-- player adjusting a design produces a legitimate burst.
		maxPerMinute = 120,
		description = "Validates and applies a partial spec patch. Rejected once a sample is in production.",
	},

	ArchiveProduct = {
		name = "ArchiveProduct",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = { fields = { productId = productId } },
		maxPerMinute = 12,
		description = "Archives a product. Does not delete it; ids are never reused.",
	},

	-- ------------------------------------------------------------- supplier

	GetQuote = {
		name = "GetQuote",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = {
			fields = {
				productId = productId,
				manufacturerId = Validate.configKey(),
			},
		},
		maxPerMinute = 60,
		description = "Prices a product at a manufacturer. Read-only; no state change.",
	},

	ContactSupplier = {
		name = "ContactSupplier",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = {
			fields = {
				manufacturerId = Validate.configKey(),
				productId = { type = "string", optional = true, maxLength = 24, pattern = "^PRD%-%d+$" },
				intent = {
					type = "string",
					oneOf = { "Introduce", "AskCapability", "AskPricing", "AskLeadTime", "RequestSample" },
				},
			},
		},
		maxPerMinute = 40,
		description = "Opens or advances a simulated conversation with a supplier.",
	},

	OrderSample = {
		name = "OrderSample",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = {
			fields = {
				productId = productId,
				manufacturerId = Validate.configKey(),
				-- The price the client believes it is agreeing to, in pence.
				-- The server recomputes the real cost and REJECTS a mismatch rather
				-- than charging a different amount, so a stale quote on screen can
				-- never silently take more money than the player agreed to. This is
				-- a confirmation, never an input to the charge.
				acknowledgedCostPence = { type = "integer", min = 0, max = 100000000 },
			},
		},
		-- Deliberately low. Touches money.
		maxPerMinute = 10,
		description = "Places a sample order: validates funds, debits server-side, freezes a spec snapshot.",
	},

	-- --------------------------------------------------------------- sample

	OpenParcel = {
		name = "OpenParcel",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = { fields = { orderId = orderId } },
		maxPerMinute = 20,
		description = "Opens a delivered parcel. First call reveals the quality report.",
	},

	GetSampleReport = {
		name = "GetSampleReport",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = { fields = { orderId = orderId } },
		maxPerMinute = 40,
		description = "Returns the inspection report for an opened sample.",
	},

	ResolveSample = {
		name = "ResolveSample",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = {
			fields = {
				orderId = orderId,
				decision = { type = "string", oneOf = { "Approve", "Revise" } },
				note = Validate.freeText(140, true),
			},
		},
		maxPerMinute = 20,
		description = "Approves a sample or requests a revision, bumping the product revision.",
	},

	-- ---------------------------------------------------------- interaction

	Interact = {
		name = "Interact",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = {
			fields = {
				-- The instance the client claims to be interacting with. The server
				-- re-resolves it against its own registry and re-checks distance;
				-- the claim is a lookup key, never a grant of permission.
				targetName = { type = "string", maxLength = 64, pattern = "^[%w_%-%.]+$" },
				kind = { type = "string", enum = Enums.InteractionKind },
			},
		},
		maxPerMinute = 90,
		description = "Requests an interaction. Server validates proximity and returns a directive.",
	},

	-- ------------------------------------------------------------------ dev

	DevCommand = {
		name = "DevCommand",
		kind = Protocol.FUNCTION,
		direction = "ToServer",
		schema = {
			fields = {
				command = { type = "string", maxLength = 32, pattern = "^[%a_]+$" },
				arg = { type = "string", optional = true, maxLength = 48, pattern = "^[%w_%-%.]*$" },
			},
		},
		maxPerMinute = 60,
		authoritativeOnly = true,
		description = "Development commands. Gated by DevService authorisation; inert in production.",
	},
} :: { [string]: Route }

-- ============================================================================
-- Integrity check
-- ============================================================================

--[[
	Enforced at require time: every client-callable route must declare both a
	schema and a positive rate limit. A route that forgets either is a hole in
	the server's defences, so this fails loudly at startup rather than shipping.
]]
local function assertWellFormed()
	for key, route in pairs(Protocol.routes) do
		assert(route.name == key, string.format("Protocol route %q has mismatched name %q", key, route.name))
		assert(
			route.kind == Protocol.FUNCTION or route.kind == Protocol.EVENT,
			string.format("Protocol route %q has invalid kind", key)
		)

		if route.direction == "ToServer" then
			assert(route.schema ~= nil, string.format("Protocol route %q is client-callable but declares no schema", key))
			assert(
				type(route.maxPerMinute) == "number" and route.maxPerMinute > 0,
				string.format("Protocol route %q is client-callable but declares no rate limit", key)
			)
		end
	end
end

assertWellFormed()

function Protocol.get(name: string): Route?
	return Protocol.routes[name]
end

function Protocol.clientCallable(): { Route }
	local out = {}
	for _, route in pairs(Protocol.routes) do
		if route.direction == "ToServer" then
			table.insert(out, route)
		end
	end
	return out
end

return Protocol
