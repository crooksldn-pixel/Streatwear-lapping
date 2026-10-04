--!strict
--[[
	UI.Shell

	The laptop's operating system: one window, one sidebar, one content host.

	== Why a shell at all ==

	The brief is explicit that apps must NOT each be a separate hardcoded
	ScreenGui with duplicated behaviour. So the shell owns everything an app
	would otherwise reimplement:

		* the single ScreenGui and the window frame
		* opening and closing, and the transition
		* the sidebar, built from Config.Progression rather than hardcoded
		* which app is mounted, and tearing the previous one down
		* the status bar (brand name, balance, clock)
		* routing state updates to the live app

	An app is just: `mount(container, context) -> handle`. It receives a bare
	Frame and an AppContext and never touches anything above itself.

	== App availability is server-derived ==

	The sidebar is built from `state.availableApps`, which the SERVER computes
	from Progression. The client cannot grant itself an app by editing a local
	table, and the two can never disagree about what should be visible.
]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Progression = require(Shared.Config.Progression)
local Styles = require(Shared.Config.Styles)
local Format = require(Shared.Util.Format)

local Theme = require(script.Parent.Theme)
local Components = require(script.Parent.Components)

local Shell = {}
Shell.__index = Shell

--[[
	App definitions. `order` fixes sidebar position; `icon` is a short glyph
	rather than an image asset, keeping the UI free of asset dependencies and
	consistent with the restrained visual language.
]]
local APP_META = {
	brand = { title = "Brand", icon = "\u{25C8}", order = 1, subtitle = "Identity" },
	design = { title = "Design", icon = "\u{25A3}", order = 2, subtitle = "Products" },
	suppliers = { title = "Suppliers", icon = "\u{25A4}", order = 3, subtitle = "Manufacturing" },
}

function Shell.new(controllers: any)
	local self = setmetatable({}, Shell)
	self.controllers = controllers
	self.open = false
	self.currentAppId = nil :: string?
	self.currentHandle = nil :: any
	self.apps = {} :: { [string]: any }
	self.navButtons = {} :: { [string]: any }
	self.scale = 1
	self.gui = nil :: ScreenGui?
	return self
end

function Shell:RegisterApp(id: string, app: any)
	self.apps[id] = app
end

-- ============================================================================
-- Construction
-- ============================================================================

function Shell:Build()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local camera = workspace.CurrentCamera
	local uiScale = Theme.scale(camera.ViewportSize)
	self.scale = uiScale

	local gui = Instance.new("ScreenGui")
	gui.Name = "BrandOS"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 10
	gui.Enabled = false
	gui.Parent = playerGui
	self.gui = gui

	--[[
		Scrim. Dims the bedroom behind the laptop without hiding it -- the brief
		asks for the physical world to remain the primary space, so the room
		stays visible through a partial dim rather than being blacked out.
	]]
	local scrim = Components.frame({
		name = "Scrim",
		parent = gui,
		size = UDim2.fromScale(1, 1),
		color = Color3.new(0, 0, 0),
		transparency = 1,
		zIndex = 1,
	})
	self.scrim = scrim

	local windowWidth = math.round(Theme.OS_WIDTH * uiScale)
	local windowHeight = math.round(Theme.OS_HEIGHT * uiScale)

	local window = Components.frame({
		name = "Window",
		parent = gui,
		size = UDim2.fromOffset(windowWidth, windowHeight),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		color = Theme.color.base,
		radius = Theme.radius.xl,
		stroke = Theme.color.border,
		clip = true,
		zIndex = 2,
	})
	self.window = window

	self:BuildTitleBar(window, uiScale)
	self:BuildSidebar(window, uiScale)

	-- Content host. Apps mount into this and nothing else.
	local content = Components.frame({
		name = "Content",
		parent = window,
		size = UDim2.new(
			1, -math.round(Theme.SIDEBAR_WIDTH * uiScale),
			1, -math.round(Theme.TITLEBAR_HEIGHT * uiScale)
		),
		position = UDim2.fromOffset(
			math.round(Theme.SIDEBAR_WIDTH * uiScale),
			math.round(Theme.TITLEBAR_HEIGHT * uiScale)
		),
		color = Theme.color.base,
		clip = true,
		zIndex = 2,
	})
	self.content = content

	return gui
end

function Shell:BuildTitleBar(window: Frame, uiScale: number)
	local bar = Components.frame({
		name = "TitleBar",
		parent = window,
		size = UDim2.new(1, 0, 0, math.round(Theme.TITLEBAR_HEIGHT * uiScale)),
		color = Theme.color.surface,
		zIndex = 4,
	})

	Components.padding(bar, { left = Theme.space.lg, right = Theme.space.md }, uiScale)

	-- Hairline under the bar instead of a border, so the corners stay clean.
	local underline = Components.frame({
		name = "Underline",
		parent = window,
		size = UDim2.new(1, 0, 0, 1),
		position = UDim2.fromOffset(0, math.round(Theme.TITLEBAR_HEIGHT * uiScale)),
		color = Theme.color.border,
		zIndex = 5,
	})
	underline.Name = "TitleBarUnderline"

	--[[
		Three dots, left. Reads as a window control cluster without imitating a
		specific operating system. Only the first is wired up (close).
	]]
	local dots = Components.frame({
		name = "Dots",
		parent = bar,
		size = UDim2.new(0, math.round(52 * uiScale), 1, 0),
		zIndex = 5,
	})
	Components.list(dots, {
		direction = Enum.FillDirection.Horizontal,
		padding = Theme.space.sm,
		verticalAlign = Enum.VerticalAlignment.Center,
		scale = uiScale,
	})

	for index, colour in ipairs({
		Color3.fromRGB(96, 70, 70),
		Theme.color.border,
		Theme.color.border,
	}) do
		local dot = Components.frame({
			name = "Dot" .. index,
			parent = dots,
			size = UDim2.fromOffset(math.round(10 * uiScale), math.round(10 * uiScale)),
			color = colour,
			radius = Theme.radius.pill,
			layoutOrder = index,
			zIndex = 5,
		})
		if index == 1 then
			local hit = Instance.new("TextButton")
			hit.Name = "CloseHit"
			hit.BackgroundTransparency = 1
			hit.Text = ""
			hit.Size = UDim2.fromScale(1, 1)
			hit.ZIndex = 6
			hit.Parent = dot
			hit.MouseButton1Click:Connect(function()
				self:Close()
			end)
		end
	end

	-- Centre: the brand name, which is the window's title.
	self.titleLabel = Components.text({
		parent = bar,
		name = "Title",
		text = "",
		variant = "small",
		color = Theme.color.textSecondary,
		size = UDim2.new(0.5, 0, 1, 0),
		position = UDim2.fromScale(0.25, 0),
		align = Enum.TextXAlignment.Center,
		scale = uiScale,
		zIndex = 5,
		truncate = true,
	})

	-- Right: balance, then an escape hint.
	local right = Components.frame({
		name = "Right",
		parent = bar,
		size = UDim2.new(0, math.round(260 * uiScale), 1, 0),
		position = UDim2.new(1, -math.round(260 * uiScale), 0, 0),
		zIndex = 5,
	})
	Components.list(right, {
		direction = Enum.FillDirection.Horizontal,
		padding = Theme.space.md,
		horizontalAlign = Enum.HorizontalAlignment.Right,
		verticalAlign = Enum.VerticalAlignment.Center,
		scale = uiScale,
	})

	--[[
		The balance is deliberately typographic and small -- the brief rules out
		giant currency counters. It sits in the chrome as a fact, not a reward.
	]]
	self.balanceLabel = Components.text({
		parent = right,
		name = "Balance",
		text = "",
		variant = "bodyStrong",
		color = Theme.color.textPrimary,
		size = UDim2.new(0, math.round(110 * uiScale), 1, 0),
		align = Enum.TextXAlignment.Right,
		data = true,
		layoutOrder = 1,
		scale = uiScale,
		zIndex = 5,
	})

	Components.text({
		parent = right,
		name = "EscapeHint",
		-- Q, not Escape: Escape is reserved by Roblox's CoreGUI menu and never
		-- reaches game code. See the note in OSController.
		text = "Q to step away",
		variant = "micro",
		color = Theme.color.textTertiary,
		size = UDim2.new(0, math.round(118 * uiScale), 1, 0),
		align = Enum.TextXAlignment.Right,
		layoutOrder = 2,
		scale = uiScale,
		zIndex = 5,
	})
end

function Shell:BuildSidebar(window: Frame, uiScale: number)
	local sidebar = Components.frame({
		name = "Sidebar",
		parent = window,
		size = UDim2.new(
			0, math.round(Theme.SIDEBAR_WIDTH * uiScale),
			1, -math.round(Theme.TITLEBAR_HEIGHT * uiScale)
		),
		position = UDim2.fromOffset(0, math.round(Theme.TITLEBAR_HEIGHT * uiScale)),
		color = Theme.color.surface,
		zIndex = 3,
	})

	Components.divider(sidebar, { vertical = true }).Position =
		UDim2.new(1, -1, 0, 0)

	Components.padding(sidebar, {
		top = Theme.space.lg,
		left = Theme.space.md,
		right = Theme.space.md,
		bottom = Theme.space.lg,
	}, uiScale)

	local nav = Components.frame({
		name = "Nav",
		parent = sidebar,
		size = UDim2.fromScale(1, 1),
		zIndex = 3,
	})
	Components.list(nav, { padding = Theme.space.xs, scale = uiScale })
	self.nav = nav

	-- Build a nav entry per declared app, ordered by APP_META.order.
	local ordered = {}
	for appId, meta in pairs(APP_META) do
		table.insert(ordered, { id = appId, meta = meta })
	end
	table.sort(ordered, function(a, b)
		return a.meta.order < b.meta.order
	end)

	for _, entry in ipairs(ordered) do
		self.navButtons[entry.id] = self:BuildNavButton(nav, entry.id, entry.meta, uiScale)
	end
end

function Shell:BuildNavButton(parent: Instance, appId: string, meta: any, uiScale: number)
	local tile = Components.tile({
		name = "Nav_" .. appId,
		parent = parent,
		size = UDim2.new(1, 0, 0, math.round(52 * uiScale)),
		layoutOrder = meta.order,
		transparentBackground = true,
		onClick = function()
			self:Navigate(appId)
		end,
	})

	Components.padding(tile.content, { left = Theme.space.md, right = Theme.space.sm }, uiScale)

	local icon = Components.text({
		parent = tile.content,
		name = "Icon",
		text = meta.icon,
		variant = "heading",
		color = Theme.color.textSecondary,
		size = UDim2.new(0, math.round(24 * uiScale), 1, 0),
		align = Enum.TextXAlignment.Left,
		scale = uiScale,
	})

	local title = Components.text({
		parent = tile.content,
		name = "Title",
		text = meta.title,
		variant = "bodyStrong",
		color = Theme.color.textPrimary,
		size = UDim2.new(1, -math.round(30 * uiScale), 0, math.round(18 * uiScale)),
		position = UDim2.fromOffset(math.round(30 * uiScale), math.round(9 * uiScale)),
		scale = uiScale,
	})

	local subtitle = Components.text({
		parent = tile.content,
		name = "Subtitle",
		text = meta.subtitle,
		variant = "micro",
		color = Theme.color.textTertiary,
		size = UDim2.new(1, -math.round(30 * uiScale), 0, math.round(14 * uiScale)),
		position = UDim2.fromOffset(math.round(30 * uiScale), math.round(27 * uiScale)),
		scale = uiScale,
	})

	return {
		tile = tile,
		icon = icon,
		title = title,
		subtitle = subtitle,
		available = true,
	}
end

-- ============================================================================
-- Navigation
-- ============================================================================

function Shell:Navigate(appId: string, params: any?)
	local entry = self.navButtons[appId]
	if entry and not entry.available then
		return
	end

	local app = self.apps[appId]
	if not app then
		return
	end

	if self.currentAppId == appId and self.currentHandle then
		-- Re-navigating to the live app is a refresh, not a remount.
		if self.currentHandle.onParams and params then
			self.currentHandle.onParams(params)
		end
		return
	end

	-- Tear the previous app down completely. Apps own their connections, so a
	-- destroyed app must leave nothing behind.
	if self.currentHandle and self.currentHandle.destroy then
		local ok, err = pcall(self.currentHandle.destroy)
		if not ok then
			warn("[Shell] app destroy failed: " .. tostring(err))
		end
	end
	self.currentHandle = nil
	self.content:ClearAllChildren()

	self.currentAppId = appId
	self:UpdateNavSelection()

	local container = Components.frame({
		name = "App_" .. appId,
		parent = self.content,
		size = UDim2.fromScale(1, 1),
		zIndex = 2,
	})

	local ok, handle = pcall(app.mount, container, self:Context(params))
	if not ok then
		warn("[Shell] app " .. appId .. " failed to mount: " .. tostring(handle))
		Components.emptyState({
			parent = container,
			title = "This app failed to open",
			body = "Something went wrong. Step away and try again.",
			scale = self.scale,
		})
		return
	end

	self.currentHandle = handle

	-- Push the current state into the freshly mounted app immediately, so it
	-- never renders an empty frame waiting for the next update.
	local state = self.controllers.state:Get()
	if state and handle and handle.onStateChanged then
		pcall(handle.onStateChanged, state)
	end

	-- A short fade on content change. Enough to register, not enough to wait for.
	container.BackgroundTransparency = 1
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			descendant.Position = descendant.Position + UDim2.fromOffset(0, 6)
			TweenService:Create(descendant, Theme.tweenInfo(Theme.motion.normal), {
				Position = descendant.Position - UDim2.fromOffset(0, 6),
			}):Play()
			break -- only nudge the outermost child; cheaper and reads the same
		end
	end
end

function Shell:UpdateNavSelection()
	for appId, entry in pairs(self.navButtons) do
		local selected = appId == self.currentAppId
		entry.tile.setSelected(selected)
		entry.icon.TextColor3 = if selected then Theme.color.accent else Theme.color.textTertiary
		entry.title.TextColor3 = if selected then Theme.color.textPrimary else Theme.color.textSecondary
	end
end

-- ============================================================================
-- State
-- ============================================================================

function Shell:OnStateChanged(state: any)
	if not self.gui then
		return
	end

	-- Title and balance.
	local identity = state.identity
	if self.titleLabel then
		self.titleLabel.Text = if identity.created
			then string.upper(identity.name)
			else "UNNAMED"
	end
	if self.balanceLabel then
		self.balanceLabel.Text = Format.money(state.finances.cashPence)
	end

	--[[
		Sidebar availability comes from the server's projection. A locked app is
		shown dimmed with its requirement, rather than hidden -- seeing what is
		coming is better than a dock that silently grows.
	]]
	for appId, entry in pairs(self.navButtons) do
		local available = state.availableApps[appId] == true
		entry.available = available
		entry.tile.setEnabled(available)

		if not available then
			local requirement = Progression.getAppRequirement(appId)
			entry.subtitle.Text = requirement and requirement.lockedHint or "Locked"
			entry.subtitle.TextColor3 = Theme.color.textTertiary
			entry.icon.TextColor3 = Theme.color.textTertiary
		else
			entry.subtitle.Text = APP_META[appId].subtitle
		end
	end

	self:UpdateNavSelection()

	-- Forward to the live app.
	if self.currentHandle and self.currentHandle.onStateChanged then
		local ok, err = pcall(self.currentHandle.onStateChanged, state)
		if not ok then
			warn("[Shell] app state update failed: " .. tostring(err))
		end
	end

	-- If the mounted app just became unavailable (a dev reset, say), fall back.
	if self.currentAppId and state.availableApps[self.currentAppId] == false then
		self:Navigate("brand")
	end
end

--[[
	The AppContext.

	This is the entire surface an app is given. It deliberately does NOT include
	the shell, the ScreenGui, or any sibling app, so an app cannot reach outside
	its container.
]]
function Shell:Context(params: any?): any
	return {
		scale = self.scale,
		params = params,

		getState = function()
			return self.controllers.state:Get()
		end,

		navigate = function(appId: string, navParams: any?)
			self:Navigate(appId, navParams)
		end,

		notify = function(notification: any)
			self.controllers.notifications:Push(notification)
		end,

		close = function()
			self:Close()
		end,

		-- Style accent for brand-owned surfaces only; the chrome never changes.
		accent = function()
			local state = self.controllers.state:Get()
			local style = state and Styles.get(state.identity.styleId)
			return style and style.accent or Theme.color.accent
		end,
	}
end

-- ============================================================================
-- Open / close
-- ============================================================================

function Shell:Open(initialAppId: string?)
	if self.open or not self.gui then
		return
	end
	self.open = true

	local gui = self.gui :: ScreenGui
	gui.Enabled = true

	-- Start slightly small and transparent, settle into place. Short enough that
	-- it reads as the screen waking rather than an animation to sit through.
	local window = self.window
	local targetSize = window.Size
	window.Size = UDim2.fromOffset(
		math.round(targetSize.X.Offset * 0.97),
		math.round(targetSize.Y.Offset * 0.97)
	)
	window.BackgroundTransparency = 1

	TweenService:Create(self.scrim, Theme.tweenInfo(Theme.motion.normal), {
		BackgroundTransparency = 0.45,
	}):Play()
	TweenService:Create(window, Theme.tweenInfo(Theme.motion.normal), {
		Size = targetSize,
		BackgroundTransparency = 0,
	}):Play()

	local state = self.controllers.state:Get()
	if state then
		self:OnStateChanged(state)
	end

	-- Choose a landing app the player can actually use.
	local appId = initialAppId
	if appId == "desktop" or appId == nil then
		appId = if state and state.availableApps.design then "design" else "brand"
	end
	self:Navigate(appId)
end

function Shell:Close()
	if not self.open or not self.gui then
		return
	end
	self.open = false

	local gui = self.gui :: ScreenGui

	TweenService:Create(self.scrim, Theme.tweenInfo(Theme.motion.fast), {
		BackgroundTransparency = 1,
	}):Play()

	local fade = TweenService:Create(self.window, Theme.tweenInfo(Theme.motion.fast), {
		BackgroundTransparency = 1,
	})
	fade:Play()
	fade.Completed:Once(function()
		if not self.open then
			gui.Enabled = false
		end
	end)

	if self.onClosed then
		self.onClosed()
	end
end

function Shell:IsOpen(): boolean
	return self.open
end

Shell.APP_META = APP_META

return Shell
