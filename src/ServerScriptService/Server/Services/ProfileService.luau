--!strict
--[[
	ProfileService

	Owns the player session, the money ledger, progression flags, and the
	projection of state sent to clients.

	Every other service mutates state THROUGH this one rather than touching
	`profile.state` directly, because three things must happen on every change
	and doing them at each call site guarantees one eventually gets missed:

	  1. the profile is marked dirty for autosave
	  2. the brand stage is re-derived from flags
	  3. the client is sent a fresh projection

	== The projection ==

	`project()` is the security boundary for reads. The client receives a
	purpose-built table, never the live state, so:

	  * mutating it client-side changes nothing
	  * server-only fields cannot leak by accident -- most importantly, an
		order's quality report is STRIPPED until the parcel has been physically
		opened, so an exploiter cannot read the outcome of a sample while it is
		still in transit and decide whether to bother walking to the door.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Types = require(Shared.Types)
local Enums = require(Shared.Enums)
local Economy = require(Shared.Config.Economy)
local Progression = require(Shared.Config.Progression)
local TableKit = require(Shared.Util.TableKit)
local Signal = require(Shared.Util.Signal)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("Profile")

local ProfileService = {}
ProfileService.__index = ProfileService

type BrandState = Types.BrandState

function ProfileService.new(dataService: any)
	local self = setmetatable({}, ProfileService)
	self.data = dataService

	-- Fired whenever a player's state changes. The API layer listens and pushes
	-- a projection; nothing else needs to know how replication works.
	self.stateChanged = Signal.new("StateChanged")
	self.playerReady = Signal.new("PlayerReady")

	return self
end

function ProfileService:Init() end

function ProfileService:Start()
	Players.PlayerAdded:Connect(function(player)
		self:OnPlayerAdded(player)
	end)

	-- Players already present when the server starts (Studio play solo races
	-- the connection above).
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:OnPlayerAdded(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		self.data:Release(player.UserId)
		log:info("released %s", player.Name)
	end)
end

function ProfileService:OnPlayerAdded(player: Player)
	local profile = self.data:Load(player.UserId)

	-- Keep the derived stage correct even if flags were written by an older build.
	profile.state.progression.stage = Progression.deriveStage(profile.state.progression.flags)

	log:info("loaded %s (brand: %s)", player.Name,
		profile.state.identity.created and profile.state.identity.name or "none")

	self.playerReady:fire(player, profile.state)
	self:Changed(player)
end

-- ============================================================================
-- State access
-- ============================================================================

function ProfileService:GetState(player: Player): BrandState?
	return self.data:GetState(player.UserId)
end

--[[
	The single mutation entry point.

	`mutator` receives the live state and may change it in place. Returning false
	abandons the change (no dirty flag, no replication), which lets a caller bail
	out mid-way after discovering a precondition fails.
]]
function ProfileService:Mutate(player: Player, mutator: (BrandState) -> boolean?): boolean
	local state = self:GetState(player)
	if not state then
		return false
	end

	local ok, result = pcall(mutator, state)
	if not ok then
		log:error("mutation failed for %s: %s", player.Name, tostring(result))
		return false
	end
	if result == false then
		return false
	end

	state.progression.stage = Progression.deriveStage(state.progression.flags)
	self.data:MarkDirty(player.UserId)
	self:Changed(player)
	return true
end

function ProfileService:Changed(player: Player)
	local state = self:GetState(player)
	if state then
		self.stateChanged:fire(player, state)
	end
end

-- ============================================================================
-- Money
-- ============================================================================

--[[
	All money movement goes through here. Amounts are integer pence; a negative
	amount is a debit.

	The guards are deliberately strict, because this is the function an exploiter
	would most like to reach:

	  * non-integer, NaN and infinite amounts are refused outright
	  * amounts beyond Economy bounds are refused and logged as a probable bug or
		attack rather than clamped, since clamping would let a nonsense request
		still move the maximum allowed money
	  * a debit that would overdraw is refused; the balance never goes negative

	Returns ok plus a reason code so callers can distinguish "cannot afford" from
	"malformed request".
]]
function ProfileService:AdjustCash(
	player: Player,
	amountPence: number,
	kind: string,
	label: string
): (boolean, string?)
	if type(amountPence) ~= "number" or amountPence ~= amountPence then
		log:error("AdjustCash got a non-number for %s", player.Name)
		return false, "InvalidAmount"
	end
	if amountPence % 1 ~= 0 then
		log:error("AdjustCash got a fractional amount (%s) for %s", tostring(amountPence), player.Name)
		return false, "InvalidAmount"
	end

	local magnitude = math.abs(amountPence)
	if magnitude ~= 0 and magnitude < Economy.minTransactionPence then
		return false, "InvalidAmount"
	end
	if magnitude > Economy.maxTransactionPence then
		log:error("AdjustCash refused an out-of-bounds amount (%d) for %s", amountPence, player.Name)
		return false, "InvalidAmount"
	end

	if not Enums.LedgerKind.isValid(kind) then
		log:error("AdjustCash got an unknown ledger kind %q", tostring(kind))
		return false, "InvalidKind"
	end

	local state = self:GetState(player)
	if not state then
		return false, "NoProfile"
	end

	if amountPence < 0 and state.finances.cashPence + amountPence < 0 then
		return false, "InsufficientFunds"
	end

	self:Mutate(player, function(s)
		local finances = s.finances
		finances.cashPence += amountPence

		if amountPence < 0 then
			finances.lifetimeSpendPence += -amountPence
		else
			finances.lifetimeRevenuePence += amountPence
		end

		table.insert(finances.ledger, {
			at = os.time(),
			kind = kind,
			amountPence = amountPence,
			balancePence = finances.cashPence,
			label = label,
		})
		TableKit.trimFront(finances.ledger, Economy.ledgerMaxEntries)
		return true
	end)

	return true
end

function ProfileService:CanAfford(player: Player, pence: number): boolean
	local state = self:GetState(player)
	return state ~= nil and state.finances.cashPence >= pence
end

-- ============================================================================
-- Progression
-- ============================================================================

-- Flags are one-way. Returns true only on the transition, so callers can fire
-- first-time presentation without tracking it themselves.
function ProfileService:SetFlag(player: Player, flag: string): boolean
	local state = self:GetState(player)
	if not state or state.progression.flags[flag] then
		return false
	end

	self:Mutate(player, function(s)
		s.progression.flags[flag] = true
		return true
	end)
	log:debug("flag %s set for %s", flag, player.Name)
	return true
end

function ProfileService:HasFlag(player: Player, flag: string): boolean
	local state = self:GetState(player)
	return state ~= nil and state.progression.flags[flag] == true
end

function ProfileService:Increment(player: Player, counter: string, amount: number?)
	local step = amount or 1
	self:Mutate(player, function(s)
		s.progression.counters[counter] = (s.progression.counters[counter] or 0) + step
		return true
	end)
end

-- ============================================================================
-- Client projection
-- ============================================================================

--[[
	Builds the client-visible view of a state.

	What is deliberately withheld:

	  * `order.quality` while the order has not been opened. The quality report
		exists on the server from the moment production finishes, but revealing
		it early would let the player know the outcome before opening the box --
		and an exploiter read it straight off the wire. It appears only once
		status reaches Opened.
	  * `specSnapshot` is included, because the client must render the garment
		that was actually made rather than the current design.
]]
function ProfileService:Project(state: BrandState): any
	local orders: { [string]: any } = {}
	for orderId, order in pairs(state.orders) do
		local revealed = Enums.OrderStatus.atLeast(order.status, Enums.OrderStatus.Opened)

		orders[orderId] = {
			id = order.id,
			kind = order.kind,
			productId = order.productId,
			manufacturerId = order.manufacturerId,
			productRevision = order.productRevision,
			specSnapshot = order.specSnapshot,
			status = order.status,
			costPence = order.costPence,
			placedAt = order.placedAt,
			productionEndsAt = order.productionEndsAt,
			shippingEndsAt = order.shippingEndsAt,
			deliveredAt = order.deliveredAt,
			openedAt = order.openedAt,
			resolvedAt = order.resolvedAt,
			parcelSpawned = order.parcelSpawned,

			-- Withheld until the box is physically opened.
			quality = if revealed then order.quality else nil,
		}
	end

	local availableApps: { [string]: boolean } = {}
	for _, requirement in ipairs(Progression.appRequirements) do
		availableApps[requirement.appId] =
			Progression.isAppAvailable(requirement.appId, state.progression.flags)
	end

	return {
		identity = TableKit.deepCopy(state.identity),
		finances = {
			cashPence = state.finances.cashPence,
			lifetimeSpendPence = state.finances.lifetimeSpendPence,
			lifetimeRevenuePence = state.finances.lifetimeRevenuePence,
			-- Only the recent tail is sent; the full ledger is server-side.
			ledger = (function()
				local tail = {}
				local ledger = state.finances.ledger
				for index = math.max(1, #ledger - 24), #ledger do
					table.insert(tail, ledger[index])
				end
				return tail
			end)(),
		},
		products = TableKit.deepCopy(state.products),
		productOrder = TableKit.deepCopy(state.productOrder),
		orders = orders,
		orderIndex = TableKit.deepCopy(state.orderIndex),
		manufacturers = TableKit.deepCopy(state.manufacturers),
		progression = TableKit.deepCopy(state.progression),
		availableApps = availableApps,
		serverTime = os.time(),
	}
end

return ProfileService
