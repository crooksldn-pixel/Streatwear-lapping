--!strict
--[[
	DataService

	Versioned, provider-backed persistence.

	== Why a provider abstraction ==

	This place is currently unpublished (PlaceId 0), so DataStoreService throws
	"You must publish this place to the web to access DataStore" on every call.
	That is not an edge case to handle later -- it is the state the game is
	developed in, every session.

	So storage sits behind a tiny interface with two implementations:

	  DataStoreProvider  real persistence
	  MemoryProvider     in-process table, survives only the current session

	Selection happens ONCE at startup via an actual probe call, never from a
	hardcoded flag. Publish the place and tick "Studio Access to API Services"
	and real saving begins with no code change. The provider in use is logged
	loudly at startup so nobody mistakes a Studio session for durable storage.

	== Guarantees ==

	* A load NEVER returns nil. Failure yields a fresh default state flagged
	  `loadFailed`, and a flagged profile is never saved over the real one --
	  silently overwriting a player's brand because one GetAsync timed out is
	  the worst outcome this system can produce.
	* Saves retry on a backoff schedule with jitter.
	* Every payload is checked for DataStore-serialisability BEFORE the call, so
	  a bad write surfaces as our own clear error rather than an opaque refusal.
	* Migrations run oldest-to-newest and are each individually reversible in
	  review; the schema version is stamped on write.
]]

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Types = require(Shared.Types)
local Enums = require(Shared.Enums)
local Economy = require(Shared.Config.Economy)
local Timings = require(Shared.Config.Timings)
local TableKit = require(Shared.Util.TableKit)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("Data")

local DataService = {}
DataService.__index = DataService

DataService.SCHEMA_VERSION = 1
DataService.STORE_NAME = "BrandState"
DataService.KEY_PREFIX = "player_"

type BrandState = Types.BrandState

-- ============================================================================
-- Default state
-- ============================================================================

--[[
	The canonical shape of a save.

	Future sections are present and empty from v1 on purpose: adding a key to an
	existing table is a free migration via TableKit.reconcile, whereas
	introducing a brand new top-level section to live saves is not.
]]
function DataService.defaultState(): BrandState
	local now = os.time()
	return {
		schemaVersion = DataService.SCHEMA_VERSION,
		createdAt = now,
		lastSavedAt = 0,
		playTimeSeconds = 0,

		identity = {
			created = false,
			name = "",
			displayName = "",
			tagline = "",
			displayTagline = "",
			styleId = "",
			createdAt = nil,
		},

		finances = {
			cashPence = Economy.startingCashPence,
			lifetimeSpendPence = 0,
			lifetimeRevenuePence = 0,
			ledger = {},
		},

		products = {},
		productOrder = {},

		orders = {},
		orderIndex = {},

		manufacturers = {},

		progression = {
			stage = Enums.BrandStage.Unbranded,
			flags = {},
			counters = {},
		},

		inventory = {},
		audience = {},
		social = {},
		customers = {},
		reputation = {},
		properties = {},
		employees = {},

		counters = {},
	}
end

-- ============================================================================
-- Storage providers
-- ============================================================================

export type Provider = {
	name: string,
	durable: boolean,
	get: (key: string) -> (boolean, any),
	set: (key: string, value: any) -> (boolean, string?),
}

local function makeDataStoreProvider(store: DataStore): Provider
	return {
		name = "DataStore",
		durable = true,
		get = function(key: string): (boolean, any)
			local ok, result = pcall(function()
				return store:GetAsync(key)
			end)
			return ok, result
		end,
		set = function(key: string, value: any): (boolean, string?)
			local ok, err = pcall(function()
				store:SetAsync(key, value)
			end)
			return ok, if ok then nil else tostring(err)
		end,
	}
end

local function makeMemoryProvider(): Provider
	local store: { [string]: any } = {}
	return {
		name = "Memory",
		durable = false,
		get = function(key: string): (boolean, any)
			return true, store[key]
		end,
		set = function(key: string, value: any): (boolean, string?)
			-- Deep-copied on the way in so a later mutation of the caller's table
			-- does not retroactively alter what was "saved", matching how a real
			-- DataStore behaves.
			store[key] = TableKit.deepCopy(value)
			return true
		end,
	}
end

-- ============================================================================
-- Construction
-- ============================================================================

export type Profile = {
	userId: number,
	key: string,
	state: BrandState,
	loadFailed: boolean,
	dirty: boolean,
	lastSaveAt: number,
	saving: boolean,
	sessionStartClock: number,
}

function DataService.new()
	local self = setmetatable({}, DataService)
	self.provider = nil :: Provider?
	self.profiles = {} :: { [number]: Profile }
	self.started = false
	return self
end

--[[
	Probes DataStore availability once and selects a provider.

	The probe is a real GetAsync against a throwaway key -- the only reliable
	test. Checking RunService:IsStudio() or game.PlaceId would guess, and guesses
	here mean either silently losing saves or refusing to save when we could.
]]
function DataService:Init()
	local store: DataStore? = nil
	local probeOk = false
	local probeError: string? = nil

	local gotStore, storeOrErr = pcall(function()
		return DataStoreService:GetDataStore(DataService.STORE_NAME)
	end)

	if gotStore then
		store = storeOrErr
		local ok, err = pcall(function()
			return (storeOrErr :: DataStore):GetAsync("__availability_probe")
		end)
		probeOk = ok
		if not ok then
			probeError = tostring(err)
		end
	else
		probeError = tostring(storeOrErr)
	end

	if probeOk and store then
		self.provider = makeDataStoreProvider(store)
		log:info("persistence: DataStore (durable)")
	else
		self.provider = makeMemoryProvider()
		log:warn("persistence: IN-MEMORY ONLY -- progress will NOT survive this session")
		log:warn("  reason: %s", probeError or "unknown")
		if not RunService:IsStudio() then
			-- In a live server this is a genuine incident, not a dev convenience.
			log:error("DataStore unavailable in a PUBLISHED server -- player progress is being lost")
		else
			log:warn("  publish the place and enable Studio Access to API Services for real saving")
		end
	end
end

function DataService:Start()
	self.started = true

	-- Autosave loop.
	task.spawn(function()
		while self.started do
			task.wait(Timings.autosaveIntervalSeconds)
			for userId in pairs(self.profiles) do
				local profile = self.profiles[userId]
				if profile and profile.dirty then
					self:Save(userId, "autosave")
				end
			end
		end
	end)

	--[[
		BindToClose gets a limited window (~30s live, less in Studio) to flush.
		Saves run in parallel and the handler waits for all of them, because
		saving twenty profiles sequentially would exceed the window.
	]]
	game:BindToClose(function()
		self.started = false
		log:info("BindToClose: flushing %d profiles", TableKit.count(self.profiles))

		local pending = 0
		local done = Instance.new("BindableEvent")

		for userId, profile in pairs(self.profiles) do
			if profile.dirty then
				pending += 1
				task.spawn(function()
					self:Save(userId, "shutdown")
					pending -= 1
					if pending == 0 then
						done:Fire()
					end
				end)
			end
		end

		if pending > 0 then
			done.Event:Wait()
		end
		done:Destroy()
		log:info("BindToClose: flush complete")
	end)
end

-- ============================================================================
-- Migration
-- ============================================================================

--[[
	Migrations keyed by the version they upgrade FROM. Each returns the state at
	version+1. They run in sequence, so a v1 save reaching a v4 build applies
	1->2, 2->3, 3->4 in order.

	Empty at v1. Entries get added here, never edited in place once shipped.
]]
local migrations: { [number]: (BrandState) -> BrandState } = {}

local function migrate(state: BrandState): (BrandState, boolean)
	local version = tonumber(state.schemaVersion) or 0
	local migrated = false

	while version < DataService.SCHEMA_VERSION do
		local step = migrations[version]
		if not step then
			-- No path from this version. Reconcile against the default instead of
			-- discarding: the player keeps everything structurally valid.
			log:warn("no migration from schema v%d; reconciling against defaults", version)
			break
		end
		local ok, result = pcall(step, state)
		if not ok then
			log:error("migration v%d failed: %s", version, tostring(result))
			break
		end
		state = result
		version += 1
		migrated = true
	end

	state.schemaVersion = DataService.SCHEMA_VERSION
	return state, migrated
end

-- ============================================================================
-- Load
-- ============================================================================

local function keyFor(userId: number): string
	return DataService.KEY_PREFIX .. tostring(userId)
end

--[[
	Validates that a loaded value is plausibly one of our saves.

	A stored value can be corrupt, truncated, or from an unrelated build. Anything
	that is not a table with a numeric schemaVersion is rejected outright rather
	than reconciled, because reconciling arbitrary data produces a state that
	looks valid while containing nonsense.
]]
local function looksLikeSave(value: any): boolean
	return type(value) == "table" and type(value.schemaVersion) == "number"
end

function DataService:Load(userId: number): Profile
	local existing = self.profiles[userId]
	if existing then
		return existing
	end

	local provider = self.provider
	assert(provider, "DataService:Init has not run")

	local key = keyFor(userId)
	local ok, raw = provider.get(key)

	local state: BrandState
	local loadFailed = false

	if not ok then
		--[[
			The read itself failed. This is the dangerous case: the player may
			have a real save we simply could not reach. The profile is marked
			`loadFailed` and Save() refuses to write it, so a transient outage
			cannot destroy a brand.
		]]
		loadFailed = true
		state = DataService.defaultState()
		log:error("load failed for %d: %s -- profile is READ-ONLY this session", userId, tostring(raw))
	elseif raw == nil then
		state = DataService.defaultState()
		log:info("new player %d", userId)
	elseif not looksLikeSave(raw) then
		loadFailed = true
		state = DataService.defaultState()
		log:error("malformed save for %d (%s) -- profile is READ-ONLY this session", userId, typeof(raw))
	else
		local migratedState, didMigrate = migrate(raw :: BrandState)
		-- Reconcile fills any field added to the schema since this save was
		-- written, which is what makes additive changes migration-free.
		state = TableKit.reconcile(migratedState, DataService.defaultState()) :: BrandState
		if didMigrate then
			log:info("migrated %d to schema v%d", userId, DataService.SCHEMA_VERSION)
		end
	end

	local profile: Profile = {
		userId = userId,
		key = key,
		state = state,
		loadFailed = loadFailed,
		dirty = false,
		lastSaveAt = 0,
		saving = false,
		sessionStartClock = os.clock(),
	}

	self.profiles[userId] = profile
	return profile
end

function DataService:Get(userId: number): Profile?
	return self.profiles[userId]
end

function DataService:GetState(userId: number): BrandState?
	local profile = self.profiles[userId]
	return profile and profile.state or nil
end

-- Marks a profile as needing a save. Called by every service that mutates state.
function DataService:MarkDirty(userId: number)
	local profile = self.profiles[userId]
	if profile then
		profile.dirty = true
	end
end

-- ============================================================================
-- Save
-- ============================================================================

function DataService:Save(userId: number, reason: string?): boolean
	local profile = self.profiles[userId]
	if not profile then
		return false
	end

	if profile.loadFailed then
		-- Refusing to write is the entire point of the flag.
		log:warn("skipping save for %d: profile failed to load", userId)
		return false
	end

	if profile.saving then
		return false
	end

	local provider = self.provider
	if not provider then
		return false
	end

	profile.saving = true

	local state = profile.state
	state.schemaVersion = DataService.SCHEMA_VERSION
	state.lastSavedAt = os.time()
	state.playTimeSeconds = math.floor(state.playTimeSeconds + (os.clock() - profile.sessionStartClock))
	profile.sessionStartClock = os.clock()

	-- Catch unserialisable values before spending a DataStore call on them.
	local serialisable, offendingPath = TableKit.isPlainData(state)
	if not serialisable then
		log:error("refusing to save %d: unserialisable value at %s", userId, tostring(offendingPath))
		profile.saving = false
		return false
	end

	local payload = TableKit.deepCopy(state)

	local saved = false
	local attempts = #Timings.saveRetryDelaysSeconds + 1

	for attempt = 1, attempts do
		local ok, err = provider.set(profile.key, payload)
		if ok then
			saved = true
			break
		end

		log:warn("save attempt %d/%d failed for %d: %s", attempt, attempts, userId, tostring(err))

		local delay = Timings.saveRetryDelaysSeconds[attempt]
		if delay then
			-- Jitter prevents every server retrying in lockstep after an outage.
			task.wait(delay + math.random() * 0.5)
		end
	end

	profile.saving = false

	if saved then
		profile.dirty = false
		profile.lastSaveAt = os.time()
		log:debug("saved %d (%s)", userId, reason or "manual")
	else
		log:error("ALL save attempts failed for %d (%s)", userId, reason or "manual")
	end

	return saved
end

function DataService:Release(userId: number)
	local profile = self.profiles[userId]
	if not profile then
		return
	end

	if profile.dirty then
		self:Save(userId, "release")
	end

	self.profiles[userId] = nil
end

-- ============================================================================
-- Development
-- ============================================================================

--[[
	Wipes a player's save back to defaults. Reachable only through DevService,
	which performs the authorisation check; DataService does not gate it itself
	because it has no concept of who is asking.
]]
function DataService:ResetProfile(userId: number): boolean
	local profile = self.profiles[userId]
	if not profile then
		return false
	end

	profile.state = DataService.defaultState()
	-- Clearing the flag is safe here: we are deliberately replacing the save.
	profile.loadFailed = false
	profile.dirty = true
	log:warn("profile RESET for %d", userId)
	return true
end

function DataService:ProviderName(): string
	return self.provider and self.provider.name or "none"
end

function DataService:IsDurable(): boolean
	return self.provider ~= nil and self.provider.durable
end

return DataService
