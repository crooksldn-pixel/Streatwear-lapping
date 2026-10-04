--!strict
--[[
	ParcelController

	The opening sequence: the box opens, the garment comes out, and the player
	sees what they actually made.

	== Why this gets its own moment ==

	This is the payoff of the entire loop. The player designed something, chose a
	factory, spent real money and waited. Dropping the result into a menu would
	throw that away. So the box physically opens in the room, the garment rises
	out of it, and only then does the inspection view appear.

	The sequence is short on purpose -- under two seconds. It is a beat, not a
	cutscene, and it plays every single time without becoming tiresome.

	== The garment is the real one ==

	It is built by GarmentBuilder from the ORDER'S FROZEN SPEC SNAPSHOT, with the
	quality report applied. So a bad sample visibly arrives crooked, off-shade
	and badly printed. The player sees the factory's work before reading a single
	number about it.
]]

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage").Shared
local Manufacturers = require(Shared.Config.Manufacturers)
local Timings = require(Shared.Config.Timings)
local GarmentBuilder = require(Shared.Garment.GarmentBuilder)
local Ids = require(Shared.Util.Ids)
local Net = require(Shared.Net.Net)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("Parcel")

local ParcelController = {}
ParcelController.__index = ParcelController

function ParcelController.new(controllers: any)
	local self = setmetatable({}, ParcelController)
	self.controllers = controllers
	self.busy = false
	return self
end

function ParcelController:Init() end

function ParcelController:Start()
	-- The server announces arrivals; the client notifies and points the player
	-- at the door.
	Net.onClientEvent("WorldEvent", function(event)
		if type(event) ~= "table" then
			return
		end

		if event.kind == "ParcelArrived" then
			local manufacturer = Manufacturers.get(event.manufacturerId)
			self.controllers.notifications:Push({
				title = "A parcel arrived",
				body = string.format(
					"%s left it by your door.",
					manufacturer and manufacturer.name or "Your supplier"
				),
				kind = "positive",
				duration = 9,
			})
		end
	end)
end

-- ============================================================================
-- Opening sequence
-- ============================================================================

function ParcelController:FindParcel(orderId: string): Model?
	local model = workspace:FindFirstChild("Parcel_" .. orderId)
	return model and model:IsA("Model") and model or nil
end

function ParcelController:PlayOpening(orderId: string)
	if self.busy then
		return
	end
	self.busy = true

	task.spawn(function()
		-- Tell the server first. This is what reveals the quality report, and it
		-- is authoritative -- the animation is presentation of a result that has
		-- already been decided.
		local response = Net.invoke("OpenParcel", { orderId = orderId })
		if not response.ok then
			self.busy = false
			self.controllers.notifications:Push({
				title = response.message or "Could not open that",
				kind = "warning",
			})
			return
		end

		local data = response.data
		local parcel = self:FindParcel(orderId)

		if parcel then
			self:AnimateOpen(parcel, data, orderId)
		else
			-- The box may already be gone (rejoin, cleanup). Skip straight to the
			-- inspection rather than failing.
			log:debug("no parcel model for %s; opening inspection directly", orderId)
			self.busy = false
			self.controllers.inspection:Open(orderId)
		end
	end)
end

function ParcelController:AnimateOpen(parcel: Model, data: any, orderId: string)
	local box = parcel.PrimaryPart
	if not box then
		self.busy = false
		self.controllers.inspection:Open(orderId)
		return
	end

	-- Focus the camera on the box so the reveal happens where the player is
	-- looking, rather than somewhere off screen.
	self.controllers.camera:FocusOn(box, {
		distance = 5.5,
		height = 2.4,
		pitch = -22,
		fov = 50,
		duration = 0.4,
	})

	task.wait(0.35)

	-- ---- flaps open ----
	local tape = parcel:FindFirstChild("Tape")
	if tape and tape:IsA("BasePart") then
		-- Tape splits and falls away.
		tape.Anchored = false
		tape.CanCollide = false
		Debris:AddItem(tape, 2)
	end

	local lid = Instance.new("Part")
	lid.Name = "Lid"
	lid.Size = Vector3.new(box.Size.X, 0.08, box.Size.Z)
	lid.Color = box.Color
	lid.Material = Enum.Material.Cardboard
	lid.Anchored = true
	lid.CanCollide = false
	lid.CFrame = box.CFrame * CFrame.new(0, box.Size.Y / 2, 0)
	lid.Parent = parcel

	-- Hinge the lid open backwards.
	local hingeOrigin = box.CFrame * CFrame.new(0, box.Size.Y / 2, -box.Size.Z / 2)
	local openTween = TweenService:Create(
		lid,
		TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ CFrame = hingeOrigin * CFrame.Angles(math.rad(-115), 0, 0) * CFrame.new(0, 0, box.Size.Z / 2) }
	)
	openTween:Play()

	-- ---- garment rises ----
	local state = self.controllers.state:Get()
	local brandName = state and state.identity.name ~= "" and state.identity.name or "YOUR BRAND"

	local order = state and state.orders[orderId]
	local spec = data.specSnapshot or (order and order.specSnapshot)
	local quality = data.quality or (order and order.quality)

	if spec then
		-- Built from the frozen snapshot with the real quality applied, so the
		-- defects are visible before any numbers are read.
		local garment = GarmentBuilder.build(spec, {
			brandName = brandName,
			quality = quality and quality.dimensions or nil,
			seed = Ids.hash(orderId),
			forViewport = true,
		})
		garment.Name = "RevealGarment"

		for _, part in ipairs(garment:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.Anchored = true
			end
		end

		-- Start folded inside the box, rise and turn to face the player.
		local startCFrame = box.CFrame * CFrame.new(0, -0.2, 0) * CFrame.Angles(math.rad(-90), 0, 0)
		garment:PivotTo(startCFrame)
		garment.Parent = workspace

		task.wait(0.18)

		local endCFrame = box.CFrame
			* CFrame.new(0, box.Size.Y / 2 + 1.9, 0)
			* CFrame.Angles(0, math.rad(180), 0)

		-- Tween the model by driving a proxy part, since Models cannot be tweened
		-- directly.
		local proxy = Instance.new("CFrameValue")
		proxy.Value = startCFrame
		local connection = proxy.Changed:Connect(function(value)
			if garment.Parent then
				garment:PivotTo(value)
			end
		end)

		local riseTween = TweenService:Create(
			proxy,
			TweenInfo.new(Timings.parcelOpenSeconds, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Value = endCFrame }
		)
		riseTween:Play()
		riseTween.Completed:Wait()
		connection:Disconnect()
		proxy:Destroy()

		task.wait(0.45)

		-- Fade the garment out as the inspection view takes over, so the physical
		-- object hands off to the detailed one rather than vanishing.
		for _, part in ipairs(garment:GetDescendants()) do
			if part:IsA("BasePart") then
				TweenService:Create(part, TweenInfo.new(0.3), { Transparency = 1 }):Play()
			end
		end
		Debris:AddItem(garment, 0.4)
	end

	self.busy = false
	self.controllers.inspection:Open(orderId)
end

return ParcelController
