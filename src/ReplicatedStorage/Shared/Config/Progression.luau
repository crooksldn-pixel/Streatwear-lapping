--!strict
--[[
	Config.Progression

	Progression flags, counters and app availability.

	== Flags vs counters ==

	Flags are one-way booleans recording that something happened for the first
	time (`brandCreated`, `firstSampleApproved`). They gate content and are never
	unset. Counters are cumulative tallies used for later milestones.

	Both live in the save as open string-keyed tables, so a new system can record
	a new flag without a schema migration. The cost is that a typo'd flag name
	fails silently, so every flag the game actually reads is declared here as a
	constant and referenced through `Progression.Flags.x` rather than as a
	string literal at the call site.

	== App availability ==

	The laptop decides which apps exist from state, not from hardcoded client
	logic. `appRequirements` is the single declaration of that, read by both the
	server (when projecting state) and the client OS shell (when building the
	dock), so the two can never disagree about whether an app should be there.
]]

local Enums = require(script.Parent.Parent.Enums)

local Progression = {}

-- ============================================================================
-- Flag and counter names
-- ============================================================================

Progression.Flags = table.freeze({
	brandCreated = "brandCreated",
	firstProductCreated = "firstProductCreated",
	firstProductDesigned = "firstProductDesigned",
	firstSupplierViewed = "firstSupplierViewed",
	firstSampleOrdered = "firstSampleOrdered",
	firstParcelReceived = "firstParcelReceived",
	firstParcelOpened = "firstParcelOpened",
	firstSampleInspected = "firstSampleInspected",
	firstSampleApproved = "firstSampleApproved",
	firstRevisionRequested = "firstRevisionRequested",
})

Progression.Counters = table.freeze({
	productsCreated = "productsCreated",
	samplesOrdered = "samplesOrdered",
	samplesApproved = "samplesApproved",
	samplesRejected = "samplesRejected",
	parcelsOpened = "parcelsOpened",
	penceSpentOnSamples = "penceSpentOnSamples",
})

-- ============================================================================
-- Brand stage advancement
-- ============================================================================

--[[
	Stage is derived from flags rather than stored independently, so it can never
	drift out of sync with what the player has actually done. Evaluated
	highest-first; the first satisfied entry wins.
]]
Progression.stageRules = {
	{
		stage = Enums.BrandStage.PreLaunch,
		requiresFlags = { Progression.Flags.firstSampleApproved },
	},
	{
		stage = Enums.BrandStage.FirstSample,
		requiresFlags = { Progression.Flags.firstSampleOrdered },
	},
	{
		stage = Enums.BrandStage.Bedroom,
		requiresFlags = { Progression.Flags.brandCreated },
	},
	{
		stage = Enums.BrandStage.Unbranded,
		requiresFlags = {},
	},
}

function Progression.deriveStage(flags: { [string]: boolean }): string
	for _, rule in ipairs(Progression.stageRules) do
		local satisfied = true
		for _, flag in ipairs(rule.requiresFlags) do
			if not flags[flag] then
				satisfied = false
				break
			end
		end
		if satisfied then
			return rule.stage
		end
	end
	return Enums.BrandStage.Unbranded
end

-- ============================================================================
-- App availability
-- ============================================================================

export type AppRequirement = {
	appId: string,
	name: string,
	-- Flags that must all be set for the app to appear.
	requiresFlags: { string },
	-- Shown in the dock as a locked entry with this hint, rather than hidden,
	-- when `showLocked` is true. Seeing what is coming is better than a dock
	-- that silently grows.
	showLocked: boolean,
	lockedHint: string?,
}

Progression.appRequirements = {
	{
		appId = "brand",
		name = "Brand",
		requiresFlags = {},
		showLocked = false,
	},
	{
		appId = "design",
		name = "Design",
		requiresFlags = { Progression.Flags.brandCreated },
		showLocked = true,
		lockedHint = "Set up your brand first",
	},
	{
		appId = "suppliers",
		name = "Suppliers",
		requiresFlags = { Progression.Flags.brandCreated },
		showLocked = true,
		lockedHint = "Design something to get quoted on",
	},
} :: { AppRequirement }

function Progression.isAppAvailable(appId: string, flags: { [string]: boolean }): boolean
	for _, requirement in ipairs(Progression.appRequirements) do
		if requirement.appId == appId then
			for _, flag in ipairs(requirement.requiresFlags) do
				if not flags[flag] then
					return false
				end
			end
			return true
		end
	end
	-- An app with no declared requirement is unavailable by default: a new app
	-- must be declared here deliberately rather than appearing because someone
	-- registered it on the client.
	return false
end

function Progression.getAppRequirement(appId: string): AppRequirement?
	for _, requirement in ipairs(Progression.appRequirements) do
		if requirement.appId == appId then
			return requirement
		end
	end
	return nil
end

return Progression
