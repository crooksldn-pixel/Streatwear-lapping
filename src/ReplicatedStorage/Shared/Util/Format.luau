--!strict
--[[
	Format

	Display-edge formatting. This is the ONLY place pence become "£" -- systems
	and remotes deal exclusively in integer pence.
]]

local Format = {}

Format.CURRENCY_SYMBOL = "\u{00A3}"

local function groupThousands(digits: string): string
	local out = digits
	while true do
		local replaced, count = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
		out = replaced
		if count == 0 then
			break
		end
	end
	return out
end

--[[
	money(4999)        -> "£49.99"
	money(40000)       -> "£400.00"
	money(40000, true) -> "£400"       (whole amounts drop the decimals)
]]
function Format.money(pence: number, compactWhole: boolean?): string
	local rounded = math.floor(pence + 0.5)
	local negative = rounded < 0
	local absolute = math.abs(rounded)

	local whole = math.floor(absolute / 100)
	local fraction = absolute % 100

	local body
	if compactWhole and fraction == 0 then
		body = groupThousands(tostring(whole))
	else
		body = string.format("%s.%02d", groupThousands(tostring(whole)), fraction)
	end

	return (negative and "-" or "") .. Format.CURRENCY_SYMBOL .. body
end

-- Signed form for ledger rows: "+£12.00" / "-£49.99".
function Format.moneySigned(pence: number): string
	if pence >= 0 then
		return "+" .. Format.money(pence)
	end
	return Format.money(pence)
end

-- Large balances for headline figures: "£1.2k", "£3.4m".
function Format.moneyAbbreviated(pence: number): string
	local pounds = pence / 100
	local absolute = math.abs(pounds)
	local sign = pounds < 0 and "-" or ""

	if absolute >= 1e9 then
		return string.format("%s%s%.1fb", sign, Format.CURRENCY_SYMBOL, absolute / 1e9)
	elseif absolute >= 1e6 then
		return string.format("%s%s%.1fm", sign, Format.CURRENCY_SYMBOL, absolute / 1e6)
	elseif absolute >= 10000 then
		return string.format("%s%s%.1fk", sign, Format.CURRENCY_SYMBOL, absolute / 1000)
	end
	return Format.money(pence, true)
end

--[[
	Durations are shown to the player as elapsed/remaining wall-clock. Game time
	is accelerated, so these are the ALREADY-COMPRESSED values -- Format does no
	scaling of its own.
]]
function Format.duration(seconds: number): string
	local remaining = math.max(0, math.floor(seconds + 0.5))

	if remaining < 60 then
		return string.format("%ds", remaining)
	end

	local minutes = math.floor(remaining / 60)
	local secs = remaining % 60

	if minutes < 60 then
		if secs == 0 then
			return string.format("%dm", minutes)
		end
		return string.format("%dm %ds", minutes, secs)
	end

	local hours = math.floor(minutes / 60)
	local mins = minutes % 60
	if mins == 0 then
		return string.format("%dh", hours)
	end
	return string.format("%dh %dm", hours, mins)
end

-- Compact countdown for timers: "04:31".
function Format.clock(seconds: number): string
	local remaining = math.max(0, math.floor(seconds + 0.5))
	local minutes = math.floor(remaining / 60)
	local secs = remaining % 60
	if minutes >= 60 then
		return string.format("%d:%02d:%02d", math.floor(minutes / 60), minutes % 60, secs)
	end
	return string.format("%02d:%02d", minutes, secs)
end

-- 0..1 -> "82%"
function Format.percent(value: number, decimals: number?): string
	local places = decimals or 0
	return string.format("%." .. places .. "f%%", value * 100)
end

--[[
	Quality scores are shown as a grade rather than a bare number: a player
	inspecting a garment should read "Excellent print, loose stitching", not
	"0.81 / 0.42". Thresholds live here so every surface grades identically.
]]
local QUALITY_GRADES = {
	{ min = 0.90, label = "Excellent" },
	{ min = 0.78, label = "Very good" },
	{ min = 0.64, label = "Good" },
	{ min = 0.50, label = "Acceptable" },
	{ min = 0.34, label = "Below standard" },
	{ min = 0.18, label = "Poor" },
	{ min = 0.00, label = "Unusable" },
}

function Format.qualityGrade(score: number): string
	for _, grade in ipairs(QUALITY_GRADES) do
		if score >= grade.min then
			return grade.label
		end
	end
	return "Unusable"
end

function Format.gsm(value: number): string
	return string.format("%dgsm", math.floor(value + 0.5))
end

-- "Noor Textiles \u{2022} Faisalabad, Pakistan"
function Format.joinWithBullet(parts: { string }): string
	local kept = {}
	for _, part in ipairs(parts) do
		if part and part ~= "" then
			table.insert(kept, part)
		end
	end
	return table.concat(kept, " \u{2022} ")
end

-- Spaced capitals for restrained section headers: "BRAND" -> "B R A N D".
-- Roblox TextLabels have no letter-spacing property; this is the usual stand-in.
function Format.tracked(text: string): string
	local chars = {}
	for _, codepoint in utf8.codes(text) do
		table.insert(chars, utf8.char(codepoint))
	end
	return table.concat(chars, " ")
end

function Format.truncate(text: string, maxLength: number): string
	if utf8.len(text) and (utf8.len(text) :: number) <= maxLength then
		return text
	end
	local offset = utf8.offset(text, maxLength)
	if not offset then
		return text
	end
	return string.sub(text, 1, offset - 1) .. "\u{2026}"
end

function Format.ordinal(n: number): string
	local mod100 = n % 100
	if mod100 >= 11 and mod100 <= 13 then
		return n .. "th"
	end
	local suffixes = { "st", "nd", "rd" }
	return n .. (suffixes[n % 10] or "th")
end

return Format
