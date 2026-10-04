--!strict
--[[
	Server Bootstrap

	Constructs every service, wires their dependencies, then runs Init on all of
	them followed by Start on all of them.

	== Why two phases ==

	Init may only touch the service's own state. Start may touch other services
	and connect to their signals. Separating them means construction order does
	not have to match dependency order -- by the time any Start runs, every
	service has already been fully initialised, so a listener can never attach to
	a half-built service.

	Dependencies are passed EXPLICITLY through constructors rather than pulled
	from a global service locator. It is slightly more typing and it makes the
	whole dependency graph visible in one screen, which is worth far more.

	Remotes are built before any handler binds, and the world is bound before
	anything registers interactions on it.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net.Net)
local Logger = require(Shared.Util.Logger)

local Server = ServerScriptService:WaitForChild("Server")
local ServicesFolder = Server:WaitForChild("Services")
local ApiFolder = Server:WaitForChild("Api")

local log = Logger.scope("Bootstrap")

local startClock = os.clock()
log:info("starting")

-- ============================================================================
-- Remotes first -- handlers cannot bind to what does not exist.
-- ============================================================================

Net.build()

-- ============================================================================
-- Construction
-- ============================================================================

local DataService = require(ServicesFolder.DataService)
local ProfileService = require(ServicesFolder.ProfileService)
local BrandService = require(ServicesFolder.BrandService)
local ProductService = require(ServicesFolder.ProductService)
local QualityService = require(ServicesFolder.QualityService)
local ManufacturerService = require(ServicesFolder.ManufacturerService)
local SampleOrderService = require(ServicesFolder.SampleOrderService)
local InteractionService = require(ServicesFolder.InteractionService)
local WorldService = require(ServicesFolder.WorldService)
local DeliveryService = require(ServicesFolder.DeliveryService)
local DevService = require(ServicesFolder.DevService)
local Handlers = require(ApiFolder.Handlers)

local services = {}

services.data = DataService.new()
services.profiles = ProfileService.new(services.data)
services.brand = BrandService.new(services.profiles)
services.products = ProductService.new(services.profiles)
services.quality = QualityService.new()
services.manufacturers = ManufacturerService.new(services.profiles, services.products, services.quality)
services.sampleOrders = SampleOrderService.new(
	services.profiles,
	services.products,
	services.manufacturers,
	services.quality
)
services.interactions = InteractionService.new(services.profiles)
services.world = WorldService.new(services.profiles, services.interactions)
services.delivery = DeliveryService.new(
	services.profiles,
	services.sampleOrders,
	services.interactions,
	services.world
)
services.dev = DevService.new(services)
services.api = Handlers.new(services)

--[[
	Lifecycle order.

	data before profiles (profiles load through it); world before delivery
	(delivery needs the drop point); api last so every service it routes to is
	already running.
]]
local LIFECYCLE_ORDER = {
	"data",
	"profiles",
	"brand",
	"products",
	"quality",
	"manufacturers",
	"sampleOrders",
	"interactions",
	"world",
	"delivery",
	"dev",
	"api",
}

-- ============================================================================
-- Init, then Start
-- ============================================================================

local function runPhase(phase: string)
	for _, name in ipairs(LIFECYCLE_ORDER) do
		local service = services[name]
		local method = service and (service :: any)[phase]
		if method then
			local ok, err = pcall(method, service)
			if not ok then
				--[[
					A failure here is logged and the remaining services still run.
					A half-started server where most things work beats a dead one,
					and the error is loud enough to find.
				]]
				log:error("%s:%s() failed: %s", name, phase, tostring(err))
			end
		end
	end
end

runPhase("Init")
runPhase("Start")

log:info("ready in %.0fms (storage: %s)",
	(os.clock() - startClock) * 1000,
	services.data:ProviderName())

if not services.data:IsDurable() then
	log:warn("REMINDER: progress is not being persisted in this session")
end
