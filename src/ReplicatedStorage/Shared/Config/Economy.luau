--!strict
--[[
	Config.Economy

	Money rules. All values are INTEGER PENCE.

	The starting figure is deliberately constraining: £400 buys roughly two
	samples from a mid-tier factory, or one from a premium one plus change. The
	player cannot sample everything, so choosing a manufacturer is an actual
	decision rather than a formality. Not balanced for a final build.
]]

export type EconomyConfig = {
	startingCashPence: number,
	currencyCode: string,
	ledgerMaxEntries: number,
	minTransactionPence: number,
	maxTransactionPence: number,
	sampleShippingSurchargePence: number,
	rushMultiplier: number,
	bulkDepositFraction: number,
}

local Economy: EconomyConfig = {
	-- £400.00
	startingCashPence = 40000,

	currencyCode = "GBP",

	-- Ledger is a rolling window. Statements only ever show recent activity, and
	-- an unbounded list would grow the save until it breached the DataStore
	-- value limit after a long session.
	ledgerMaxEntries = 150,

	--[[
		Sanity bounds on any single balance change. These are a tripwire, not a
		gameplay rule: if a service ever tries to move more than this in one go,
		it is a bug or an exploit attempt and the transaction is refused and
		logged rather than silently applied.
	]]
	minTransactionPence = 1,
	maxTransactionPence = 100000000, -- £1,000,000

	-- Flat courier charge added to every sample order on top of the factory fee,
	-- scaled per manufacturer by their shipping distance band.
	sampleShippingSurchargePence = 0,

	-- Reserved for a future "rush this order" option.
	rushMultiplier = 1.6,

	-- Reserved: fraction of a bulk order payable up front.
	bulkDepositFraction = 0.3,
}

return table.freeze(Economy)
