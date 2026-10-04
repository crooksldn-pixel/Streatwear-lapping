--!strict
--[[
	StateController

	A read-only mirror of the server's brand state.

	The client NEVER writes to this. Every change arrives as a projection pushed
	from the server, so there is exactly one way state can change on the client:
	the server said so. That removes the whole class of bugs where optimistic
	local updates drift out of sync with authority, and it means an exploiter
	editing this table changes only what they personally see -- the server's copy
	is untouched and every action is re-validated against it.

	Controllers and apps subscribe via `changed`.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net.Net)
local Signal = require(Shared.Util.Signal)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("State")

local StateController = {}
StateController.__index = StateController

function StateController.new()
	local self = setmetatable({}, StateController)
	self.state = nil :: any
	self.changed = Signal.new("StateChanged")
	self.ready = Signal.new("StateReady")
	self.hasLoaded = false
	return self
end

function StateController:Init()
	Net.onClientEvent("StateChanged", function(projection)
		self:Apply(projection)
	end)
end

function StateController:Start()
	-- Pull once at startup. The server also pushes on load, but a player who
	-- joins mid-push would otherwise wait for the next change.
	task.spawn(function()
		local response = Net.invoke("GetState")
		if response.ok then
			self:Apply(response.data)
		else
			log:warn("initial GetState failed: %s", tostring(response.error))
			-- Retry a few times; a profile may still be loading.
			for attempt = 1, 5 do
				task.wait(1 + attempt)
				local retry = Net.invoke("GetState")
				if retry.ok then
					self:Apply(retry.data)
					return
				end
			end
			log:error("could not load state after retries")
		end
	end)
end

function StateController:Apply(projection: any)
	if type(projection) ~= "table" then
		return
	end

	self.state = projection

	if not self.hasLoaded then
		self.hasLoaded = true
		self.ready:fire(projection)
	end

	self.changed:fire(projection)
end

function StateController:Get(): any
	return self.state
end

function StateController:IsReady(): boolean
	return self.hasLoaded
end

-- Convenience accessors used across apps.

function StateController:BrandName(): string
	local state = self.state
	if state and state.identity.created and state.identity.name ~= "" then
		return state.identity.name
	end
	return "UNTITLED"
end

function StateController:HasBrand(): boolean
	return self.state ~= nil and self.state.identity.created == true
end

function StateController:Cash(): number
	return self.state and self.state.finances.cashPence or 0
end

function StateController:GetProduct(productId: string): any
	return self.state and self.state.products[productId] or nil
end

function StateController:GetOrder(orderId: string): any
	return self.state and self.state.orders[orderId] or nil
end

-- Products in display order, excluding archived ones.
function StateController:ActiveProducts(): { any }
	local out = {}
	local state = self.state
	if not state then
		return out
	end
	for _, productId in ipairs(state.productOrder) do
		local product = state.products[productId]
		if product and product.stage ~= "Archived" then
			table.insert(out, product)
		end
	end
	return out
end

return StateController
