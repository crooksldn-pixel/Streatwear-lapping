--!strict
--[[
	SampleOrderService

	The sample order lifecycle, and the only place player money leaves the brand.

		Requested -> InProduction -> Shipped -> Delivered
		          -> Opened -> Approved | RevisionRequested

	== Two things make this trustworthy ==

	1. The spec is SNAPSHOT at order time. The factory makes what was sent, not
	   what the design later became. Editing the product afterwards cannot
	   retroactively change a garment already in production, which is both
	   correct simulation and the reason the sample that arrives is always the
	   one the player paid for.

	2. Cost is recomputed server-side at the moment of ordering and compared
	   against what the client said it was agreeing to. A mismatch is REFUSED
	   rather than silently charged, so a stale quote on screen can never take
	   more money than the player saw. The client's number is a confirmation,
	   never an input.

	== Timing ==

	Deadlines are stored as absolute os.time() values. The tick compares the
	clock to the deadline rather than counting elapsed ticks, so leaving and
	rejoining neither skips nor repeats a wait, and a slow or missed tick delays
	a transition slightly without ever losing it.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Types = require(Shared.Types)
local Enums = require(Shared.Enums)
local Manufacturers = require(Shared.Config.Manufacturers)
local Timings = require(Shared.Config.Timings)
local Progression = require(Shared.Config.Progression)
local Net = require(Shared.Net.Net)
local Ids = require(Shared.Util.Ids)
local TableKit = require(Shared.Util.TableKit)
local Signal = require(Shared.Util.Signal)
local Format = require(Shared.Util.Format)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("SampleOrder")

local SampleOrderService = {}
SampleOrderService.__index = SampleOrderService

type SampleOrder = Types.SampleOrder

-- Guard against a player tying up their whole balance in parallel samples, and
-- against an exploiter spamming orders to exhaust server work.
local MAX_OPEN_ORDERS = 8

function SampleOrderService.new(
	profileService: any,
	productService: any,
	manufacturerService: any,
	qualityService: any
)
	local self = setmetatable({}, SampleOrderService)
	self.profiles = profileService
	self.products = productService
	self.manufacturers = manufacturerService
	self.quality = qualityService

	-- Other systems react to these rather than being called directly, which is
	-- what keeps DeliveryService unaware that this service exists.
	self.orderStatusChanged = Signal.new("OrderStatusChanged")
	self.orderDelivered = Signal.new("OrderDelivered")
	self.orderOpened = Signal.new("OrderOpened")

	self.running = false
	return self
end

function SampleOrderService:Init() end

function SampleOrderService:Start()
	self.running = true
	task.spawn(function()
		while self.running do
			task.wait(Timings.orderTickIntervalSeconds)
			local ok, err = pcall(function()
				self:Tick()
			end)
			if not ok then
				log:error("tick failed: %s", tostring(err))
			end
		end
	end)
end

-- ============================================================================
-- Ordering
-- ============================================================================

function SampleOrderService:CountOpenOrders(state: any): number
	local count = 0
	for _, order in pairs(state.orders) do
		if not Enums.OrderStatus.atLeast(order.status, Enums.OrderStatus.Opened) then
			count += 1
		end
	end
	return count
end

function SampleOrderService:OrderSample(player: Player, payload: any)
	local state = self.profiles:GetState(player)
	if not state then
		return Net.fail("NoProfile", "Your profile is still loading.")
	end

	local product = self.products:Get(player, payload.productId)
	if not product then
		return Net.fail("NotFound", "That product does not exist.")
	end

	local manufacturer = Manufacturers.get(payload.manufacturerId)
	if not manufacturer then
		return Net.fail("UnknownManufacturer", "That supplier does not exist.")
	end

	if #(product.spec.graphics or {}) == 0 then
		return Net.fail("NoDesign", "Add a graphic before sending this to a factory.")
	end

	if self.products:IsLocked(product) then
		return Net.fail("AlreadySampling", "A sample of this product is already being made.")
	end

	if self:CountOpenOrders(state) >= MAX_OPEN_ORDERS then
		return Net.fail("TooManyOrders", "You have too many samples in progress.")
	end

	-- Re-price from scratch. The quote the client is holding may be stale.
	local quote = self.manufacturers:BuildQuote(product.id, product.spec, payload.manufacturerId)
	if not quote then
		return Net.fail("QuoteFailed", "Could not price that order.")
	end

	if not quote.canFulfil then
		return Net.fail("CannotFulfil", quote.rejectionReason or "That supplier cannot make this.")
	end

	local cost = quote.sampleCostPence

	--[[
		The client tells us what it believes it is agreeing to. If the real cost
		is higher we refuse outright rather than charging the difference, because
		taking more money than the player saw on screen is never acceptable --
		even when the discrepancy is our own stale UI rather than an attack.
	]]
	if payload.acknowledgedCostPence ~= cost then
		log:warn("cost mismatch for %s: client said %d, server computed %d",
			player.Name, payload.acknowledgedCostPence, cost)
		return Net.fail("PriceChanged", string.format(
			"The price has changed to %s. Review the quote and try again.", Format.money(cost)))
	end

	if not self.profiles:CanAfford(player, cost) then
		return Net.fail("InsufficientFunds", string.format(
			"You need %s for this sample.", Format.money(cost)))
	end

	-- Debit FIRST. If this fails for any reason, no order is created.
	local charged, reason = self.profiles:AdjustCash(
		player,
		-cost,
		Enums.LedgerKind.SampleOrder,
		string.format("Sample \u{2014} %s (%s)", product.name, manufacturer.name)
	)

	if not charged then
		if reason == "InsufficientFunds" then
			return Net.fail("InsufficientFunds", string.format(
				"You need %s for this sample.", Format.money(cost)))
		end
		return Net.fail("ChargeFailed", "Could not take payment for that order.")
	end

	local now = os.time()
	local orderId: string

	local created = self.profiles:Mutate(player, function(s)
		orderId = Ids.next(s.counters, Ids.ORDER)

		local order: SampleOrder = {
			id = orderId,
			kind = Enums.OrderKind.Sample,
			productId = product.id,
			manufacturerId = payload.manufacturerId,
			productRevision = product.revision,

			-- The frozen record of what was actually sent to the factory.
			specSnapshot = TableKit.deepCopy(s.products[product.id].spec),

			status = Enums.OrderStatus.InProduction,
			costPence = cost,

			placedAt = now,
			productionEndsAt = now + math.floor(quote.productionSeconds),
			shippingEndsAt = now + math.floor(quote.productionSeconds + quote.shippingSeconds),
			deliveredAt = nil,
			openedAt = nil,
			resolvedAt = nil,

			quality = nil,
			parcelSpawned = false,
		}

		s.orders[orderId] = order
		table.insert(s.orderIndex, orderId)

		local target = s.products[product.id]
		table.insert(target.sampleOrderIds, orderId)
		target.activeSampleOrderId = orderId

		local relationship = s.manufacturers[payload.manufacturerId]
		if relationship then
			relationship.ordersPlaced += 1
			relationship.lastContactAt = now
		end

		return true
	end)

	if not created then
		-- Refund rather than leave the player charged for nothing.
		self.profiles:AdjustCash(player, cost, Enums.LedgerKind.Refund, "Failed sample order refund")
		return Net.fail("OrderFailed", "Could not place that order.")
	end

	-- Drive the product stage through its legal path.
	self.products:SetStage(player, product.id, Enums.ProductStage.SampleRequested, orderId)
	self.products:SetStage(player, product.id, Enums.ProductStage.SampleInProduction, orderId)

	self.profiles:SetFlag(player, Progression.Flags.firstSampleOrdered)
	self.profiles:Increment(player, Progression.Counters.samplesOrdered)
	self.profiles:Increment(player, Progression.Counters.penceSpentOnSamples, cost)

	log:info("%s ordered %s from %s for %s",
		player.Name, orderId, manufacturer.name, Format.money(cost))

	self.orderStatusChanged:fire(player, orderId, Enums.OrderStatus.InProduction)

	return Net.ok({
		orderId = orderId,
		costPence = cost,
		productionEndsAt = now + math.floor(quote.productionSeconds),
		shippingEndsAt = now + math.floor(quote.productionSeconds + quote.shippingSeconds),
	})
end

-- ============================================================================
-- Progression tick
-- ============================================================================

function SampleOrderService:Tick()
	local Players = game:GetService("Players")
	local now = os.time()

	for _, player in ipairs(Players:GetPlayers()) do
		local state = self.profiles:GetState(player)
		if state then
			for _, orderId in ipairs(state.orderIndex) do
				local order = state.orders[orderId]
				if order then
					self:AdvanceOrder(player, order, now)
				end
			end
		end
	end
end

function SampleOrderService:AdvanceOrder(player: Player, order: SampleOrder, now: number)
	if order.status == Enums.OrderStatus.InProduction and now >= order.productionEndsAt then
		--[[
			Quality is rolled when production FINISHES, not when the parcel is
			opened. The garment physically exists at this point, so its properties
			are fixed; opening the box only reveals them. The report is withheld
			from the client projection until Opened.
		]]
		local report = self.quality:Evaluate(order.id, order.manufacturerId, order.specSnapshot)

		self.profiles:Mutate(player, function(s)
			local target = s.orders[order.id]
			if not target then
				return false
			end
			target.status = Enums.OrderStatus.Shipped
			target.quality = report
			return true
		end)

		self.products:SetStage(player, order.productId, Enums.ProductStage.SampleShipped, order.id)
		self.orderStatusChanged:fire(player, order.id, Enums.OrderStatus.Shipped)
		log:debug("%s shipped", order.id)
		return
	end

	if order.status == Enums.OrderStatus.Shipped and now >= order.shippingEndsAt then
		self.profiles:Mutate(player, function(s)
			local target = s.orders[order.id]
			if not target then
				return false
			end
			target.status = Enums.OrderStatus.Delivered
			target.deliveredAt = now
			return true
		end)

		self.products:SetStage(player, order.productId, Enums.ProductStage.SampleReceived, order.id)
		self.profiles:SetFlag(player, Progression.Flags.firstParcelReceived)

		self.orderStatusChanged:fire(player, order.id, Enums.OrderStatus.Delivered)
		-- DeliveryService listens for this and puts a physical parcel in the world.
		self.orderDelivered:fire(player, order.id)
		log:info("%s delivered to %s", order.id, player.Name)
	end
end

-- ============================================================================
-- Opening and resolution
-- ============================================================================

function SampleOrderService:Get(player: Player, orderId: string): SampleOrder?
	local state = self.profiles:GetState(player)
	return state and state.orders[orderId] or nil
end

--[[
	Marks a parcel opened and returns the revealed report.

	Idempotent: opening an already-open parcel returns the same report rather
	than erroring, because the client may legitimately re-request it (reconnect,
	re-entering the inspection view).
]]
function SampleOrderService:OpenParcel(player: Player, payload: any)
	local order = self:Get(player, payload.orderId)
	if not order then
		return Net.fail("NotFound", "That order does not exist.")
	end

	if order.status == Enums.OrderStatus.InProduction or order.status == Enums.OrderStatus.Shipped then
		return Net.fail("NotArrived", "That parcel has not arrived yet.")
	end

	if not Enums.OrderStatus.atLeast(order.status, Enums.OrderStatus.Opened) then
		self.profiles:Mutate(player, function(s)
			local target = s.orders[payload.orderId]
			if not target then
				return false
			end
			target.status = Enums.OrderStatus.Opened
			target.openedAt = os.time()
			return true
		end)

		self.profiles:SetFlag(player, Progression.Flags.firstParcelOpened)
		self.profiles:Increment(player, Progression.Counters.parcelsOpened)
		self.orderOpened:fire(player, payload.orderId)
		log:info("%s opened %s", player.Name, payload.orderId)
	end

	local refreshed = self:Get(player, payload.orderId)
	return Net.ok({
		orderId = payload.orderId,
		quality = refreshed and refreshed.quality or nil,
		specSnapshot = refreshed and refreshed.specSnapshot or nil,
		manufacturerId = refreshed and refreshed.manufacturerId or nil,
	})
end

function SampleOrderService:GetSampleReport(player: Player, payload: any)
	local order = self:Get(player, payload.orderId)
	if not order then
		return Net.fail("NotFound", "That order does not exist.")
	end

	if not Enums.OrderStatus.atLeast(order.status, Enums.OrderStatus.Opened) then
		return Net.fail("NotOpened", "Open the parcel first.")
	end

	self.profiles:SetFlag(player, Progression.Flags.firstSampleInspected)

	return Net.ok({
		orderId = order.id,
		productId = order.productId,
		manufacturerId = order.manufacturerId,
		productRevision = order.productRevision,
		specSnapshot = order.specSnapshot,
		costPence = order.costPence,
		quality = order.quality,
		status = order.status,
	})
end

--[[
	Approve the sample, or reject it and bump the product revision so the next
	attempt is clearly a new one.

	The revision model is what lets this support multiple rounds later without
	rework: each sample records the revision it was made from, so a history of
	attempts is already recorded rather than needing to be reconstructed.
]]
function SampleOrderService:ResolveSample(player: Player, payload: any)
	local order = self:Get(player, payload.orderId)
	if not order then
		return Net.fail("NotFound", "That order does not exist.")
	end

	if not Enums.OrderStatus.atLeast(order.status, Enums.OrderStatus.Opened) then
		return Net.fail("NotOpened", "Open and inspect the sample first.")
	end

	if order.status == Enums.OrderStatus.Approved or order.status == Enums.OrderStatus.RevisionRequested then
		return Net.fail("AlreadyResolved", "You have already made a decision on this sample.")
	end

	local approving = payload.decision == "Approve"
	local newStatus = if approving then Enums.OrderStatus.Approved else Enums.OrderStatus.RevisionRequested

	self.profiles:Mutate(player, function(s)
		local target = s.orders[payload.orderId]
		if not target then
			return false
		end
		target.status = newStatus
		target.resolvedAt = os.time()

		local product = s.products[target.productId]
		if product then
			product.activeSampleOrderId = nil
			if approving then
				product.approvedSampleOrderId = target.id
			end
		end

		local relationship = s.manufacturers[target.manufacturerId]
		if relationship and approving then
			relationship.samplesApproved += 1
			-- A working relationship builds slowly and caps at 1.
			relationship.relationship = math.min(1, relationship.relationship + 0.15)
		end

		return true
	end)

	if approving then
		self.products:SetStage(player, order.productId, Enums.ProductStage.SampleApproved, order.id)
		self.profiles:SetFlag(player, Progression.Flags.firstSampleApproved)
		self.profiles:Increment(player, Progression.Counters.samplesApproved)
		log:info("%s approved %s", player.Name, order.id)
	else
		self.products:SetStage(player, order.productId, Enums.ProductStage.SampleRejected, payload.note)
		-- Return to Design so the player can change the spec and re-order.
		self.products:SetStage(player, order.productId, Enums.ProductStage.Design, "revision")
		self.products:BumpRevision(player, order.productId)
		self.profiles:SetFlag(player, Progression.Flags.firstRevisionRequested)
		self.profiles:Increment(player, Progression.Counters.samplesRejected)
		log:info("%s requested a revision on %s", player.Name, order.id)
	end

	self.orderStatusChanged:fire(player, order.id, newStatus)

	return Net.ok({ orderId = order.id, status = newStatus })
end

-- ============================================================================
-- Development
-- ============================================================================

--[[
	Collapses every in-flight deadline for a player so the next tick delivers.
	Reached only through DevService, which owns the authorisation check.
]]
function SampleOrderService:ForceDeliverAll(player: Player): number
	local moved = 0
	local now = os.time()

	self.profiles:Mutate(player, function(s)
		for _, order in pairs(s.orders) do
			if order.status == Enums.OrderStatus.InProduction or order.status == Enums.OrderStatus.Shipped then
				order.productionEndsAt = now - 1
				order.shippingEndsAt = now - 1
				moved += 1
			end
		end
		return moved > 0
	end)

	if moved > 0 then
		-- Run the state machine immediately rather than waiting for the tick, so
		-- the effect is instant when debugging.
		local state = self.profiles:GetState(player)
		if state then
			for _, orderId in ipairs(state.orderIndex) do
				local order = state.orders[orderId]
				if order then
					-- Two passes: InProduction -> Shipped, then Shipped -> Delivered.
					self:AdvanceOrder(player, order, os.time())
					local refreshed = state.orders[orderId]
					if refreshed then
						self:AdvanceOrder(player, refreshed, os.time())
					end
				end
			end
		end
	end

	return moved
end

return SampleOrderService
