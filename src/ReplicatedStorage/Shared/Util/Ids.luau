--!strict
--[[
	Ids

	Entity id generation.

	Ids are generated SERVER-SIDE ONLY and are per-save monotonic, drawn from a
	counter stored inside the save itself (`state.counters`). That matters:

	* The id is stable and meaningful ("PRD-7"), which makes saves and logs
	  readable.
	* Because the counter persists with the save, a rejoin cannot reissue an id
	  that already belongs to an entity.
	* No randomness means no collision handling and no chance of two entities
	  racing to the same key.

	The counter is never reset by deleting entities -- ids are not reused, so a
	stale reference always fails to resolve rather than silently resolving to a
	different object.
]]

local Ids = {}

Ids.PRODUCT = "PRD"
Ids.ORDER = "ORD"
Ids.PARCEL = "PCL"
Ids.CUSTOMER = "CUS"
Ids.CAMPAIGN = "CMP"

--[[
	next(counters, prefix) -> "PRD-1"

	`counters` is the mutable table from the player's state; this function
	increments it in place. Callers must be holding the authoritative state.
]]
function Ids.next(counters: { [string]: number }, prefix: string): string
	local key = prefix .. "_seq"
	local current = counters[key]
	if type(current) ~= "number" or current < 0 or current % 1 ~= 0 then
		current = 0
	end
	current += 1
	counters[key] = current
	return string.format("%s-%d", prefix, current)
end

function Ids.peek(counters: { [string]: number }, prefix: string): number
	local current = counters[prefix .. "_seq"]
	return type(current) == "number" and current or 0
end

-- Shape check for ids arriving from the client. Cheap pre-filter before a
-- lookup -- rejects obvious junk without touching state.
function Ids.looksValid(value: unknown, prefix: string?): boolean
	if typeof(value) ~= "string" then
		return false
	end
	local text = value :: string
	if #text == 0 or #text > 24 then
		return false
	end
	if prefix then
		return string.match(text, "^" .. prefix .. "%-%d+$") ~= nil
	end
	return string.match(text, "^%u+%-%d+$") ~= nil
end

--[[
	Deterministic 32-bit hash of a string.

	Used to seed quality rolls from an order id: the same order always produces
	the same outcome, so a player cannot rejoin or re-open a parcel to re-roll a
	bad sample, and a reported result is reproducible for debugging.

	FNV-1a, with the multiply kept inside 32 bits via bit32 so it does not drift
	into float territory.
]]
function Ids.hash(text: string): number
	local hash = 2166136261
	for index = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, index))
		-- FNV prime 16777619, decomposed so each shift stays within 32 bits.
		hash = bit32.band(
			hash
				+ bit32.lshift(hash, 1)
				+ bit32.lshift(hash, 4)
				+ bit32.lshift(hash, 7)
				+ bit32.lshift(hash, 8)
				+ bit32.lshift(hash, 24),
			0xFFFFFFFF
		)
	end
	return hash
end

-- Combines a base string with a named sub-stream so one order can seed several
-- independent rolls (print quality, stitching, ...) that do not correlate.
function Ids.subSeed(base: string, stream: string): number
	return Ids.hash(base .. "|" .. stream)
end

return Ids
