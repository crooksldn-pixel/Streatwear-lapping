--!strict
--[[
	TableKit

	Table helpers used by persistence and state projection. The important ones:

	* deepCopy -- used whenever state crosses a boundary, so no caller can mutate
	  another system's table by holding a reference to it.
	* reconcile -- fills a loaded save with any keys added to the default schema
	  since it was written. This is what makes "add a field" a zero-work
	  migration.
	* isPlainData -- rejects anything DataStore cannot serialise BEFORE a save is
	  attempted, so a bad write surfaces as our own clear error rather than an
	  opaque DataStore rejection.
]]

local TableKit = {}

function TableKit.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in pairs(value :: any) do
		copy[key] = TableKit.deepCopy(child)
	end
	return copy :: any
end

function TableKit.deepFreeze<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	for _, child in pairs(value :: any) do
		if type(child) == "table" and not table.isfrozen(child) then
			TableKit.deepFreeze(child)
		end
	end
	if not table.isfrozen(value :: any) then
		table.freeze(value :: any)
	end
	return value
end

--[[
	Fills missing keys in `target` from `template`, recursively.

	Arrays are treated as opaque values, not merged element-wise: a saved list of
	ledger entries must not have template entries spliced into it. Arrays are
	detected as tables whose first key is 1.
]]
local function isArray(value: any): boolean
	return type(value) == "table" and (next(value) == nil or rawget(value, 1) ~= nil)
end

function TableKit.reconcile(target: any, template: any): any
	if type(target) ~= "table" then
		return TableKit.deepCopy(template)
	end

	for key, templateValue in pairs(template) do
		local current = target[key]
		if current == nil then
			target[key] = TableKit.deepCopy(templateValue)
		elseif type(templateValue) == "table" and type(current) == "table" then
			-- Only descend into dictionaries. Arrays stay as saved.
			if not isArray(templateValue) then
				TableKit.reconcile(current, templateValue)
			end
		elseif type(templateValue) ~= type(current) then
			-- A type change means the save is stale or tampered with. The template
			-- is authoritative; losing one field beats propagating a bad type
			-- into arithmetic later.
			target[key] = TableKit.deepCopy(templateValue)
		end
	end

	return target
end

function TableKit.count(value: { [any]: any }): number
	local n = 0
	for _ in pairs(value) do
		n += 1
	end
	return n
end

function TableKit.keys<K, V>(value: { [K]: V }): { K }
	local out = {}
	for key in pairs(value) do
		table.insert(out, key)
	end
	return out
end

function TableKit.values<K, V>(value: { [K]: V }): { V }
	local out = {}
	for _, item in pairs(value) do
		table.insert(out, item)
	end
	return out
end

function TableKit.map<T, U>(list: { T }, fn: (T, number) -> U): { U }
	local out = table.create(#list)
	for index, item in ipairs(list) do
		out[index] = fn(item, index)
	end
	return out
end

function TableKit.filter<T>(list: { T }, fn: (T, number) -> boolean): { T }
	local out = {}
	for index, item in ipairs(list) do
		if fn(item, index) then
			table.insert(out, item)
		end
	end
	return out
end

function TableKit.find<T>(list: { T }, fn: (T, number) -> boolean): (T?, number?)
	for index, item in ipairs(list) do
		if fn(item, index) then
			return item, index
		end
	end
	return nil, nil
end

function TableKit.removeValue<T>(list: { T }, value: T): boolean
	local index = table.find(list, value)
	if index then
		table.remove(list, index)
		return true
	end
	return false
end

-- Keeps the newest `maxLength` entries of an append-only list.
function TableKit.trimFront<T>(list: { T }, maxLength: number)
	while #list > maxLength do
		table.remove(list, 1)
	end
end

--[[
	Verifies a value graph is DataStore-serialisable.
	Returns false plus a dotted path to the first offending value.

	Rules enforced: no mixed-key tables, no non-string/number keys, no NaN or
	infinite numbers, no Roblox datatypes or functions, bounded depth.
]]
function TableKit.isPlainData(value: any, path: string?, depth: number?): (boolean, string?)
	local here = path or "root"
	local level = depth or 0

	if level > 32 then
		return false, here .. " (exceeds max depth)"
	end

	local valueType = type(value)

	if valueType == "string" or valueType == "boolean" then
		return true
	end

	if valueType == "number" then
		if value ~= value then
			return false, here .. " (NaN)"
		end
		if value == math.huge or value == -math.huge then
			return false, here .. " (infinite)"
		end
		return true
	end

	if valueType ~= "table" then
		return false, string.format("%s (unserialisable type %s)", here, typeof(value))
	end

	local hasArrayKeys, hasMapKeys = false, false
	for key, child in pairs(value) do
		local keyType = type(key)
		if keyType == "number" then
			if key % 1 ~= 0 or key < 1 then
				return false, string.format("%s[%s] (non-positive-integer numeric key)", here, tostring(key))
			end
			hasArrayKeys = true
		elseif keyType == "string" then
			hasMapKeys = true
		else
			return false, string.format("%s (key of type %s)", here, keyType)
		end

		local ok, failure = TableKit.isPlainData(child, string.format("%s.%s", here, tostring(key)), level + 1)
		if not ok then
			return false, failure
		end
	end

	if hasArrayKeys and hasMapKeys then
		return false, here .. " (mixed array and dictionary keys)"
	end

	return true
end

return TableKit
