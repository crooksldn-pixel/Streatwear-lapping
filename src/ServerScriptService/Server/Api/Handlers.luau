--!strict
--[[
	Api.Handlers

	The single place client traffic enters the server.

	Every client-callable route is bound here, and the binding helper makes the
	safety steps structural rather than optional. For each call, in order:

		1. the route must exist in Protocol
		2. rate limit for this player on this route
		3. payload validated against the route's schema; the handler receives a
		   freshly built table containing ONLY validated fields
		4. the player must have a loaded profile
		5. handler runs inside pcall -- a thrown error becomes a clean failure
		   response rather than a hung RemoteFunction

	A handler cannot opt out of any of this, because it never sees the raw call.
	That is the point: adding a route later cannot accidentally skip validation.

	== Why RemoteFunction errors matter ==

	An erroring RemoteFunction handler leaves the CLIENT yielding forever. Every
	path here therefore returns a well-formed Response, including the failure
	paths, so the UI always gets an answer.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Protocol = require(Shared.Net.Protocol)
local Net = require(Shared.Net.Net)
local Validate = require(Shared.Util.Validate)
local DevConfig = require(Shared.Config.Dev)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("Api")

local Handlers = {}
Handlers.__index = Handlers

function Handlers.new(services: any)
	local self = setmetatable({}, Handlers)
	self.services = services

	--[[
		Rate limit buckets: [userId][routeName] = { windowStart, count }.
		A fixed window is enough here -- the limits exist to stop floods and
		scripted abuse, not to shape traffic precisely.
	]]
	self.buckets = {} :: { [number]: { [string]: { windowStart: number, count: number } } }

	return self
end

function Handlers:Init() end

-- ============================================================================
-- Rate limiting
-- ============================================================================

function Handlers:CheckRate(player: Player, route: any): boolean
	local userBuckets = self.buckets[player.UserId]
	if not userBuckets then
		userBuckets = {}
		self.buckets[player.UserId] = userBuckets
	end

	local bucket = userBuckets[route.name]
	local now = os.clock()

	if not bucket or now - bucket.windowStart >= 60 then
		userBuckets[route.name] = { windowStart = now, count = 1 }
		return true
	end

	bucket.count += 1
	if bucket.count > route.maxPerMinute then
		return false
	end

	return true
end

-- ============================================================================
-- Binding
-- ============================================================================

--[[
	Binds one RemoteFunction route.

	`handler` receives (player, cleanedPayload) and returns a Response. It never
	sees unvalidated input and cannot bypass the checks above.
]]
function Handlers:BindFunction(routeName: string, handler: (Player, any) -> any)
	local route = Protocol.get(routeName)
	assert(route, string.format("unknown route %q", routeName))
	assert(route.kind == Protocol.FUNCTION, string.format("%q is not a RemoteFunction", routeName))
	assert(route.schema, string.format("%q has no schema", routeName))

	local remote = Net.getFunction(routeName)

	remote.OnServerInvoke = function(player: Player, rawPayload: any)
		-- Rate limit before doing any work on the payload.
		if not self:CheckRate(player, route) then
			log:warn("rate limit hit: %s on %s", player.Name, routeName)
			return Net.fail("RateLimited", "Slow down a moment.")
		end

		local valid, cleanedOrIssue = Validate.payload(rawPayload, route.schema :: any)
		if not valid then
			if DevConfig.logRemoteTraffic then
				log:warn("invalid payload on %s from %s: %s",
					routeName, player.Name, tostring(cleanedOrIssue))
			end
			-- The internal reason is logged, never returned: it would tell an
			-- attacker exactly which field to adjust next.
			return Net.fail("InvalidRequest", "That request was not valid.")
		end

		if not self.services.profiles:GetState(player) then
			return Net.fail("NoProfile", "Your profile is still loading.")
		end

		if DevConfig.logRemoteTraffic then
			log:debug("%s -> %s", player.Name, routeName)
		end

		local ok, result = pcall(handler, player, cleanedOrIssue)
		if not ok then
			log:error("handler %s errored for %s: %s", routeName, player.Name, tostring(result))
			return Net.fail("ServerError", "Something went wrong. Try again.")
		end

		-- A handler returning nothing would hang the client; make it a failure.
		if type(result) ~= "table" then
			log:error("handler %s returned %s instead of a Response", routeName, typeof(result))
			return Net.fail("ServerError", "Something went wrong. Try again.")
		end

		return result
	end
end

-- ============================================================================
-- Routes
-- ============================================================================

function Handlers:Start()
	local services = self.services

	-- ---- state ----------------------------------------------------------
	self:BindFunction("GetState", function(player)
		local state = services.profiles:GetState(player)
		if not state then
			return Net.fail("NoProfile", "Your profile is still loading.")
		end
		return Net.ok(services.profiles:Project(state))
	end)

	-- ---- brand ----------------------------------------------------------
	self:BindFunction("CreateBrand", function(player, payload)
		return services.brand:CreateBrand(player, payload)
	end)

	-- ---- products -------------------------------------------------------
	self:BindFunction("CreateProduct", function(player, payload)
		return services.products:CreateProduct(player, payload)
	end)

	self:BindFunction("RenameProduct", function(player, payload)
		return services.products:RenameProduct(player, payload)
	end)

	self:BindFunction("UpdateProductSpec", function(player, payload)
		return services.products:UpdateProductSpec(player, payload)
	end)

	self:BindFunction("ArchiveProduct", function(player, payload)
		return services.products:ArchiveProduct(player, payload)
	end)

	-- ---- suppliers ------------------------------------------------------
	self:BindFunction("GetQuote", function(player, payload)
		return services.manufacturers:GetQuote(player, payload)
	end)

	self:BindFunction("ContactSupplier", function(player, payload)
		return services.manufacturers:ContactSupplier(player, payload)
	end)

	self:BindFunction("OrderSample", function(player, payload)
		return services.sampleOrders:OrderSample(player, payload)
	end)

	-- ---- samples --------------------------------------------------------
	self:BindFunction("OpenParcel", function(player, payload)
		return services.sampleOrders:OpenParcel(player, payload)
	end)

	self:BindFunction("GetSampleReport", function(player, payload)
		return services.sampleOrders:GetSampleReport(player, payload)
	end)

	self:BindFunction("ResolveSample", function(player, payload)
		return services.sampleOrders:ResolveSample(player, payload)
	end)

	-- ---- interaction ----------------------------------------------------
	self:BindFunction("Interact", function(player, payload)
		return services.interactions:HandleInteract(player, payload)
	end)

	-- ---- dev ------------------------------------------------------------
	self:BindFunction("DevCommand", function(player, payload)
		return services.dev:HandleCommand(player, payload)
	end)

	-- ---- push -----------------------------------------------------------
	--[[
		The ONLY subscriber to stateChanged. Services fire that signal without
		knowing replication exists; this turns it into a projection on the wire.
	]]
	services.profiles.stateChanged:connect(function(player: Player, state: any)
		local ok, err = pcall(function()
			Net.fireClient("StateChanged", player, services.profiles:Project(state))
		end)
		if not ok then
			log:error("failed to push state to %s: %s", player.Name, tostring(err))
		end
	end)

	-- Free rate-limit buckets when a player leaves.
	Players.PlayerRemoving:Connect(function(player)
		self.buckets[player.UserId] = nil
	end)

	log:info("bound %d client routes", #Protocol.clientCallable())
end

return Handlers
