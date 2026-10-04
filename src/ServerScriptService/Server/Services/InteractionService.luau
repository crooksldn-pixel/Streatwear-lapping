--!strict
--[[
	InteractionService

	Server-side registry and validation for every physical world interaction.

	== The trust model ==

	The client says "I interacted with the thing called X". That claim is a
	LOOKUP KEY and nothing more. The server:

	  1. resolves the name against its OWN registry -- a name the server never
		 registered simply does not exist
	  2. confirms the registered kind matches what the client claimed
	  3. re-measures the distance from the player's character to the real
		 instance, server-side
	  4. checks ownership, for objects belonging to one player (parcels)
	  5. runs the handler and returns a DIRECTIVE

	The client never decides what an interaction does. It receives an instruction
	and carries it out. An exploiter calling Interact with arbitrary names gets
	nothing back; one standing across the room gets a distance rejection.

	== Why ProximityPrompt ==

	The world-side presentation uses ProximityPrompt, which brings keyboard,
	gamepad and touch input, hold-to-activate and occlusion handling for free.
	Writing three input paths by hand would be worse in every respect. Prompts
	are created by the client from attributes, but they are only a trigger --
	nothing about the prompt grants permission, so a tampered prompt achieves
	nothing.
]]

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Types = require(Shared.Types)
local Enums = require(Shared.Enums)
local Net = require(Shared.Net.Net)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("Interaction")

local InteractionService = {}
InteractionService.__index = InteractionService

InteractionService.TAG = "Interactable"

--[[
	Hard ceiling on interaction range, applied on top of each object's own
	MaxDistance so a mis-authored world object cannot become remotely usable.

	The DEFAULT is deliberately short. The bedroom is 18x16 studs, and a 9-stud
	radius covered most of it -- standing next to a parcel by the door still put
	the player inside the laptop's radius across the room, and the laptop's
	prompt won. In a room this size, interaction ranges have to be close to arm's
	reach or objects steal each other's prompts.
]]
local ABSOLUTE_MAX_DISTANCE = 32
local DEFAULT_MAX_DISTANCE = 6

-- Slack added to the configured distance before rejecting, to absorb the
-- difference between what the client saw and where the server thinks the
-- character is. Without it, a player on a laggy connection gets refused while
-- visibly standing next to the object.
local DISTANCE_TOLERANCE = 4

export type Registration = {
	name: string,
	kind: string,
	instance: Instance,
	ownerUserId: number?, -- nil = world object, usable by anyone
	handler: (player: Player, registration: Registration) -> Types.InteractionDirective?,
	maxDistance: number,
	enabled: boolean,
	context: { [string]: any },
}

function InteractionService.new(profileService: any)
	local self = setmetatable({}, InteractionService)
	self.profiles = profileService
	self.registry = {} :: { [string]: Registration }
	return self
end

function InteractionService:Init() end
function InteractionService:Start() end

-- ============================================================================
-- Registration
-- ============================================================================

--[[
	Registers an instance as interactable.

	The NAME is the network identity, so it must be unique and stable. World
	objects use fixed names ("BedroomLaptop"); per-player objects embed their
	owning entity id ("Parcel_ORD-3"), which is what makes ownership checkable
	without a second lookup.
]]
function InteractionService:Register(registration: {
	name: string,
	kind: string,
	instance: Instance,
	ownerUserId: number?,
	handler: (player: Player, registration: any) -> Types.InteractionDirective?,
	maxDistance: number?,
	promptText: string?,
	actionText: string?,
	holdDuration: number?,
	context: { [string]: any }?,
}): Registration
	assert(Enums.InteractionKind.isValid(registration.kind),
		string.format("unknown interaction kind %q", tostring(registration.kind)))

	if self.registry[registration.name] then
		log:warn("re-registering %q", registration.name)
	end

	local maxDistance = math.min(registration.maxDistance or DEFAULT_MAX_DISTANCE, ABSOLUTE_MAX_DISTANCE)

	local entry: Registration = {
		name = registration.name,
		kind = registration.kind,
		instance = registration.instance,
		ownerUserId = registration.ownerUserId,
		handler = registration.handler,
		maxDistance = maxDistance,
		enabled = true,
		context = registration.context or {},
	}

	self.registry[registration.name] = entry

	--[[
		Attributes drive the CLIENT's prompt presentation. They are display data
		only -- the authoritative copy of every one of these values lives in the
		registry above, and the server reads the registry, never the attributes.
		A player editing them locally changes only what their own prompt says.
	]]
	local instance = registration.instance
	instance:SetAttribute("InteractionName", registration.name)
	instance:SetAttribute("InteractionKind", registration.kind)
	instance:SetAttribute("InteractionPrompt", registration.promptText or "")
	instance:SetAttribute("InteractionAction", registration.actionText or "Use")
	instance:SetAttribute("InteractionHold", registration.holdDuration or 0)
	instance:SetAttribute("InteractionDistance", maxDistance)
	instance:SetAttribute("InteractionOwner", registration.ownerUserId or 0)

	CollectionService:AddTag(instance, InteractionService.TAG)

	-- Clean up automatically if the world object goes away.
	instance.Destroying:Once(function()
		self:Unregister(registration.name)
	end)

	log:debug("registered %s (%s)", registration.name, registration.kind)
	return entry
end

function InteractionService:Unregister(name: string)
	local entry = self.registry[name]
	if not entry then
		return
	end
	if entry.instance and entry.instance.Parent then
		CollectionService:RemoveTag(entry.instance, InteractionService.TAG)
	end
	self.registry[name] = nil
end

function InteractionService:SetEnabled(name: string, enabled: boolean)
	local entry = self.registry[name]
	if entry then
		entry.enabled = enabled
		if entry.instance and entry.instance.Parent then
			entry.instance:SetAttribute("InteractionEnabled", enabled)
		end
	end
end

function InteractionService:Get(name: string): Registration?
	return self.registry[name]
end

-- ============================================================================
-- Validation
-- ============================================================================

local function instancePosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		local ok, pivot = pcall(function()
			return instance:GetPivot().Position
		end)
		if ok then
			return pivot
		end
	end
	if instance:IsA("Attachment") then
		return instance.WorldPosition
	end
	return nil
end

--[[
	The single entry point for all interaction requests.
	Returns a Response whose data is an InteractionDirective.
]]
function InteractionService:HandleInteract(player: Player, payload: any)
	local entry = self.registry[payload.targetName]

	-- A name the server never registered. Nothing is leaked about why.
	if not entry then
		log:debug("%s requested unknown interactable %q", player.Name, tostring(payload.targetName))
		return Net.fail("NoTarget", "There is nothing there.")
	end

	if not entry.enabled then
		return Net.fail("Disabled", "That cannot be used right now.")
	end

	-- The claimed kind must match what we registered. A mismatch means the
	-- client is confused or probing.
	if entry.kind ~= payload.kind then
		log:warn("%s claimed kind %q for %q (registered as %q)",
			player.Name, tostring(payload.kind), entry.name, entry.kind)
		return Net.fail("KindMismatch", "That cannot be used right now.")
	end

	if not entry.instance or not entry.instance.Parent then
		self:Unregister(entry.name)
		return Net.fail("NoTarget", "There is nothing there.")
	end

	-- Ownership, for per-player objects such as parcels.
	if entry.ownerUserId and entry.ownerUserId ~= player.UserId then
		log:warn("%s tried to interact with %s owned by %d", player.Name, entry.name, entry.ownerUserId)
		return Net.fail("NotYours", "That is not yours.")
	end

	-- Server-side distance check against the real instance position.
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return Net.fail("NoCharacter", "You cannot do that right now.")
	end

	local targetPosition = instancePosition(entry.instance)
	if not targetPosition then
		return Net.fail("NoTarget", "There is nothing there.")
	end

	local distance = (root.Position - targetPosition).Magnitude
	if distance > entry.maxDistance + DISTANCE_TOLERANCE then
		log:warn("%s was %.1f studs from %s (limit %.1f)",
			player.Name, distance, entry.name, entry.maxDistance)
		return Net.fail("TooFar", "You are too far away.")
	end

	local ok, directive = pcall(entry.handler, player, entry)
	if not ok then
		log:error("handler for %s failed: %s", entry.name, tostring(directive))
		return Net.fail("HandlerError", "That did not work.")
	end

	if not directive then
		return Net.fail("NoResult", "Nothing happened.")
	end

	return Net.ok(directive)
end

-- Removes every registration owned by a player. Called when they leave, so a
-- disconnected player's parcels do not linger in the registry.
function InteractionService:ClearForPlayer(userId: number)
	for name, entry in pairs(self.registry) do
		if entry.ownerUserId == userId then
			self:Unregister(name)
		end
	end
end

return InteractionService
