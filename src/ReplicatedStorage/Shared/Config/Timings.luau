--!strict
--[[
	Config.Timings

	All durations in REAL seconds, already compressed for gameplay.

	== The time model ==

	Manufacturers declare their lead times in BUSINESS DAYS, because that is how
	a real factory quotes and it keeps the manufacturer data readable and
	balanced in units that mean something. A single global constant converts days
	to seconds, so the entire game's pacing is tunable from one number.

	At 4 seconds per day: a 7-day sample run is 28s of production, and a 10-day
	shipment is 40s. The full order-to-doorstep loop for a mid-tier factory lands
	around a minute -- long enough to feel like waiting on a factory, short
	enough that the player does something else and is interrupted by a delivery
	rather than standing still watching a bar.

	Deadlines are stored as ABSOLUTE os.time() values on the order, so leaving
	and rejoining neither skips nor repeats the wait.
]]

export type TimingsConfig = {
	secondsPerBusinessDay: number,
	autosaveIntervalSeconds: number,
	saveRetryDelaysSeconds: { number },
	orderTickIntervalSeconds: number,
	minimumOrderSeconds: number,
	supplierReplyDelayScale: number,
	parcelDespawnSeconds: number,
	notificationDwellSeconds: number,
	cameraBlendSeconds: number,
	parcelOpenSeconds: number,
}

local Timings: TimingsConfig = {
	--[[
		THE master pacing dial. Raise it to make the whole game slower, lower it
		to speed every lead time up. Nothing else needs touching.
	]]
	secondsPerBusinessDay = 4,

	-- Autosave cadence. 120s bounds worst-case loss to two minutes while
	-- staying far inside the DataStore write budget for a realistic player count.
	autosaveIntervalSeconds = 120,

	-- Backoff schedule for a failed save. Length determines attempt count.
	-- Exponential-ish with jitter applied at the call site.
	saveRetryDelaysSeconds = { 1, 3, 7, 15 },

	--[[
		How often the server re-checks order deadlines. 1s is ample: orders are
		minute-scale, and the tick is a cheap scan over one player's open orders.
		Order progression is driven by comparing os.time() to a stored deadline,
		not by counting ticks, so a slow or missed tick delays a transition
		slightly but never loses it.
	]]
	orderTickIntervalSeconds = 1,

	-- Floor on any order stage, so a dev-skipped or zero-day quote still reads
	-- as a process rather than completing in the same frame it was placed.
	minimumOrderSeconds = 3,

	-- Multiplier applied to a manufacturer's communication trait to derive how
	-- long they take to "reply" in a conversation.
	supplierReplyDelayScale = 1.0,

	-- An unopened parcel persists this long before being tidied away. Generous:
	-- losing a paid-for sample to a timer would be hostile. It is re-spawnable
	-- from the order regardless, since the order is the source of truth.
	parcelDespawnSeconds = 1800,

	notificationDwellSeconds = 6,

	-- Camera move between player view and laptop screen.
	cameraBlendSeconds = 0.55,

	-- Parcel opening presentation.
	parcelOpenSeconds = 1.6,
}

-- Business days -> real seconds, with the minimum stage length enforced.
function Timings.daysToSeconds(days: number): number
	return math.max(Timings.minimumOrderSeconds, days * Timings.secondsPerBusinessDay)
end

return table.freeze(Timings)
