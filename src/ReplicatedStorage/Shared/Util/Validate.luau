--!strict
--[[
	Validate

	Declarative payload validation for remote traffic.

	Every remote entry point runs its payload through a schema before any service
	sees it. The threat model is that an exploiter can call any RemoteEvent or
	RemoteFunction with arbitrary arguments, unlimited times, including values
	designed to be hostile rather than merely wrong:

	* wrong types (a table where a number is expected)
	* NaN / infinity, which pass `type(x) == "number"` and then poison arithmetic
	  and comparisons (NaN defeats every bounds check written as `x > min`)
	* enormous strings or deeply nested tables, as a memory/CPU attack
	* extra keys, to smuggle fields a handler might forward verbatim into state
	* metatables and cyclic tables

	`strict` schemas reject unknown keys outright. Handlers therefore never see a
	field they did not ask for, which is what stops a payload like
	`{ name = "x", cashPence = 999999 }` from being reconciled into state by a
	careless merge somewhere downstream.
]]

local Validate = {}

local MAX_TABLE_DEPTH = 8
local MAX_TABLE_KEYS = 64

export type Issue = string

export type FieldSpec = {
	type: string, -- "string" | "number" | "integer" | "boolean" | "table" | "array"
	optional: boolean?,
	default: any?,

	-- strings
	minLength: number?,
	maxLength: number?,
	pattern: string?,

	-- numbers
	min: number?,
	max: number?,

	-- any
	oneOf: { any }?,
	enum: { isValid: (unknown) -> boolean }?, -- an Enums entry

	-- tables / arrays
	fields: { [string]: FieldSpec }?, -- nested object schema
	item: FieldSpec?, -- array element schema
	maxItems: number?,

	check: ((value: any) -> (boolean, string?))?, -- bespoke rule
}

export type Schema = {
	fields: { [string]: FieldSpec },
	strict: boolean?, -- defaults to true
}

-- ============================================================================
-- Scalar guards
-- ============================================================================

--[[
	A finite real number. This is the single most important guard in the file.
	`type(0/0) == "number"` is true, and NaN compares false against every bound,
	so `if value < min then reject end` lets NaN straight through. Infinity
	likewise survives naive range checks when used as a multiplier.
]]
function Validate.isFiniteNumber(value: unknown): boolean
	if type(value) ~= "number" then
		return false
	end
	local n = value :: number
	if n ~= n then -- NaN
		return false
	end
	if n == math.huge or n == -math.huge then
		return false
	end
	return true
end

function Validate.isInteger(value: unknown): boolean
	return Validate.isFiniteNumber(value) and (value :: number) % 1 == 0
end

function Validate.isSafeString(value: unknown, maxLength: number?): boolean
	if type(value) ~= "string" then
		return false
	end
	return #(value :: string) <= (maxLength or 256)
end

-- ============================================================================
-- Structural guard
-- ============================================================================

--[[
	Rejects hostile table shapes before any per-field work: cycles, metatables,
	excessive depth, excessive key counts. Runs first so a malicious payload
	cannot make the validator itself expensive.
]]
local function assertSaneTable(value: any, depth: number, seen: { [any]: boolean }, path: string): (boolean, string?)
	if depth > MAX_TABLE_DEPTH then
		return false, path .. ": nested too deeply"
	end
	if seen[value] then
		return false, path .. ": cyclic table"
	end
	if getmetatable(value :: any) ~= nil then
		return false, path .. ": table has a metatable"
	end

	seen[value] = true

	local keyCount = 0
	for key, child in pairs(value) do
		keyCount += 1
		if keyCount > MAX_TABLE_KEYS then
			return false, path .. ": too many keys"
		end

		local keyType = type(key)
		if keyType ~= "string" and keyType ~= "number" then
			return false, path .. ": key of type " .. keyType
		end
		if keyType == "string" and #(key :: string) > 64 then
			return false, path .. ": key name too long"
		end

		local childType = type(child)
		if childType == "table" then
			local ok, issue = assertSaneTable(child, depth + 1, seen, path .. "." .. tostring(key))
			if not ok then
				return false, issue
			end
		elseif childType ~= "string" and childType ~= "number" and childType ~= "boolean" then
			return false, string.format("%s.%s: disallowed value type %s", path, tostring(key), typeof(child))
		end
	end

	seen[value] = nil
	return true
end

Validate.assertSaneTable = function(value: any): (boolean, string?)
	if type(value) ~= "table" then
		return false, "not a table"
	end
	return assertSaneTable(value, 1, {}, "payload")
end

-- ============================================================================
-- Field validation
-- ============================================================================

local validateField

local function validateObject(
	value: any,
	fields: { [string]: FieldSpec },
	strict: boolean,
	path: string,
	out: { [string]: any }
): (boolean, string?)
	if type(value) ~= "table" then
		return false, path .. ": expected a table"
	end

	if strict then
		for key in pairs(value) do
			if type(key) ~= "string" or fields[key] == nil then
				return false, string.format("%s: unexpected field %q", path, tostring(key))
			end
		end
	end

	for name, spec in pairs(fields) do
		local raw = value[name]
		local fieldPath = path .. "." .. name

		if raw == nil then
			if not spec.optional then
				return false, fieldPath .. ": required"
			end
			if spec.default ~= nil then
				out[name] = spec.default
			end
		else
			local ok, issueOrValue = validateField(raw, spec, fieldPath)
			if not ok then
				return false, issueOrValue :: string
			end
			out[name] = issueOrValue
		end
	end

	return true
end

-- Returns (true, coercedValue) or (false, issue).
function validateField(value: any, spec: FieldSpec, path: string): (boolean, any)
	local kind = spec.type

	if kind == "string" then
		if type(value) ~= "string" then
			return false, path .. ": expected a string"
		end
		local text = value :: string
		local maxLength = spec.maxLength or 256
		if #text > maxLength then
			return false, string.format("%s: longer than %d characters", path, maxLength)
		end
		if spec.minLength and #text < spec.minLength then
			return false, string.format("%s: shorter than %d characters", path, spec.minLength)
		end
		if spec.pattern and not string.match(text, spec.pattern) then
			return false, path .. ": contains disallowed characters"
		end
		if spec.oneOf and not table.find(spec.oneOf, text) then
			return false, path .. ": not an allowed value"
		end
		if spec.enum and not spec.enum.isValid(text) then
			return false, path .. ": not a valid enum value"
		end

	elseif kind == "number" or kind == "integer" then
		if not Validate.isFiniteNumber(value) then
			return false, path .. ": expected a finite number"
		end
		local n = value :: number
		if kind == "integer" and n % 1 ~= 0 then
			return false, path .. ": expected a whole number"
		end
		if spec.min and n < spec.min then
			return false, string.format("%s: below minimum %s", path, tostring(spec.min))
		end
		if spec.max and n > spec.max then
			return false, string.format("%s: above maximum %s", path, tostring(spec.max))
		end
		if spec.oneOf and not table.find(spec.oneOf, n) then
			return false, path .. ": not an allowed value"
		end

	elseif kind == "boolean" then
		if type(value) ~= "boolean" then
			return false, path .. ": expected a boolean"
		end

	elseif kind == "table" then
		if type(value) ~= "table" then
			return false, path .. ": expected a table"
		end
		if spec.fields then
			local nested: { [string]: any } = {}
			local ok, issue = validateObject(value, spec.fields, true, path, nested)
			if not ok then
				return false, issue
			end
			return true, nested
		end

	elseif kind == "array" then
		if type(value) ~= "table" then
			return false, path .. ": expected an array"
		end
		local list = value :: { any }
		local maxItems = spec.maxItems or 32
		local length = #list
		if length > maxItems then
			return false, string.format("%s: more than %d items", path, maxItems)
		end
		-- Reject sparse / dictionary-keyed "arrays": #list would understate them.
		local counted = 0
		for _ in pairs(list) do
			counted += 1
		end
		if counted ~= length then
			return false, path .. ": array has non-sequential keys"
		end

		local coerced = table.create(length)
		if spec.item then
			for index, item in ipairs(list) do
				local ok, issueOrValue = validateField(item, spec.item, string.format("%s[%d]", path, index))
				if not ok then
					return false, issueOrValue
				end
				coerced[index] = issueOrValue
			end
		else
			coerced = list
		end
		return true, coerced
	else
		return false, path .. ": schema declares unknown type " .. tostring(kind)
	end

	if spec.check then
		local ok, issue = spec.check(value)
		if not ok then
			return false, path .. ": " .. (issue or "failed validation")
		end
	end

	return true, value
end

--[[
	Validate.payload(value, schema) -> ok, cleanedPayload | issue

	The returned table is freshly built from validated fields only -- it is never
	the caller's table. A handler mutating it cannot affect anything the client
	sent, and no unvalidated key can survive into it.
]]
function Validate.payload(value: any, schema: Schema): (boolean, any)
	if value == nil then
		value = {}
	end

	local sane, issue = Validate.assertSaneTable(value)
	if not sane then
		return false, issue
	end

	local cleaned: { [string]: any } = {}
	local strict = schema.strict ~= false
	local ok, failure = validateObject(value, schema.fields, strict, "payload", cleaned)
	if not ok then
		return false, failure
	end

	return true, cleaned
end

-- ============================================================================
-- Shared field specs
-- ============================================================================

--[[
	Player-authored text. The pattern is an ALLOW-list: letters, digits, spaces
	and a small set of punctuation that real brand names use. Everything else --
	control characters, rich-text markup that TextLabels would interpret, zero
	width joiners used to spoof names -- is rejected rather than stripped,
	because silently rewriting someone's brand name is worse UX than telling them
	the character is not allowed.
]]
Validate.BRAND_NAME_PATTERN = "^[%w%s%-%.&'\u{2019}]+$"

function Validate.brandName(): FieldSpec
	return {
		type = "string",
		minLength = 2,
		maxLength = 28,
		pattern = Validate.BRAND_NAME_PATTERN,
		check = function(value: any): (boolean, string?)
			local text = value :: string
			if string.match(text, "^%s") or string.match(text, "%s$") then
				return false, "cannot start or end with a space"
			end
			if string.match(text, "%s%s") then
				return false, "cannot contain repeated spaces"
			end
			if not string.match(text, "%a") then
				return false, "must contain at least one letter"
			end
			return true
		end,
	}
end

function Validate.freeText(maxLength: number, optional: boolean?): FieldSpec
	return {
		type = "string",
		optional = optional,
		maxLength = maxLength,
		pattern = "^[%w%s%-%.,&'\u{2019}!%?:%(%)/]*$",
	}
end

function Validate.entityId(prefix: string): FieldSpec
	return {
		type = "string",
		maxLength = 24,
		pattern = "^" .. prefix .. "%-%d+$",
	}
end

function Validate.configKey(optional: boolean?): FieldSpec
	-- Config keys are internal identifiers; a tight charset means a bad key can
	-- never be mistaken for a path or an injection attempt in a log line.
	return {
		type = "string",
		optional = optional,
		minLength = 1,
		maxLength = 48,
		pattern = "^[%w_%-]+$",
	}
end

function Validate.unitScalar(optional: boolean?): FieldSpec
	return { type = "number", optional = optional, min = 0, max = 1 }
end

return Validate
