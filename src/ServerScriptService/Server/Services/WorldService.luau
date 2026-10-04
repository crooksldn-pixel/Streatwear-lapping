--!strict
--[[
	WorldService

	Binds the authored world geometry to game systems.

	== Authored, not generated ==

	The bedroom is real saved geometry in Workspace, not something built at
	runtime. That matters: it can be opened and edited by hand in Studio like any
	normal Roblox build, it does not cost startup time, and it is version-
	controlled with the place. This service only LOCATES the parts it needs and
	attaches behaviour.

	Lookups are by name against a declared manifest. A missing marker is reported
	loudly at startup rather than causing a confusing nil failure later, because
	a world that is quietly missing its delivery point produces samples that
	never arrive.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Enums = require(Shared.Enums)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("World")

local WorldService = {}
WorldService.__index = WorldService

WorldService.ROOT_NAME = "Bedroom"

-- Named parts the game depends on. `required` entries abort startup loudly.
local MANIFEST = {
	{ name = "Laptop", required = true, description = "the desk computer" },
	{ name = "DeliveryPoint", required = true, description = "where parcels arrive" },
	{ name = "Bed", required = false, description = "the bed" },
	{ name = "Moodboard", required = false, description = "wall space for pinned work" },
	{ name = "SpawnPoint", required = false, description = "player spawn" },
}

function WorldService.new(profileService: any, interactionService: any)
	local self = setmetatable({}, WorldService)
	self.profiles = profileService
	self.interactions = interactionService
	self.markers = {} :: { [string]: Instance }
	self.root = nil :: Instance?
	return self
end

function WorldService:Init()
	local root = workspace:FindFirstChild(WorldService.ROOT_NAME)
	if not root then
		log:error("Workspace.%s is missing -- the world has not been built", WorldService.ROOT_NAME)
		return
	end
	self.root = root

	for _, entry in ipairs(MANIFEST) do
		local found = root:FindFirstChild(entry.name, true)
		if found then
			self.markers[entry.name] = found
		elseif entry.required then
			log:error("missing required world marker %q (%s)", entry.name, entry.description)
		else
			log:debug("optional world marker %q not present", entry.name)
		end
	end

	log:info("world bound (%d markers)", (function()
		local count = 0
		for _ in pairs(self.markers) do
			count += 1
		end
		return count
	end)())
end

function WorldService:Start()
	self:RegisterLaptop()
	self:RegisterBed()
end

function WorldService:GetMarker(name: string): Instance?
	return self.markers[name]
end

--[[
	Where parcels land. Returns a CFrame sitting on top of the marker rather than
	inside it, so a box rests on the floor instead of intersecting it.
]]
function WorldService:GetDeliveryPoint(): CFrame?
	local marker = self.markers.DeliveryPoint
	if not marker then
		return nil
	end
	if marker:IsA("BasePart") then
		return marker.CFrame * CFrame.new(0, marker.Size.Y / 2 + 0.76, 0)
	end
	if marker:IsA("Model") then
		return marker:GetPivot()
	end
	return nil
end

-- ============================================================================
-- Interactions
-- ============================================================================

function WorldService:RegisterLaptop()
	local laptop = self.markers.Laptop
	if not laptop then
		return
	end

	self.interactions:Register({
		name = "BedroomLaptop",
		kind = Enums.InteractionKind.Laptop,
		instance = laptop,
		-- Short: the room is small and a wide radius steals the parcel's prompt
		-- from across the room. See the note in InteractionService.
		maxDistance = 5.5,
		promptText = "Laptop",
		actionText = "Use",
		handler = function(player)
			local state = self.profiles:GetState(player)
			if not state then
				return nil
			end

			--[[
				The server decides which app opens. A player without a brand lands
				on Brand Setup; everyone else gets the desktop. Deciding this here
				rather than client-side means the laptop cannot be used to reach an
				app the player has not unlocked.
			]]
			local initialApp = if state.identity.created then "desktop" else "brand"

			return {
				action = "OpenOS",
				payload = { initialApp = initialApp },
			}
		end,
	})
end

function WorldService:RegisterBed()
	local bed = self.markers.Bed
	if not bed then
		return
	end

	-- Not a mechanic yet; present so the room responds to the player rather than
	-- being scenery with one usable object in it.
	self.interactions:Register({
		name = "BedroomBed",
		kind = Enums.InteractionKind.Bed,
		instance = bed,
		maxDistance = 5,
		promptText = "Bed",
		actionText = "Rest",
		handler = function()
			return {
				action = "Message",
				payload = { text = "No time to sleep. There is a brand to build." },
			}
		end,
	})
end

return WorldService
