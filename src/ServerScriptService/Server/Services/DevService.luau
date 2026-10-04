--!strict
--[[
	DevService

	Development commands, and the authorisation gate that keeps them away from
	normal players.

	== The gate ==

	The brief requires that cheats can never accidentally reach players. A single
	boolean in a replicated config module is not sufficient on its own, because
	that module is readable (and, to an exploiter, apparently editable) on the
	client. So authorisation requires BOTH:

		1. Config.Dev.enabled -- the build-level switch, and
		2. an environment condition the client cannot influence:
		   RunService:IsStudio(), or an explicit UserId allow-list.

	In a published place with an empty allow-list, IsStudio() is false and nobody
	passes, regardless of what any client sends. The check runs SERVER-SIDE on
	every single command -- never once at startup -- so there is no window where
	a stale decision could be reused.

	Every dev command is also an ordinary validated remote: the payload passes
	the same schema and rate limit as any other route. An authorised user cannot
	send malformed input either.

	Unauthorised attempts are logged with the player's name, because in a live
	server that is an exploit attempt worth seeing.
]]

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Enums = require(Shared.Enums)
local DevConfig = require(Shared.Config.Dev)
local Economy = require(Shared.Config.Economy)
local Net = require(Shared.Net.Net)
local Format = require(Shared.Util.Format)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("Dev")

local DevService = {}
DevService.__index = DevService

function DevService.new(services: any)
	local self = setmetatable({}, DevService)
	self.services = services
	return self
end

function DevService:Init()
	if not DevConfig.enabled then
		log:info("dev commands disabled by config")
		return
	end

	if RunService:IsStudio() then
		log:info("dev commands ENABLED (Studio)")
	elseif next(DevConfig.authorisedUserIds) ~= nil then
		log:warn("dev commands ENABLED in a published place for an explicit allow-list")
	else
		log:info("dev commands unreachable (published place, empty allow-list)")
	end
end

function DevService:Start() end

-- ============================================================================
-- Authorisation
-- ============================================================================

function DevService:IsAuthorised(player: Player): boolean
	if not DevConfig.enabled then
		return false
	end
	-- Studio: only ever true in a local session, never in a live server.
	if RunService:IsStudio() then
		return true
	end
	-- Explicit allow-list for debugging a published build.
	return DevConfig.authorisedUserIds[player.UserId] == true
end

-- ============================================================================
-- Commands
-- ============================================================================

local commands: { [string]: (self: any, player: Player, arg: string?) -> any } = {}

commands.help = function(self, _player)
	local names = {}
	for name in pairs(commands) do
		table.insert(names, name)
	end
	table.sort(names)
	return Net.ok({ message = "Commands: " .. table.concat(names, ", ") })
end

-- Grants cash. Amount comes from config, never from the client.
commands.cash = function(self, player, arg)
	local amount = DevConfig.grantPence
	if arg then
		local parsed = tonumber(arg)
		-- Bounded even for an authorised user: a typo should not create a
		-- balance that breaks the economy's sanity checks.
		if parsed and parsed == parsed and parsed > 0 then
			amount = math.floor(math.min(parsed, Economy.maxTransactionPence))
		end
	end

	local ok = self.services.profiles:AdjustCash(player, amount, Enums.LedgerKind.DevGrant, "Developer grant")
	if not ok then
		return Net.fail("GrantFailed", "Could not grant cash.")
	end
	return Net.ok({ message = "Granted " .. Format.money(amount) })
end

-- Collapses every in-flight sample deadline so parcels arrive immediately.
commands.deliver = function(self, player)
	local moved = self.services.sampleOrders:ForceDeliverAll(player)
	if moved == 0 then
		return Net.ok({ message = "No samples in production." })
	end
	return Net.ok({ message = string.format("Forced %d order(s) to delivery.", moved) })
end

-- Wipes the save back to defaults.
commands.reset = function(self, player)
	local ok = self.services.data:ResetProfile(player.UserId)
	if not ok then
		return Net.fail("ResetFailed", "Could not reset the profile.")
	end
	self.services.profiles:Changed(player)
	return Net.ok({ message = "Profile reset. Rejoin to start clean." })
end

commands.state = function(self, player)
	local state = self.services.profiles:GetState(player)
	if not state then
		return Net.fail("NoProfile", "No profile loaded.")
	end

	local productCount = 0
	for _ in pairs(state.products) do
		productCount += 1
	end
	local orderCount = 0
	for _ in pairs(state.orders) do
		orderCount += 1
	end

	return Net.ok({
		message = string.format(
			"%s | %s | %d products | %d orders | stage %s | storage %s",
			state.identity.created and state.identity.name or "no brand",
			Format.money(state.finances.cashPence),
			productCount,
			orderCount,
			state.progression.stage,
			self.services.data:ProviderName()
		),
	})
end

-- Forces a save now, to verify persistence end to end.
commands.save = function(self, player)
	local ok = self.services.data:Save(player.UserId, "dev")
	return Net.ok({
		message = ok
			and ("Saved via " .. self.services.data:ProviderName())
			or "Save failed -- check the output.",
	})
end

-- Fast-forwards to a designed product so the supplier flow can be tested
-- without walking the whole brand/design path each time.
commands.seed = function(self, player)
	local profiles = self.services.profiles
	local state = profiles:GetState(player)
	if not state then
		return Net.fail("NoProfile", "No profile loaded.")
	end

	if not state.identity.created then
		local created = self.services.brand:CreateBrand(player, {
			name = "Test Brand",
			tagline = "Seeded for testing",
			styleId = "streetwear",
		})
		if not created.ok then
			return created
		end
	end

	local created = self.services.products:CreateProduct(player, { name = "Test Tee" })
	if not created.ok then
		return created
	end

	local productId = created.data.productId
	local updated = self.services.products:UpdateProductSpec(player, {
		productId = productId,
		graphics = { {
			recipeId = "arch_collegiate",
			paletteId = "white",
			placement = Enums.Placement.FrontCentre,
			printMethodId = "screen",
			scale = 0.84,
			rotation = 0,
			offsetX = 0,
			offsetY = 0,
		} },
	})
	if not updated.ok then
		return updated
	end

	return Net.ok({ message = "Seeded brand and designed " .. productId })
end

-- ============================================================================
-- Dispatch
-- ============================================================================

function DevService:HandleCommand(player: Player, payload: any)
	if not self:IsAuthorised(player) then
		-- Worth seeing in a live server: this is an exploit attempt.
		log:warn("UNAUTHORISED dev command %q from %s (%d)",
			tostring(payload.command), player.Name, player.UserId)
		-- Deliberately indistinguishable from a nonexistent route.
		return Net.fail("NotFound", "Unknown command.")
	end

	local command = commands[payload.command]
	if not command then
		return Net.fail("NotFound", "Unknown command. Try 'help'.")
	end

	local ok, result = pcall(command, self, player, payload.arg)
	if not ok then
		log:error("dev command %q failed: %s", payload.command, tostring(result))
		return Net.fail("CommandError", tostring(result))
	end

	log:info("%s ran dev command %q", player.Name, payload.command)
	return result
end

return DevService
