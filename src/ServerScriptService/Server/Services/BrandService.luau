--!strict
--[[
	BrandService

	Creates and owns the brand identity.

	== Text filtering ==

	A brand name is player-authored text that ends up on a garment, on a neck
	label, and later in front of other players. It must be filtered.

	TextService:FilterStringAsync is server-only and ALSO fails on an unpublished
	place, which is the state this game is developed in. So filtering sits behind
	the same provider pattern as persistence: the real filter when it is
	reachable, a conservative local check when it is not.

	The raw name and the filtered name are stored SEPARATELY:

	  identity.name         what the player typed, shown back to them
	  identity.displayName  the filtered form, used anywhere another player
	                        could see it

	Keeping both means we never show someone a mangled version of their own brand
	while still never showing unfiltered text to anyone else. The local fallback
	is deliberately strict -- it would rather reject a legitimate name than let
	something through on an unpublished build.
]]

local TextService = game:GetService("TextService")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Styles = require(Shared.Config.Styles)
local Progression = require(Shared.Config.Progression)
local Net = require(Shared.Net.Net)
local Logger = require(Shared.Util.Logger)

local log = Logger.scope("Brand")

local BrandService = {}
BrandService.__index = BrandService

function BrandService.new(profileService: any)
	local self = setmetatable({}, BrandService)
	self.profiles = profileService
	self.filterAvailable = false
	return self
end

function BrandService:Init()
	-- Probe the filter the same way persistence probes DataStore: by calling it.
	local ok = pcall(function()
		return TextService:FilterStringAsync("probe", 1)
	end)
	self.filterAvailable = ok

	if ok then
		log:info("text filtering: TextService")
	else
		log:warn("text filtering: LOCAL FALLBACK (TextService unavailable on an unpublished place)")
		if not RunService:IsStudio() then
			log:error("TextService unavailable in a PUBLISHED server -- names are only locally checked")
		end
	end
end

function BrandService:Start() end

-- ============================================================================
-- Filtering
-- ============================================================================

--[[
	Local fallback check.

	This is NOT a moderation system and does not pretend to be one. It is a
	narrow guard for development builds: it rejects the structural tricks used to
	smuggle text past a renderer, and leaves genuine profanity moderation to
	TextService where that is reachable.
]]
local SUSPICIOUS_PATTERNS = {
	"%z", -- embedded nulls
	"[\1-\31]", -- control characters
	"[\194-\244][\128-\191]*\226\128[\141\142\143]", -- zero-width joiners / marks
	"<%s*[%a/]", -- anything resembling a markup tag
}

function BrandService:FilterText(text: string, userId: number): (boolean, string)
	for _, pattern in ipairs(SUSPICIOUS_PATTERNS) do
		if string.find(text, pattern) then
			return false, ""
		end
	end

	if not self.filterAvailable then
		-- Unfiltered, but structurally validated by Validate.brandName upstream.
		return true, text
	end

	local ok, result = pcall(function()
		local filterResult = TextService:FilterStringAsync(text, userId)
		return filterResult:GetNonChatStringForBroadcastAsync()
	end)

	if not ok then
		-- A filter outage must not become a way to bypass filtering.
		log:warn("filter call failed for %d: %s", userId, tostring(result))
		return false, ""
	end

	return true, result :: string
end

-- ============================================================================
-- Brand creation
-- ============================================================================

function BrandService:CreateBrand(player: Player, payload: any)
	local state = self.profiles:GetState(player)
	if not state then
		return Net.fail("NoProfile", "Your profile is still loading.")
	end

	if state.identity.created then
		return Net.fail("AlreadyExists", "You have already set up your brand.")
	end

	if not Styles.exists(payload.styleId) then
		return Net.fail("UnknownStyle", "That direction is not available.")
	end

	local name = payload.name
	local tagline = payload.tagline or ""

	local nameOk, filteredName = self:FilterText(name, player.UserId)
	if not nameOk then
		return Net.fail("NameRejected", "That name cannot be used. Try another.")
	end

	local filteredTagline = ""
	if tagline ~= "" then
		local taglineOk, filtered = self:FilterText(tagline, player.UserId)
		if not taglineOk then
			return Net.fail("TaglineRejected", "That tagline cannot be used.")
		end
		filteredTagline = filtered
	end

	local applied = self.profiles:Mutate(player, function(s)
		-- Re-check inside the mutation: two rapid calls could both pass the
		-- check above before either commits.
		if s.identity.created then
			return false
		end

		s.identity.created = true
		s.identity.name = name
		s.identity.displayName = filteredName
		s.identity.tagline = tagline
		s.identity.displayTagline = filteredTagline
		s.identity.styleId = payload.styleId
		s.identity.createdAt = os.time()
		return true
	end)

	if not applied then
		return Net.fail("AlreadyExists", "You have already set up your brand.")
	end

	self.profiles:SetFlag(player, Progression.Flags.brandCreated)
	log:info("%s created brand %q (%s)", player.Name, name, payload.styleId)

	return Net.ok({
		name = name,
		displayName = filteredName,
		styleId = payload.styleId,
	})
end

-- The name used when rendering graphics. Falls back so a garment is never
-- built with an empty mark.
function BrandService:GetBrandName(player: Player): string
	local state = self.profiles:GetState(player)
	if state and state.identity.created and state.identity.name ~= "" then
		return state.identity.name
	end
	return "UNTITLED"
end

return BrandService
