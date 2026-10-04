--!strict
--[[
	Signal

	Minimal synchronous signal. Services communicate through these instead of
	reaching into each other, which is what keeps DeliveryService from needing to
	know SampleOrderService exists (it just listens for OrderDelivered).

	Deliberately not BindableEvent-backed: BindableEvents deep-copy their
	arguments across the boundary, which would silently clone the state tables we
	pass around and break identity comparisons.

	Handlers run synchronously in connection order. A handler that errors is
	logged and skipped so one bad listener cannot halt a dispatch mid-way.
]]

local Connection = {}
Connection.__index = Connection

export type Connection = typeof(setmetatable(
	{} :: { _signal: any, _fn: ((...any) -> ())?, connected: boolean },
	Connection
))

function Connection.disconnect(self: Connection)
	if not self.connected then
		return
	end
	self.connected = false
	local signal = self._signal
	local index = table.find(signal._connections, self)
	if index then
		table.remove(signal._connections, index)
	end
	self._fn = nil
end

-- Alias so these can be used where a RBXScriptConnection is expected by habit.
Connection.Disconnect = Connection.disconnect

local Signal = {}
Signal.__index = Signal

export type Signal = typeof(setmetatable(
	{} :: { _connections: { Connection }, _name: string },
	Signal
))

function Signal.new(name: string?): Signal
	return setmetatable({
		_connections = {},
		_name = name or "Signal",
	}, Signal) :: any
end

function Signal.connect(self: Signal, fn: (...any) -> ()): Connection
	assert(type(fn) == "function", "Signal:connect expects a function")
	local connection = setmetatable({
		_signal = self,
		_fn = fn,
		connected = true,
	}, Connection) :: any
	table.insert(self._connections, connection)
	return connection
end

-- Fires at most once, then disconnects itself.
function Signal.once(self: Signal, fn: (...any) -> ()): Connection
	local connection: Connection
	connection = self:connect(function(...)
		connection:disconnect()
		fn(...)
	end)
	return connection
end

function Signal.fire(self: Signal, ...: any)
	-- Iterate a snapshot: handlers are allowed to connect/disconnect during
	-- dispatch without mutating the list being walked.
	local snapshot = table.clone(self._connections)
	for _, connection in ipairs(snapshot) do
		if connection.connected and connection._fn then
			local ok, err = pcall(connection._fn, ...)
			if not ok then
				warn(string.format("[Signal:%s] handler error: %s", self._name, tostring(err)))
			end
		end
	end
end

function Signal.disconnectAll(self: Signal)
	for _, connection in ipairs(table.clone(self._connections)) do
		connection:disconnect()
	end
	table.clear(self._connections)
end

function Signal.countConnections(self: Signal): number
	return #self._connections
end

-- Capitalised aliases for call-site consistency with Roblox events.
Signal.Connect = Signal.connect
Signal.Once = Signal.once
Signal.Fire = Signal.fire
Signal.DisconnectAll = Signal.disconnectAll

return Signal
