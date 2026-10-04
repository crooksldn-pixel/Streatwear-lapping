--!strict
--[[
	DeliveryService

	Puts delivered samples into the world as PHYSICAL parcels.

	== Why this service exists at all ==

	The brief is explicit: a delivered sample must not simply appear in a UI
	inventory. The parcel is the moment the simulation becomes tangible -- the
	player sees a box by the door, walks to it, opens it, and the garment they
	designed is inside. Routing that through a menu would throw away the single
	most important beat in the loop.

	== Decoupling ==

	This service knows nothing about SampleOrderService. It listens for an
	`orderDelivered` signal and reacts. Equally, the parcel does not store the
	garment -- it stores an ORDER ID. The garment is built on demand from that
	order's frozen spec snapshot, so the box genuinely contains the thing that
	was made rather than a copy assembled separately.

	== Rejoin safety ==

	Parcels are runtime instances and do not survive a server restart, but the
	ORDER does. On join, any order that is Delivered-but-not-Opened has its
	parcel re-spawned. A player cannot lose a paid-for sample by leaving.
]]

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage").Shared
local Enums = require(Shared.Enums)
local Manufacturers = require(Shared.Config.Manufacturers)
local Timings = require(Shared.Config.Timings)
local Net = require(Shared.Net.Net)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("Delivery")

local DeliveryService = {}
DeliveryService.__index = DeliveryService

-- Parcels are placed in a small arc around the delivery marker so several
-- arriving at once do not stack inside one another.
local PARCEL_SPREAD_STUDS = 1.4

function DeliveryService.new(
	profileService: any,
	sampleOrderService: any,
	interactionService: any,
	worldService: any
)
	local self = setmetatable({}, DeliveryService)
	self.profiles = profileService
	self.orders = sampleOrderService
	self.interactions = interactionService
	self.world = worldService

	-- Live parcel models, keyed "userId:orderId".
	self.parcels = {} :: { [string]: Model }
	return self
end

function DeliveryService:Init() end

function DeliveryService:Start()
	-- React to deliveries without the order service knowing we exist.
	self.orders.orderDelivered:connect(function(player: Player, orderId: string)
		self:SpawnParcel(player, orderId)
	end)

	-- Re-spawn parcels for anything delivered but never opened.
	self.profiles.playerReady:connect(function(player: Player, state: any)
		task.defer(function()
			self:RestoreParcels(player, state)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:ClearForPlayer(player)
	end)
end

local function parcelKey(userId: number, orderId: string): string
	return string.format("%d:%s", userId, orderId)
end

-- ============================================================================
-- Parcel construction
-- ============================================================================

--[[
	Builds the box.

	Deliberately a plain assembly of parts rather than an imported model: it has
	no asset dependency, it is tiny, and the courier label is a SurfaceGui
	carrying the real manufacturer's name and city. That label is what makes the
	box feel like it came from Faisalabad rather than from a spawner.
]]
function DeliveryService:BuildParcelModel(order: any, brandName: string): Model
	local manufacturer = Manufacturers.get(order.manufacturerId)

	local model = Instance.new("Model")
	model.Name = "Parcel_" .. order.id

	local box = Instance.new("Part")
	box.Name = "Box"
	box.Size = Vector3.new(2.2, 1.5, 1.6)
	box.Color = Color3.fromRGB(176, 148, 112)
	box.Material = Enum.Material.Cardboard
	box.Anchored = true
	box.CanCollide = true
	box.TopSurface = Enum.SurfaceType.Smooth
	box.BottomSurface = Enum.SurfaceType.Smooth
	box.Parent = model
	model.PrimaryPart = box

	-- Packing tape down the lid seam.
	local tape = Instance.new("Part")
	tape.Name = "Tape"
	tape.Size = Vector3.new(2.22, 0.02, 0.34)
	tape.Color = Color3.fromRGB(206, 190, 160)
	tape.Material = Enum.Material.SmoothPlastic
	tape.Anchored = true
	tape.CanCollide = false
	tape.CFrame = box.CFrame * CFrame.new(0, 0.76, 0)
	tape.Parent = model

	-- Courier label on the top face.
	local label = Instance.new("Part")
	label.Name = "Label"
	label.Size = Vector3.new(1.1, 0.02, 0.72)
	label.Color = Color3.fromRGB(240, 238, 232)
	label.Material = Enum.Material.SmoothPlastic
	label.Anchored = true
	label.CanCollide = false
	label.CFrame = box.CFrame * CFrame.new(0.42, 0.77, 0.2)
	label.Parent = model

	local surface = Instance.new("SurfaceGui")
	surface.Face = Enum.NormalId.Top
	surface.CanvasSize = Vector2.new(220, 144)
	surface.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	surface.LightInfluence = 0.4
	surface.Parent = label

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.PaddingTop = UDim.new(0, 8)
	padding.Parent = surface

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 3)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = surface

	local function labelLine(text: string, size: number, weight: Enum.FontWeight, colour: Color3, order_: number)
		local line = Instance.new("TextLabel")
		line.Size = UDim2.new(1, 0, 0, size + 4)
		line.BackgroundTransparency = 1
		line.Text = text
		-- BuilderSans: Inter fails to load at runtime. See the note in UI.Theme.
		line.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", weight)
		line.TextSize = size
		line.TextColor3 = colour
		line.TextXAlignment = Enum.TextXAlignment.Left
		line.TextTruncate = Enum.TextTruncate.AtEnd
		line.RichText = false
		line.LayoutOrder = order_
		line.Parent = surface
		return line
	end

	labelLine("AIR FREIGHT", 11, Enum.FontWeight.Bold, Color3.fromRGB(120, 120, 126), 1)
	labelLine(
		manufacturer and string.upper(manufacturer.name) or "SUPPLIER",
		15, Enum.FontWeight.Bold, Color3.fromRGB(24, 24, 26), 2)
	labelLine(
		manufacturer and (manufacturer.city .. ", " .. manufacturer.country) or "",
		11, Enum.FontWeight.Medium, Color3.fromRGB(96, 96, 102), 3)
	labelLine("TO: " .. string.upper(brandName), 12, Enum.FontWeight.SemiBold, Color3.fromRGB(24, 24, 26), 4)
	labelLine(order.id .. "  \u{2022}  1 PC SAMPLE", 10, Enum.FontWeight.Medium, Color3.fromRGB(120, 120, 126), 5)

	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") and part ~= box then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = box
			weld.Part1 = part
			weld.Parent = box
		end
	end

	return model
end

-- ============================================================================
-- Spawning
-- ============================================================================

function DeliveryService:SpawnParcel(player: Player, orderId: string)
	local order = self.orders:Get(player, orderId)
	if not order then
		return
	end

	-- Only an undelivered-but-arrived parcel should exist in the world.
	if order.status ~= Enums.OrderStatus.Delivered then
		return
	end

	local key = parcelKey(player.UserId, orderId)
	if self.parcels[key] then
		return -- already standing there
	end

	local dropPoint = self.world:GetDeliveryPoint()
	if not dropPoint then
		log:error("no delivery point in the world; cannot place %s", orderId)
		return
	end

	local state = self.profiles:GetState(player)
	local brandName = state and state.identity.name ~= "" and state.identity.name or "YOUR BRAND"

	local model = self:BuildParcelModel(order, brandName)

	-- Spread parcels so several deliveries do not intersect.
	local existing = 0
	for existingKey in pairs(self.parcels) do
		if string.sub(existingKey, 1, #tostring(player.UserId) + 1) == tostring(player.UserId) .. ":" then
			existing += 1
		end
	end
	local angle = existing * 0.9
	local offset = Vector3.new(math.sin(angle) * PARCEL_SPREAD_STUDS, 0, math.cos(angle) * PARCEL_SPREAD_STUDS * 0.5)

	model:PivotTo(dropPoint * CFrame.new(offset) * CFrame.Angles(0, math.rad(existing * 23), 0))
	model.Parent = workspace

	self.parcels[key] = model

	-- Register the interaction. The parcel is owned, so only its player can
	-- open it; InteractionService enforces that.
	self.interactions:Register({
		name = "Parcel_" .. tostring(player.UserId) .. "_" .. orderId,
		kind = Enums.InteractionKind.Parcel,
		instance = model,
		ownerUserId = player.UserId,
		-- Short, to match the room's scale. See the note in InteractionService.
		maxDistance = 5.5,
		promptText = "Parcel",
		actionText = "Open",
		holdDuration = 0.45,
		context = { orderId = orderId },
		handler = function(interactingPlayer, registration)
			return self:HandleParcelOpened(interactingPlayer, registration)
		end,
	})

	self.profiles:Mutate(player, function(s)
		local target = s.orders[orderId]
		if target then
			target.parcelSpawned = true
			return true
		end
		return false
	end)

	log:info("parcel for %s placed for %s", orderId, player.Name)

	-- Tell the client so it can notify and point the player at the door.
	pcall(function()
		Net.fireClient("WorldEvent", player, {
			kind = "ParcelArrived",
			orderId = orderId,
			manufacturerId = order.manufacturerId,
		})
	end)
end

function DeliveryService:RestoreParcels(player: Player, state: any)
	local restored = 0
	for _, orderId in ipairs(state.orderIndex) do
		local order = state.orders[orderId]
		-- Delivered but never opened: the box is still owed to the player.
		if order and order.status == Enums.OrderStatus.Delivered then
			self:SpawnParcel(player, orderId)
			restored += 1
		end
	end
	if restored > 0 then
		log:info("restored %d parcel(s) for %s", restored, player.Name)
	end
end

-- ============================================================================
-- Opening
-- ============================================================================

--[[
	The interaction handler. Returns a directive telling the client to play the
	opening sequence; the authoritative state change happens in
	SampleOrderService when the client follows up with OpenParcel.

	The box is removed here because the interaction has been validated -- a
	player who triggered this is genuinely standing next to their own parcel.
]]
function DeliveryService:HandleParcelOpened(player: Player, registration: any)
	local orderId = registration.context.orderId
	local order = self.orders:Get(player, orderId)
	if not order then
		return nil
	end

	local key = parcelKey(player.UserId, orderId)
	local model = self.parcels[key]

	if model then
		self.interactions:Unregister(registration.name)
		self.parcels[key] = nil
		-- Let the client's opening animation play against the real box before it
		-- disappears.
		Debris:AddItem(model, Timings.parcelOpenSeconds + 0.6)
	end

	return {
		action = "OpenParcel",
		payload = {
			orderId = orderId,
			manufacturerId = order.manufacturerId,
		},
	}
end

function DeliveryService:ClearForPlayer(player: Player)
	local prefix = tostring(player.UserId) .. ":"
	for key, model in pairs(self.parcels) do
		if string.sub(key, 1, #prefix) == prefix then
			if model and model.Parent then
				model:Destroy()
			end
			self.parcels[key] = nil
		end
	end
	self.interactions:ClearForPlayer(player.UserId)
end

return DeliveryService
