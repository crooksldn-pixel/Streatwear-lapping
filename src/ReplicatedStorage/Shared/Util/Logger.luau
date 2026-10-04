--!strict
--[[
	Logger

	Channelled logging. Each system gets `Logger.scope("SampleOrder")` and logs
	through it, so output is greppable by subsystem and whole channels can be
	muted while debugging one area.

	Debug output is gated on Config.Dev.verboseLogging, resolved lazily to avoid
	a require cycle (Config requires nothing, but Logger is required by things
	Config-adjacent and this keeps the dependency one-directional).
]]

local RunService = game:GetService("RunService")

local Logger = {}

local LEVELS = { trace = 10, debug = 20, info = 30, warn = 40, error = 50 }

local mutedChannels: { [string]: boolean } = {}
local minimumLevel = LEVELS.debug
local verboseResolved: boolean? = nil

local function contextTag(): string
	if RunService:IsServer() then
		return "S"
	end
	return "C"
end

local function isVerbose(): boolean
	if verboseResolved == nil then
		verboseResolved = false
		local ok, devConfig = pcall(function()
			local shared = script.Parent.Parent
			return require(shared.Config.Dev) :: any
		end)
		if ok and type(devConfig) == "table" then
			verboseResolved = devConfig.verboseLogging == true
		end
	end
	return verboseResolved :: boolean
end

function Logger.setMinimumLevel(level: string)
	minimumLevel = LEVELS[level] or LEVELS.debug
end

function Logger.mute(channel: string)
	mutedChannels[channel] = true
end

function Logger.unmute(channel: string)
	mutedChannels[channel] = nil
end

local function emit(level: string, channel: string, message: string, ...: any)
	if mutedChannels[channel] then
		return
	end

	local levelValue = LEVELS[level] or LEVELS.info
	if levelValue < minimumLevel then
		return
	end

	-- trace/debug only appear when explicitly enabled, so a shipped build is quiet.
	if levelValue <= LEVELS.debug and not isVerbose() then
		return
	end

	local body = message
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, message, ...)
		body = ok and formatted or (message .. " " .. table.concat({ ... }, " "))
	end

	local line = string.format("[%s][%s] %s", contextTag(), channel, body)

	if levelValue >= LEVELS.error then
		-- Deliberately warn() rather than error(): a logging call must never
		-- unwind the caller's stack.
		warn("\u{26A0} " .. line)
	elseif levelValue >= LEVELS.warn then
		warn(line)
	else
		print(line)
	end
end

export type Scope = {
	trace: (self: Scope, message: string, ...any) -> (),
	debug: (self: Scope, message: string, ...any) -> (),
	info: (self: Scope, message: string, ...any) -> (),
	warn: (self: Scope, message: string, ...any) -> (),
	error: (self: Scope, message: string, ...any) -> (),
	assert: (self: Scope, condition: any, message: string) -> boolean,
}

function Logger.scope(channel: string): Scope
	local scope = {}

	function scope.trace(_self, message: string, ...: any)
		emit("trace", channel, message, ...)
	end
	function scope.debug(_self, message: string, ...: any)
		emit("debug", channel, message, ...)
	end
	function scope.info(_self, message: string, ...: any)
		emit("info", channel, message, ...)
	end
	function scope.warn(_self, message: string, ...: any)
		emit("warn", channel, message, ...)
	end
	function scope.error(_self, message: string, ...: any)
		emit("error", channel, message, ...)
	end

	-- Soft assert: reports and returns false instead of throwing, so a failed
	-- invariant in one request cannot take down a service loop.
	function scope.assert(_self, condition: any, message: string): boolean
		if not condition then
			emit("error", channel, "assertion failed: " .. message)
			return false
		end
		return true
	end

	return scope :: any
end

return Logger
