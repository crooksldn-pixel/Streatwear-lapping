--!strict
--[[
	Config.Dev

	Development tooling switches.

	== How dev access is gated ==

	The brief requires that development cheats can never leak to normal players.
	A single boolean in a replicated module is not sufficient, because this
	module is in ReplicatedStorage and an exploiter can read it -- reading it is
	harmless, but the server must not trust it as the sole gate.

	The real gate is `DevService:isAuthorised(player)` on the SERVER, which
	requires BOTH:

	  1. an environment condition the client cannot fake --
	     RunService:IsStudio(), or the player's UserId appearing in
	     `authorisedUserIds` below, and
	  2. `enabled` being true here.

	In a published production place, IsStudio() is false and an empty
	`authorisedUserIds` means no one passes, regardless of what the client sends.
	The dev remote still validates its payload like any other, so a dev command
	is not an unvalidated back door even for an authorised user.

	Before publishing: leave `authorisedUserIds` empty, or list only your own
	UserId. Never add a group check here -- group membership is cacheable and
	lags behind role changes.
]]

export type DevConfig = {
	enabled: boolean,
	verboseLogging: boolean,
	authorisedUserIds: { [number]: boolean },
	skipIntro: boolean,
	logStateChanges: boolean,
	logRemoteTraffic: boolean,
	grantPence: number,
	showInteractionBounds: boolean,
}

local Dev: DevConfig = {
	-- Master switch for the whole dev surface. Set false to ship.
	enabled = true,

	-- Emits trace/debug channels. Noisy by design; off in a shipped build.
	verboseLogging = true,

	--[[
		UserIds allowed to run dev commands in a PUBLISHED place.
		Empty means "Studio only", which is the correct shipping value.
		e.g. { [1234567] = true }
	]]
	authorisedUserIds = {},

	-- Skips any first-run presentation while iterating.
	skipIntro = false,

	-- Verbose state/remote tracing, separated so each can be enabled alone.
	logStateChanges = false,
	logRemoteTraffic = false,

	-- Amount granted by the `cash` dev command, in pence.
	grantPence = 50000,

	-- Draws interaction radii in the world for tuning prompt distances.
	showInteractionBounds = false,
}

return table.freeze(Dev)
