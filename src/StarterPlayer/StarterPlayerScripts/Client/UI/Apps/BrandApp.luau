--!strict
--[[
	Apps.BrandApp

	Brand setup, and the brand overview once set up.

	The app has two completely different jobs depending on state, which is why it
	branches at mount rather than trying to be one screen that handles both:

		no brand  -> a setup form: name, tagline, aesthetic direction
		brand set -> an overview: identity, finances, progress

	== On the style presets ==

	The copy deliberately frames these as a STARTING DIRECTION, not a class.
	Nothing is locked by the choice -- it only seeds the defaults of the first
	product. Saying so plainly in the UI matters, because a player who thinks
	they are picking a permanent class will agonise over it.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Styles = require(Shared.Config.Styles)
local Net = require(Shared.Net.Net)
local Format = require(Shared.Util.Format)

local Theme = require(script.Parent.Parent.Theme)
local Components = require(script.Parent.Parent.Components)

local BrandApp = {}

function BrandApp.mount(container: Frame, context: any)
	local state = context.getState()
	if state and state.identity.created then
		return BrandApp.mountOverview(container, context)
	end
	return BrandApp.mountSetup(container, context)
end

-- ============================================================================
-- Setup
-- ============================================================================

function BrandApp.mountSetup(container: Frame, context: any)
	local uiScale = context.scale

	local scroll = Components.scroll({ parent = container })
	Components.padding(scroll, {
		top = Theme.space.xxl,
		bottom = Theme.space.xxl,
		left = Theme.space.xxxl,
		right = Theme.space.xxxl,
	}, uiScale)
	Components.list(scroll, { padding = Theme.space.lg, scale = uiScale })

	-- ---- header ----
	Components.text({
		parent = scroll,
		text = "Start a brand",
		variant = "display",
		size = UDim2.new(1, 0, 0, math.round(42 * uiScale)),
		layoutOrder = 1,
		scale = uiScale,
	})

	Components.text({
		parent = scroll,
		text = "Everything after this \u{2014} every product, every sample, every order \u{2014} carries this name.",
		variant = "body",
		color = Theme.color.textSecondary,
		size = UDim2.new(1, 0, 0, math.round(22 * uiScale)),
		layoutOrder = 2,
		scale = uiScale,
		wrap = true,
	})

	Components.spacer(scroll, Theme.space.md, 3, uiScale)

	-- ---- name ----
	Components.sectionHeader({ parent = scroll, text = "Brand name", layoutOrder = 4, scale = uiScale })

	local nameValue = ""
	local nameField = Components.field({
		parent = scroll,
		name = "BrandName",
		placeholder = "e.g. Noir Atelier",
		maxLength = 28,
		layoutOrder = 5,
		scale = uiScale,
	})

	local nameHint = Components.text({
		parent = scroll,
		text = "2\u{2013}28 characters. Letters, numbers, spaces, and - . & '",
		variant = "small",
		color = Theme.color.textTertiary,
		size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
		layoutOrder = 6,
		scale = uiScale,
	})

	-- ---- tagline ----
	Components.sectionHeader({ parent = scroll, text = "Tagline (optional)", layoutOrder = 7, scale = uiScale })

	local taglineField = Components.field({
		parent = scroll,
		name = "Tagline",
		placeholder = "e.g. Built from a bedroom",
		maxLength = 48,
		layoutOrder = 8,
		scale = uiScale,
	})

	Components.spacer(scroll, Theme.space.sm, 9, uiScale)

	-- ---- style direction ----
	Components.sectionHeader({ parent = scroll, text = "Starting direction", layoutOrder = 10, scale = uiScale })

	Components.text({
		parent = scroll,
		text = "This only sets your starting defaults. You can make anything you like, and change direction whenever you want.",
		variant = "small",
		color = Theme.color.textTertiary,
		size = UDim2.new(1, 0, 0, math.round(32 * uiScale)),
		wrap = true,
		layoutOrder = 11,
		scale = uiScale,
	})

	local styleGrid = Components.frame({
		parent = scroll,
		name = "Styles",
		size = UDim2.new(1, 0, 0, math.round(236 * uiScale)),
		layoutOrder = 12,
	})
	Components.grid(styleGrid, {
		cellSize = UDim2.new(0.325, -math.round(8 * uiScale), 0, math.round(110 * uiScale)),
		padding = Theme.space.md,
		scale = uiScale,
	})

	local selectedStyleId: string? = nil
	local styleTiles: { [string]: any } = {}

	local function selectStyle(styleId: string)
		selectedStyleId = styleId
		for id, tile in pairs(styleTiles) do
			tile.setSelected(id == styleId)
		end
	end

	for index, style in ipairs(Styles.list) do
		local tile = Components.tile({
			parent = styleGrid,
			name = style.id,
			layoutOrder = index,
			scale = uiScale,
			onClick = function()
				selectStyle(style.id)
			end,
		})
		styleTiles[style.id] = tile

		Components.padding(tile.content, Theme.space.md, uiScale)
		Components.list(tile.content, { padding = Theme.space.xs, scale = uiScale })

		-- A thin accent rule so each direction has a visual identity without
		-- colouring the whole tile.
		Components.frame({
			parent = tile.content,
			name = "Accent",
			size = UDim2.new(0, math.round(22 * uiScale), 0, math.round(2 * uiScale)),
			color = style.accent,
			layoutOrder = 1,
		})

		Components.text({
			parent = tile.content,
			text = style.name,
			variant = "bodyStrong",
			size = UDim2.new(1, 0, 0, math.round(19 * uiScale)),
			layoutOrder = 2,
			scale = uiScale,
		})

		Components.text({
			parent = tile.content,
			text = style.tagline,
			variant = "small",
			color = Theme.color.textTertiary,
			size = UDim2.new(1, 0, 0, math.round(30 * uiScale)),
			wrap = true,
			layoutOrder = 3,
			scale = uiScale,
		})
	end

	Components.spacer(scroll, Theme.space.md, 13, uiScale)

	-- ---- submit ----
	local errorLabel = Components.text({
		parent = scroll,
		text = "",
		variant = "small",
		color = Theme.color.critical,
		size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
		layoutOrder = 14,
		scale = uiScale,
		wrap = true,
	})

	local submitting = false
	local submit

	submit = Components.button({
		parent = scroll,
		text = "Create brand",
		variant = "primary",
		size = UDim2.new(0, math.round(200 * uiScale), 0, math.round(44 * uiScale)),
		layoutOrder = 15,
		scale = uiScale,
		enabled = false,
		onClick = function()
			if submitting or not selectedStyleId then
				return
			end
			submitting = true
			submit.setEnabled(false)
			submit.setText("Creating\u{2026}")
			errorLabel.Text = ""

			task.spawn(function()
				local response = Net.invoke("CreateBrand", {
					name = nameField.Text,
					tagline = taglineField.Text,
					styleId = selectedStyleId,
				})

				submitting = false
				submit.setText("Create brand")

				if response.ok then
					context.notify({
						title = string.upper(nameField.Text) .. " is live",
						body = "Open Design and make your first piece.",
						kind = "positive",
					})
					--[[
						Navigation is NOT done here.

						The RemoteFunction response can arrive before the
						StateChanged push that unlocks the Design app, and the
						Shell refuses to navigate to an app it still believes is
						locked -- so navigating on the response silently did
						nothing and the player was left staring at the setup form
						they had just completed.

						Instead `onStateChanged` below drives it, which fires
						exactly when the client holds the state that makes the
						app available. That ordering is guaranteed rather than
						raced.
					]]
				else
					errorLabel.Text = response.message or "That did not work."
					submit.setEnabled(true)
				end
			end)
		end,
	})

	--[[
		The button only enables once both a valid-looking name and a direction
		exist. The server validates independently -- this is purely so the player
		is not invited to press a button that is certain to fail.
	]]
	local function refreshSubmit()
		local name = nameField.Text
		local nameOk = #name >= 2 and #name <= 28 and string.match(name, "%a") ~= nil
		submit.setEnabled(nameOk and selectedStyleId ~= nil and not submitting)

		if #name > 0 and not nameOk then
			nameHint.Text = "Needs at least 2 characters and one letter."
			nameHint.TextColor3 = Theme.color.warning
		else
			nameHint.Text = "2\u{2013}28 characters. Letters, numbers, spaces, and - . & '"
			nameHint.TextColor3 = Theme.color.textTertiary
		end
	end

	nameField:GetPropertyChangedSignal("Text"):Connect(refreshSubmit)

	local baseSelectStyle = selectStyle
	selectStyle = function(styleId: string)
		baseSelectStyle(styleId)
		refreshSubmit()
	end

	return {
		destroy = function() end,
		onStateChanged = function(state)
			--[[
				The brand now exists, so this setup form is finished. Move the
				player on to Design -- the next thing they actually want to do,
				and a different app, so the Shell genuinely remounts rather than
				treating it as a refresh of the current one.
			]]
			if state.identity.created then
				context.navigate("design")
			end
		end,
	}
end

-- ============================================================================
-- Overview
-- ============================================================================

function BrandApp.mountOverview(container: Frame, context: any)
	local uiScale = context.scale

	local scroll = Components.scroll({ parent = container })
	Components.padding(scroll, {
		top = Theme.space.xxl,
		bottom = Theme.space.xxl,
		left = Theme.space.xxxl,
		right = Theme.space.xxxl,
	}, uiScale)
	Components.list(scroll, { padding = Theme.space.lg, scale = uiScale })

	local state = context.getState()
	local style = Styles.getOrDefault(state.identity.styleId)

	-- ---- identity ----
	local accentRule = Components.frame({
		parent = scroll,
		name = "Accent",
		size = UDim2.new(0, math.round(40 * uiScale), 0, math.round(3 * uiScale)),
		color = style.accent,
		layoutOrder = 1,
	})

	local nameLabel = Components.text({
		parent = scroll,
		text = state.identity.name,
		variant = "display",
		size = UDim2.new(1, 0, 0, math.round(44 * uiScale)),
		layoutOrder = 2,
		scale = uiScale,
		truncate = true,
	})

	local taglineLabel = Components.text({
		parent = scroll,
		text = state.identity.tagline ~= "" and state.identity.tagline or style.tagline,
		variant = "body",
		color = Theme.color.textSecondary,
		size = UDim2.new(1, 0, 0, math.round(22 * uiScale)),
		layoutOrder = 3,
		scale = uiScale,
	})

	local chips = Components.frame({
		parent = scroll,
		name = "Chips",
		size = UDim2.new(1, 0, 0, math.round(24 * uiScale)),
		layoutOrder = 4,
	})
	Components.list(chips, {
		direction = Enum.FillDirection.Horizontal,
		padding = Theme.space.sm,
		scale = uiScale,
	})
	Components.chip({ parent = chips, text = style.name, layoutOrder = 1, scale = uiScale })
	local stageChip = Components.chip({
		parent = chips,
		text = state.progression.stage,
		layoutOrder = 2,
		scale = uiScale,
	})

	Components.spacer(scroll, Theme.space.lg, 5, uiScale)

	-- ---- finances ----
	Components.sectionHeader({ parent = scroll, text = "Finances", layoutOrder = 6, scale = uiScale })

	local financePanel = Components.frame({
		parent = scroll,
		name = "Finances",
		size = UDim2.new(1, 0, 0, math.round(110 * uiScale)),
		color = Theme.color.surface,
		radius = Theme.radius.lg,
		stroke = Theme.color.border,
		layoutOrder = 7,
	})
	Components.padding(financePanel, Theme.space.lg, uiScale)
	Components.list(financePanel, { padding = Theme.space.xs, scale = uiScale })

	local cashRow = Components.statRow({
		parent = financePanel,
		label = "Available cash",
		value = Format.money(state.finances.cashPence),
		layoutOrder = 1,
		scale = uiScale,
	})
	local spendRow = Components.statRow({
		parent = financePanel,
		label = "Spent to date",
		value = Format.money(state.finances.lifetimeSpendPence),
		valueColor = Theme.color.textSecondary,
		layoutOrder = 2,
		scale = uiScale,
	})
	local revenueRow = Components.statRow({
		parent = financePanel,
		label = "Revenue to date",
		value = Format.money(state.finances.lifetimeRevenuePence),
		valueColor = Theme.color.textSecondary,
		layoutOrder = 3,
		scale = uiScale,
	})

	-- ---- recent activity ----
	Components.sectionHeader({ parent = scroll, text = "Recent activity", layoutOrder = 8, scale = uiScale })

	local ledgerPanel = Components.frame({
		parent = scroll,
		name = "Ledger",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.color.surface,
		radius = Theme.radius.lg,
		stroke = Theme.color.border,
		layoutOrder = 9,
		automaticSize = Enum.AutomaticSize.Y,
	})
	Components.padding(ledgerPanel, Theme.space.lg, uiScale)
	Components.list(ledgerPanel, { padding = Theme.space.sm, scale = uiScale })

	local function renderLedger(currentState: any)
		for _, child in ipairs(ledgerPanel:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		local ledger = currentState.finances.ledger
		if #ledger == 0 then
			Components.text({
				parent = ledgerPanel,
				text = "Nothing yet.",
				variant = "small",
				color = Theme.color.textTertiary,
				size = UDim2.new(1, 0, 0, math.round(20 * uiScale)),
				scale = uiScale,
			})
			return
		end

		-- Newest first.
		local shown = 0
		for index = #ledger, 1, -1 do
			if shown >= 8 then
				break
			end
			shown += 1
			local entry = ledger[index]
			Components.statRow({
				parent = ledgerPanel,
				label = entry.label,
				value = Format.moneySigned(entry.amountPence),
				valueColor = if entry.amountPence < 0 then Theme.color.critical else Theme.color.positive,
				layoutOrder = shown,
				scale = uiScale,
			})
		end
	end

	renderLedger(state)

	return {
		destroy = function() end,
		onStateChanged = function(newState)
			nameLabel.Text = newState.identity.name
			taglineLabel.Text = newState.identity.tagline ~= "" and newState.identity.tagline or style.tagline

			-- A stat row holds exactly two labels: [1] is the caption, [2] the value.
			local function setRowValue(row: Frame, value: string)
				local labels = {}
				for _, child in ipairs(row:GetChildren()) do
					if child:IsA("TextLabel") then
						table.insert(labels, child)
					end
				end
				-- The second label in a stat row is the value.
				if labels[2] then
					labels[2].Text = value
				end
			end

			setRowValue(cashRow, Format.money(newState.finances.cashPence))
			setRowValue(spendRow, Format.money(newState.finances.lifetimeSpendPence))
			setRowValue(revenueRow, Format.money(newState.finances.lifetimeRevenuePence))

			local stageText = stageChip:FindFirstChildOfClass("TextLabel")
			if stageText then
				stageText.Text = newState.progression.stage
			end

			renderLedger(newState)
		end,
	}
end

return BrandApp
