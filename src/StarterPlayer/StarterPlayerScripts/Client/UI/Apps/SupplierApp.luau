--!strict
--[[
	Apps.SupplierApp

	The supplier marketplace: browse factories, read their profile, talk to them,
	get a quote, order a sample.

	== Not a shop ==

	The brief is explicit that this must feel like dealing with a manufacturer
	rather than buying from a generic store. What makes the difference here:

	* Each supplier has a NAMED contact who replies in their own voice, with a
	  delay derived from their communication trait. Noor takes fourteen seconds
	  to answer; Print Lab answers almost immediately. That delay is the cost of
	  their cheap pricing, and the player feels it rather than reading it.

	* The quote is an assessment, not a price tag. It names what they are good
	  at, warns where the spec sits outside their comfort, and states the MOQ.
	  Some suppliers REFUSE the job outright.

	* An expected-quality forecast is shown before any money moves. The player
	  is never ambushed by an outcome they had no way to anticipate.

	* Ordering is a confirmation step with the real cost and the real lead time,
	  not a one-click purchase.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Manufacturers = require(Shared.Config.Manufacturers)
local PrintMethods = require(Shared.Config.PrintMethods)
local Net = require(Shared.Net.Net)
local Format = require(Shared.Util.Format)

local Theme = require(script.Parent.Parent.Theme)
local Components = require(script.Parent.Parent.Components)

local SupplierApp = {}

-- Country flags as text. No image assets, consistent with the rest of the UI.
local COUNTRY_LABEL = {
	GB = "United Kingdom",
	PK = "Pakistan",
	TR = "T\u{00FC}rkiye",
	CN = "China",
}

function SupplierApp.mount(container: Frame, context: any)
	local uiScale = context.scale

	local selectedProductId: string? = context.params and context.params.productId or nil
	local selectedManufacturerId: string? = nil
	local currentQuote: any = nil
	local destroyed = false
	local conversation: { { from: string, text: string } } = {}
	local awaitingReply = false

	local LIST_WIDTH = 260

	-- ---------------------------------------------------------------- layout
	local listColumn = Components.frame({
		parent = container,
		name = "Suppliers",
		size = UDim2.new(0, math.round(LIST_WIDTH * uiScale), 1, 0),
		color = Theme.color.base,
	})
	Components.divider(listColumn, { vertical = true }).Position = UDim2.new(1, -1, 0, 0)

	local detailColumn = Components.frame({
		parent = container,
		name = "Detail",
		size = UDim2.new(1, -math.round(LIST_WIDTH * uiScale), 1, 0),
		position = UDim2.fromOffset(math.round(LIST_WIDTH * uiScale), 0),
		color = Theme.color.base,
	})

	local listScroll = Components.scroll({ parent = listColumn })
	Components.padding(listScroll, Theme.space.md, uiScale)
	Components.list(listScroll, { padding = Theme.space.sm, scale = uiScale })

	local detailScroll = Components.scroll({ parent = detailColumn })
	Components.padding(detailScroll, {
		top = Theme.space.xl,
		bottom = Theme.space.xxl,
		left = Theme.space.xxl,
		right = Theme.space.xxl,
	}, uiScale)
	Components.list(detailScroll, { padding = Theme.space.md, scale = uiScale })

	local supplierTiles: { [string]: any } = {}
	local renderDetail

	-- ---------------------------------------------------------------- product picker
	local function renderProductPicker(state: any)
		Components.sectionHeader({
			parent = listScroll,
			text = "Quoting for",
			layoutOrder = 1,
			scale = uiScale,
		})

		local products = {}
		for _, productId in ipairs(state.productOrder) do
			local product = state.products[productId]
			if product and product.stage ~= "Archived" and #(product.spec.graphics or {}) > 0 then
				table.insert(products, product)
			end
		end

		if #products == 0 then
			Components.text({
				parent = listScroll,
				text = "Design something first.",
				variant = "small",
				color = Theme.color.textTertiary,
				size = UDim2.new(1, 0, 0, math.round(20 * uiScale)),
				layoutOrder = 2,
				scale = uiScale,
			})
			return
		end

		-- Default to the first quotable product.
		if not selectedProductId or not state.products[selectedProductId] then
			selectedProductId = products[1].id
		end

		local picker = Components.frame({
			parent = listScroll,
			name = "ProductPicker",
			size = UDim2.new(1, 0, 0, math.round(#products * 34 * uiScale)),
			layoutOrder = 2,
		})
		Components.list(picker, { padding = Theme.space.xs, scale = uiScale })

		for index, product in ipairs(products) do
			local tile = Components.tile({
				parent = picker,
				name = product.id,
				size = UDim2.new(1, 0, 0, math.round(30 * uiScale)),
				layoutOrder = index,
				selected = product.id == selectedProductId,
				scale = uiScale,
				onClick = function()
					selectedProductId = product.id
					currentQuote = nil
					conversation = {}
					renderDetail()
					-- Refresh picker selection highlighting.
					for _, child in ipairs(picker:GetChildren()) do
						if child:IsA("TextButton") then
							local isSelected = child.Name == product.id
							local stroke = child:FindFirstChildOfClass("UIStroke")
							if stroke then
								stroke.Color = if isSelected then Theme.color.accent else Theme.color.border
								stroke.Thickness = if isSelected then 2 else 1
							end
						end
					end
				end,
			})

			Components.padding(tile.content, { left = Theme.space.sm, right = Theme.space.sm }, uiScale)
			Components.text({
				parent = tile.content,
				text = product.name,
				variant = "small",
				size = UDim2.fromScale(1, 1),
				scale = uiScale,
				truncate = true,
			})
		end
	end

	-- ---------------------------------------------------------------- supplier list
	local function renderSupplierList(state: any)
		for _, child in ipairs(listScroll:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		table.clear(supplierTiles)

		renderProductPicker(state)

		Components.spacer(listScroll, Theme.space.sm, 3, uiScale)
		Components.sectionHeader({
			parent = listScroll,
			text = "Manufacturers",
			layoutOrder = 4,
			scale = uiScale,
		})

		for index, manufacturer in ipairs(Manufacturers.list) do
			local tile = Components.tile({
				parent = listScroll,
				name = manufacturer.id,
				size = UDim2.new(1, 0, 0, math.round(68 * uiScale)),
				layoutOrder = 4 + index,
				selected = manufacturer.id == selectedManufacturerId,
				scale = uiScale,
				onClick = function()
					selectedManufacturerId = manufacturer.id
					currentQuote = nil
					conversation = {}
					for id, other in pairs(supplierTiles) do
						other.setSelected(id == manufacturer.id)
					end
					renderDetail()
					SupplierApp.fetchQuote(context, selectedProductId, manufacturer.id, function(quote)
						if not destroyed then
							currentQuote = quote
							renderDetail()
						end
					end)
				end,
			})
			supplierTiles[manufacturer.id] = tile

			Components.padding(tile.content, Theme.space.md, uiScale)

			Components.text({
				parent = tile.content,
				text = manufacturer.name,
				variant = "bodyStrong",
				size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
				scale = uiScale,
				truncate = true,
			})

			Components.text({
				parent = tile.content,
				text = manufacturer.city .. ", " .. manufacturer.country,
				variant = "micro",
				color = Theme.color.textTertiary,
				size = UDim2.new(1, 0, 0, math.round(14 * uiScale)),
				position = UDim2.fromOffset(0, math.round(20 * uiScale)),
				scale = uiScale,
				truncate = true,
			})

			Components.text({
				parent = tile.content,
				text = manufacturer.tagline,
				variant = "micro",
				color = Theme.color.textSecondary,
				size = UDim2.new(1, 0, 0, math.round(14 * uiScale)),
				position = UDim2.fromOffset(0, math.round(36 * uiScale)),
				scale = uiScale,
				truncate = true,
			})
		end
	end

	-- ---------------------------------------------------------------- detail
	function renderDetail()
		for _, child in ipairs(detailScroll:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		local state = context.getState()
		if not state then
			return
		end

		if not selectedManufacturerId then
			Components.emptyState({
				parent = detailScroll,
				title = "Pick a manufacturer",
				body = "Each one is better at something. Read their profile before you commit.",
				layoutOrder = 1,
				scale = uiScale,
			})
			return
		end

		local manufacturer = Manufacturers.get(selectedManufacturerId)
		if not manufacturer then
			return
		end

		local product = selectedProductId and state.products[selectedProductId]
		local order = 0
		local function nextOrder(): number
			order += 1
			return order
		end

		-- ---- header ----
		Components.text({
			parent = detailScroll,
			text = manufacturer.name,
			variant = "title",
			size = UDim2.new(1, 0, 0, math.round(30 * uiScale)),
			layoutOrder = nextOrder(),
			scale = uiScale,
		})

		Components.text({
			parent = detailScroll,
			text = Format.joinWithBullet({
				manufacturer.city,
				COUNTRY_LABEL[manufacturer.countryCode] or manufacturer.country,
				string.format("MOQ %d", manufacturer.moq),
			}),
			variant = "small",
			color = Theme.color.textTertiary,
			size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
			layoutOrder = nextOrder(),
			scale = uiScale,
		})

		Components.text({
			parent = detailScroll,
			text = manufacturer.description,
			variant = "body",
			color = Theme.color.textSecondary,
			size = UDim2.new(1, 0, 0, math.round(40 * uiScale)),
			wrap = true,
			layoutOrder = nextOrder(),
			scale = uiScale,
		})

		-- ---- strengths / weaknesses ----
		--[[
			Both are shown, always. A supplier the player can only see the upside
			of is a trap; showing the tradeoff up front is what makes the choice
			fair and the eventual sample feel earned.
		]]
		local traitsPanel = Components.frame({
			parent = detailScroll,
			name = "Traits",
			size = UDim2.new(1, 0, 0, math.round(118 * uiScale)),
			color = Theme.color.surface,
			radius = Theme.radius.lg,
			stroke = Theme.color.border,
			layoutOrder = nextOrder(),
		})
		Components.padding(traitsPanel, Theme.space.lg, uiScale)

		local strengthsColumn = Components.frame({
			parent = traitsPanel,
			name = "Strengths",
			size = UDim2.new(0.5, -math.round(8 * uiScale), 1, 0),
		})
		Components.list(strengthsColumn, { padding = Theme.space.xs, scale = uiScale })
		Components.sectionHeader({
			parent = strengthsColumn,
			text = "Strengths",
			layoutOrder = 1,
			scale = uiScale,
		})
		for index, strength in ipairs(manufacturer.strengths) do
			Components.text({
				parent = strengthsColumn,
				text = "\u{2022}  " .. strength,
				variant = "small",
				color = Theme.color.positive,
				size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
				layoutOrder = 1 + index,
				scale = uiScale,
				truncate = true,
			})
		end

		local weaknessesColumn = Components.frame({
			parent = traitsPanel,
			name = "Weaknesses",
			size = UDim2.new(0.5, -math.round(8 * uiScale), 1, 0),
			position = UDim2.new(0.5, math.round(8 * uiScale), 0, 0),
		})
		Components.list(weaknessesColumn, { padding = Theme.space.xs, scale = uiScale })
		Components.sectionHeader({
			parent = weaknessesColumn,
			text = "Tradeoffs",
			layoutOrder = 1,
			scale = uiScale,
		})
		for index, weakness in ipairs(manufacturer.weaknesses) do
			Components.text({
				parent = weaknessesColumn,
				text = "\u{2022}  " .. weakness,
				variant = "small",
				color = Theme.color.warning,
				size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
				layoutOrder = 1 + index,
				scale = uiScale,
				truncate = true,
			})
		end

		-- ---- conversation ----
		Components.sectionHeader({
			parent = detailScroll,
			text = "Messages with " .. manufacturer.contactName,
			layoutOrder = nextOrder(),
			scale = uiScale,
		})

		local thread = Components.frame({
			parent = detailScroll,
			name = "Thread",
			size = UDim2.new(1, 0, 0, 0),
			color = Theme.color.surface,
			radius = Theme.radius.lg,
			stroke = Theme.color.border,
			layoutOrder = nextOrder(),
			automaticSize = Enum.AutomaticSize.Y,
		})
		Components.padding(thread, Theme.space.lg, uiScale)
		Components.list(thread, { padding = Theme.space.sm, scale = uiScale })

		if #conversation == 0 then
			Components.text({
				parent = thread,
				text = "No messages yet. Introduce yourself.",
				variant = "small",
				color = Theme.color.textTertiary,
				size = UDim2.new(1, 0, 0, math.round(20 * uiScale)),
				layoutOrder = 1,
				scale = uiScale,
			})
		else
			for index, message in ipairs(conversation) do
				local fromPlayer = message.from == "you"
				Components.text({
					parent = thread,
					text = (if fromPlayer then "You" else manufacturer.contactName) .. ":",
					variant = "micro",
					color = if fromPlayer then Theme.color.textTertiary else context.accent(),
					size = UDim2.new(1, 0, 0, math.round(14 * uiScale)),
					layoutOrder = index * 2,
					scale = uiScale,
				})
				Components.text({
					parent = thread,
					text = message.text,
					variant = "small",
					color = if fromPlayer then Theme.color.textSecondary else Theme.color.textPrimary,
					size = UDim2.new(1, 0, 0, 0),
					automaticSize = Enum.AutomaticSize.Y,
					wrap = true,
					layoutOrder = index * 2 + 1,
					scale = uiScale,
				})
			end
		end

		if awaitingReply then
			Components.text({
				parent = thread,
				text = manufacturer.contactName .. " is typing\u{2026}",
				variant = "small",
				color = Theme.color.textTertiary,
				size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
				layoutOrder = 9999,
				scale = uiScale,
			})
		end

		-- Quick-ask buttons.
		local asks = Components.frame({
			parent = detailScroll,
			name = "Asks",
			size = UDim2.new(1, 0, 0, math.round(34 * uiScale)),
			layoutOrder = nextOrder(),
		})
		Components.list(asks, {
			direction = Enum.FillDirection.Horizontal,
			padding = Theme.space.sm,
			scale = uiScale,
		})

		local function ask(intent: string, label: string, buttonOrder: number)
			Components.button({
				parent = asks,
				text = label,
				variant = "ghost",
				size = UDim2.new(0, math.round(116 * uiScale), 0, math.round(32 * uiScale)),
				layoutOrder = buttonOrder,
				scale = uiScale,
				enabled = not awaitingReply,
				onClick = function()
					table.insert(conversation, { from = "you", text = label .. "?" })
					awaitingReply = true
					renderDetail()

					task.spawn(function()
						local response = Net.invoke("ContactSupplier", {
							manufacturerId = manufacturer.id,
							productId = selectedProductId,
							intent = intent,
						})

						if not response.ok then
							awaitingReply = false
							if not destroyed then
								renderDetail()
							end
							return
						end

						--[[
							Wait out the supplier's own reply delay. This is where a
							poor communicator costs the player something real: Noor's
							cheap pricing comes with a fourteen-second wait, and the
							player feels that rather than reading a stat.
						]]
						task.wait(response.data.replyDelaySeconds)
						if destroyed then
							return
						end

						awaitingReply = false
						table.insert(conversation, { from = "them", text = response.data.reply })
						renderDetail()
					end)
				end,
			})
		end

		ask("Introduce", "Introduce", 1)
		ask("AskCapability", "Capability", 2)
		ask("AskLeadTime", "Lead time", 3)
		ask("AskPricing", "Pricing", 4)

		-- ---- quote ----
		if not product then
			Components.emptyState({
				parent = detailScroll,
				title = "No product selected",
				body = "Design a piece with a graphic on it, then come back for a quote.",
				layoutOrder = nextOrder(),
				scale = uiScale,
			})
			return
		end

		Components.sectionHeader({
			parent = detailScroll,
			text = "Quote for " .. product.name,
			layoutOrder = nextOrder(),
			scale = uiScale,
		})

		if not currentQuote then
			Components.text({
				parent = detailScroll,
				text = "Pricing\u{2026}",
				variant = "small",
				color = Theme.color.textTertiary,
				size = UDim2.new(1, 0, 0, math.round(20 * uiScale)),
				layoutOrder = nextOrder(),
				scale = uiScale,
			})
			return
		end

		local quote = currentQuote.quote

		local quotePanel = Components.frame({
			parent = detailScroll,
			name = "Quote",
			size = UDim2.new(1, 0, 0, 0),
			color = Theme.color.surface,
			radius = Theme.radius.lg,
			stroke = if quote.canFulfil then Theme.color.border else Theme.color.critical,
			layoutOrder = nextOrder(),
			automaticSize = Enum.AutomaticSize.Y,
		})
		Components.padding(quotePanel, Theme.space.lg, uiScale)
		Components.list(quotePanel, { padding = Theme.space.sm, scale = uiScale })

		if not quote.canFulfil then
			Components.text({
				parent = quotePanel,
				text = quote.rejectionReason or "They cannot make this.",
				variant = "body",
				color = Theme.color.critical,
				size = UDim2.new(1, 0, 0, math.round(36 * uiScale)),
				wrap = true,
				layoutOrder = 1,
				scale = uiScale,
			})
			Components.text({
				parent = quotePanel,
				text = "Change the print method in Design, or try another factory.",
				variant = "small",
				color = Theme.color.textTertiary,
				size = UDim2.new(1, 0, 0, math.round(20 * uiScale)),
				layoutOrder = 2,
				scale = uiScale,
			})
			return
		end

		Components.statRow({
			parent = quotePanel,
			label = "Sample, delivered",
			value = Format.money(quote.sampleCostPence),
			layoutOrder = 1,
			scale = uiScale,
		})
		Components.statRow({
			parent = quotePanel,
			label = string.format("Unit cost at %d pieces", quote.moq),
			value = Format.money(quote.unitCostPence),
			valueColor = Theme.color.textSecondary,
			layoutOrder = 2,
			scale = uiScale,
		})
		Components.statRow({
			parent = quotePanel,
			label = "Production",
			value = Format.duration(quote.productionSeconds),
			valueColor = Theme.color.textSecondary,
			layoutOrder = 3,
			scale = uiScale,
		})
		Components.statRow({
			parent = quotePanel,
			label = "Shipping",
			value = Format.duration(quote.shippingSeconds),
			valueColor = Theme.color.textSecondary,
			layoutOrder = 4,
			scale = uiScale,
		})

		-- The honest forecast, before any money moves.
		Components.statRow({
			parent = quotePanel,
			label = "Expected quality",
			value = currentQuote.expectedQualityLabel,
			valueColor = Theme.qualityColor(currentQuote.expectedQuality),
			layoutOrder = 5,
			scale = uiScale,
		})

		if #quote.capabilityNotes > 0 then
			Components.divider(quotePanel, { layoutOrder = 6 })
			for index, note in ipairs(quote.capabilityNotes) do
				Components.text({
					parent = quotePanel,
					text = "\u{2022}  " .. note,
					variant = "small",
					color = Theme.color.textSecondary,
					size = UDim2.new(1, 0, 0, 0),
					automaticSize = Enum.AutomaticSize.Y,
					wrap = true,
					layoutOrder = 6 + index,
					scale = uiScale,
				})
			end
		end

		-- ---- order ----
		local canAfford = state.finances.cashPence >= quote.sampleCostPence
		local alreadySampling = product.stage == "SampleRequested"
			or product.stage == "SampleInProduction"
			or product.stage == "SampleShipped"

		Components.spacer(detailScroll, Theme.space.sm, nextOrder(), uiScale)

		local orderButton
		orderButton = Components.button({
			parent = detailScroll,
			text = string.format("Order sample \u{2014} %s", Format.money(quote.sampleCostPence)),
			variant = "primary",
			size = UDim2.new(0, math.round(280 * uiScale), 0, math.round(44 * uiScale)),
			layoutOrder = nextOrder(),
			scale = uiScale,
			enabled = canAfford and not alreadySampling,
			onClick = function()
				orderButton.setEnabled(false)
				orderButton.setText("Placing order\u{2026}")

				task.spawn(function()
					local response = Net.invoke("OrderSample", {
						productId = product.id,
						manufacturerId = manufacturer.id,
						-- The server recomputes and refuses a mismatch rather than
						-- charging a different amount.
						acknowledgedCostPence = quote.sampleCostPence,
					})

					if destroyed then
						return
					end

					if response.ok then
						context.notify({
							title = "Sample ordered",
							body = string.format(
								"%s are making it. It will arrive at your door.",
								manufacturer.name
							),
							kind = "positive",
						})
						currentQuote = nil
						context.close()
					else
						context.notify({
							title = "Order not placed",
							body = response.message,
							kind = "critical",
						})
						orderButton.setText(string.format(
							"Order sample \u{2014} %s", Format.money(quote.sampleCostPence)))
						orderButton.setEnabled(true)
					end
				end)
			end,
		})

		if alreadySampling then
			Components.text({
				parent = detailScroll,
				text = "A sample of this product is already being made.",
				variant = "small",
				color = Theme.color.warning,
				size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
				layoutOrder = nextOrder(),
				scale = uiScale,
			})
		elseif not canAfford then
			Components.text({
				parent = detailScroll,
				text = string.format(
					"You have %s. This sample costs %s.",
					Format.money(state.finances.cashPence),
					Format.money(quote.sampleCostPence)
				),
				variant = "small",
				color = Theme.color.critical,
				size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
				layoutOrder = nextOrder(),
				scale = uiScale,
			})
		end
	end

	-- ---------------------------------------------------------------- lifecycle
	local function refresh(state: any)
		if destroyed or not state then
			return
		end
		renderSupplierList(state)
		renderDetail()
	end

	refresh(context.getState())

	return {
		destroy = function()
			destroyed = true
		end,
		onStateChanged = refresh,
		onParams = function(params)
			if params and params.productId then
				selectedProductId = params.productId
				currentQuote = nil
				refresh(context.getState())
			end
		end,
	}
end

-- Fetches a quote and hands it back. Kept separate so the list and the detail
-- view can both trigger it without duplicating the call.
function SupplierApp.fetchQuote(context: any, productId: string?, manufacturerId: string, callback: (any) -> ())
	if not productId then
		return
	end
	task.spawn(function()
		local response = Net.invoke("GetQuote", {
			productId = productId,
			manufacturerId = manufacturerId,
		})
		if response.ok then
			callback(response.data)
		end
	end)
end

return SupplierApp
