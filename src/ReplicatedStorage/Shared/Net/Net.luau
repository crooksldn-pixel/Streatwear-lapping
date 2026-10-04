--!strict
--[[
	Shared.Net.Net

	Remote instance lifecycle and the client-side call surface.

	The server builds every remote declared in Protocol at startup (`Net.build()`)
	so the set of remotes in the DataModel is exactly the set in Protocol -- no
	stragglers from a previous iteration, no remote created on demand by a
	feature that forgot to declare itself.

	The client resolves them by name and never creates them, so a client cannot
	conjure a remote the server is not listening on.

	Failure handling on the client is uniform: a dropped or erroring call returns
	a well-formed `Response` with ok=false rather than throwing, because every
	call site is UI code where an unhandled error means a frozen interface.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = script.Parent.Parent
local Protocol = require(script.Parent.Protocol)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("Net")

local Net = {}

local folder: Folder? = nil

-- ============================================================================
-- Server: construction
-- ============================================================================

function Net.build(): Folder
	assert(RunService:IsServer(), "Net.build may only be called on the server")

	local existing = ReplicatedStorage:FindFirstChild(Protocol.FOLDER_NAME)
	if existing then
		existing:Destroy()
	end

	local container = Instance.new("Folder")
	container.Name = Protocol.FOLDER_NAME

	local count = 0
	for _, route in pairs(Protocol.routes) do
		local remote = Instance.new(route.kind)
		remote.Name = route.name
		remote.Parent = container
		count += 1
	end

	container.Parent = ReplicatedStorage
	folder = container

	log:info("built %d remotes", count)
	return container
end

-- ============================================================================
-- Resolution
-- ============================================================================

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end

	if RunService:IsServer() then
		local found = ReplicatedStorage:FindFirstChild(Protocol.FOLDER_NAME)
		assert(found, "Net.build() has not run yet")
		folder = found :: Folder
	else
		-- Client may require Net before the server has replicated the folder.
		folder = ReplicatedStorage:WaitForChild(Protocol.FOLDER_NAME, 30) :: Folder
		assert(folder, "Remotes folder never replicated")
	end

	return folder :: Folder
end

local function resolve(routeName: string): Instance
	local route = Protocol.routes[routeName]
	assert(route, string.format("unknown route %q", routeName))

	local container = getFolder()
	local remote = container:FindFirstChild(route.name)
	if not remote then
		-- Only possible on the client, mid-replication.
		remote = container:WaitForChild(route.name, 15)
	end
	assert(remote, string.format("remote %q not found", routeName))
	return remote
end

function Net.getFunction(routeName: string): RemoteFunction
	local remote = resolve(routeName)
	assert(remote:IsA("RemoteFunction"), string.format("%q is not a RemoteFunction", routeName))
	return remote
end

function Net.getEvent(routeName: string): RemoteEvent
	local remote = resolve(routeName)
	assert(remote:IsA("RemoteEvent"), string.format("%q is not a RemoteEvent", routeName))
	return remote
end

-- ============================================================================
-- Client call surface
-- ============================================================================

export type Response = {
	ok: boolean,
	data: any?,
	error: string?,
	message: string?,
}

local FAILED_RESPONSE_MESSAGE = "Could not reach the server. Try again in a moment."

--[[
	Calls a server route and ALWAYS returns a Response table.

	Three failure modes are flattened into one shape so no call site needs a
	pcall or a nil check:

	  * the invocation itself errors (remote destroyed, server shutting down)
	  * the server returns nothing (handler threw before responding)
	  * the server returns a malformed value (should not happen; treated as a
		failure rather than trusted)
]]
function Net.invoke(routeName: string, payload: { [string]: any }?): Response
	assert(RunService:IsClient(), "Net.invoke is client-only")

	local ok, result = pcall(function()
		return Net.getFunction(routeName):InvokeServer(payload or {})
	end)

	if not ok then
		log:warn("invoke %s failed: %s", routeName, tostring(result))
		return { ok = false, error = "NetworkError", message = FAILED_RESPONSE_MESSAGE }
	end

	if type(result) ~= "table" or type((result :: any).ok) ~= "boolean" then
		log:warn("invoke %s returned a malformed response", routeName)
		return { ok = false, error = "MalformedResponse", message = FAILED_RESPONSE_MESSAGE }
	end

	return result :: Response
end

function Net.onClientEvent(routeName: string, handler: (...any) -> ()): RBXScriptConnection
	assert(RunService:IsClient(), "Net.onClientEvent is client-only")
	return Net.getEvent(routeName).OnClientEvent:Connect(handler)
end

-- ============================================================================
-- Server helpers
-- ============================================================================

function Net.fireClient(routeName: string, player: Player, ...: any)
	assert(RunService:IsServer(), "Net.fireClient is server-only")
	Net.getEvent(routeName):FireClient(player, ...)
end

function Net.fireAllClients(routeName: string, ...: any)
	assert(RunService:IsServer(), "Net.fireAllClients is server-only")
	Net.getEvent(routeName):FireAllClients(...)
end

-- ============================================================================
-- Response constructors
-- ============================================================================

function Net.ok(data: any?): Response
	return { ok = true, data = data }
end

--[[
	Failures carry a machine-readable `error` code AND a player-facing `message`.
	The code is for client logic and logs; the message is the only thing shown to
	the player. Keeping them separate means an internal reason is never rendered
	into the UI by accident.
]]
function Net.fail(errorCode: string, message: string?): Response
	return { ok = false, error = errorCode, message = message or "That did not work." }
end

return Net
