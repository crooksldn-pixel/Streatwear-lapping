--!strict
--[[
	Client Bootstrap

	Constructs the controllers, registers the apps, then runs Init on all of them
	followed by Start on all of them -- the same two-phase lifecycle the server
	uses, for the same reason: by the time any Start runs, every controller is
	fully initialised, so nothing can subscribe to a half-built object.

	Controllers receive the shared `controllers` table so they can reach each
	other by name. That is a deliberate compromise: a strict constructor-injection
	graph would be circular here (OS needs Interaction, Interaction needs OS), and
	a single shared table is clearer than breaking the cycle with proxies.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Logger = require(Shared.Util.Logger)

local Client = script.Parent
local ControllersFolder = Client:WaitForChild("Controllers")
local UIFolder = Client:WaitForChild("UI")
local AppsFolder = UIFolder:WaitForChild("Apps")

local log = Logger.scope("Client")

local startClock = os.clock()

-- Wait for the server to publish remotes before anything tries to call one.
ReplicatedStorage:WaitForChild("Remotes", 30)

-- ============================================================================
-- Construction
-- ============================================================================

local StateController = require(ControllersFolder.StateController)
local NotificationController = require(ControllersFolder.NotificationController)
local CameraController = require(ControllersFolder.CameraController)
local InteractionController = require(ControllersFolder.InteractionController)
local OSController = require(ControllersFolder.OSController)
local ParcelController = require(ControllersFolder.ParcelController)
local InspectionController = require(ControllersFolder.InspectionController)

local controllers = {}

controllers.state = StateController.new()
controllers.notifications = NotificationController.new()
controllers.camera = CameraController.new()
controllers.interactions = InteractionController.new(controllers)
controllers.os = OSController.new(controllers)
controllers.parcel = ParcelController.new(controllers)
controllers.inspection = InspectionController.new(controllers)

--[[
	Lifecycle order.

	state first so everything else can read it; notifications early so any
	controller can report during startup; os before interactions so the shell
	exists when prompts begin firing directives at it.
]]
local LIFECYCLE_ORDER = {
	"state",
	"notifications",
	"camera",
	"os",
	"interactions",
	"parcel",
	"inspection",
}

-- ============================================================================
-- Apps
-- ============================================================================

controllers.os:RegisterApp("brand", require(AppsFolder.BrandApp))
controllers.os:RegisterApp("design", require(AppsFolder.DesignApp))
controllers.os:RegisterApp("suppliers", require(AppsFolder.SupplierApp))

-- ============================================================================
-- Init, then Start
-- ============================================================================

local function runPhase(phase: string)
	for _, name in ipairs(LIFECYCLE_ORDER) do
		local controller = controllers[name]
		local method = controller and (controller :: any)[phase]
		if method then
			local ok, err = pcall(method, controller)
			if not ok then
				-- One broken controller must not take the whole client down.
				log:error("%s:%s() failed: %s", name, phase, tostring(err))
			end
		end
	end
end

runPhase("Init")
runPhase("Start")

log:info("ready in %.0fms", (os.clock() - startClock) * 1000)

-- ============================================================================
-- First-run welcome
-- ============================================================================

--[[
	A single nudge toward the laptop for a player with no brand yet. One card,
	once -- not a tutorial sequence.
]]
controllers.state.ready:connect(function(state)
	task.wait(1.5)
	if not state.identity.created then
		controllers.notifications:Push({
			title = "Start here",
			body = "Use the laptop on your desk to set up your brand.",
			kind = "info",
			duration = 12,
		})
	end
end)
