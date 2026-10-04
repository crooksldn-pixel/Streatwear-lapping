--!strict
--[[
	NotificationController

	Transient messages: a sample shipped, a parcel arrived, an order failed.

	== Deliberately not popups ==

	The brief rules out constant popups. These are small, corner-anchored cards
	that never block input, never require dismissal, and never interrupt what the
	player is doing. They slide in, sit, and leave.

	A hard cap on simultaneous cards means a burst of events cannot cover the
	screen; the oldest is retired early instead.
]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Timings = require(Shared.Config.Timings)

local UI = script.Parent.Parent.UI
local Theme = require(UI.Theme)
local Components = require(UI.Components)

local NotificationController = {}
NotificationController.__index = NotificationController

local MAX_VISIBLE = 3
local CARD_WIDTH = 320

function NotificationController.new()
	local self = setmetatable({}, NotificationController)
	self.cards = {} :: { Frame }
	self.scale = 1
	return self
end

function NotificationController:Init()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	self.scale = Theme.scale(workspace.CurrentCamera.ViewportSize)

	local gui = Instance.new("ScreenGui")
	gui.Name = "Notifications"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Above the OS window, so a parcel arriving while the laptop is open is seen.
	gui.DisplayOrder = 20
	gui.Parent = playerGui
	self.gui = gui

	local container = Components.frame({
		name = "Stack",
		parent = gui,
		size = UDim2.new(0, math.round(CARD_WIDTH * self.scale), 1, -math.round(80 * self.scale)),
		position = UDim2.new(1, -math.round((CARD_WIDTH + 24) * self.scale), 0, math.round(60 * self.scale)),
	})
	Components.list(container, {
		padding = Theme.space.sm,
		verticalAlign = Enum.VerticalAlignment.Top,
		scale = self.scale,
	})
	self.container = container
end

function NotificationController:Start() end

export type Notification = {
	title: string,
	body: string?,
	kind: string?, -- "info" | "positive" | "warning" | "critical"
	duration: number?,
}

local KIND_COLORS = {
	info = Theme.color.info,
	positive = Theme.color.positive,
	warning = Theme.color.warning,
	critical = Theme.color.critical,
}

function NotificationController:Push(notification: Notification)
	if not self.container then
		return
	end

	local uiScale = self.scale
	local accent = KIND_COLORS[notification.kind or "info"] or Theme.color.info

	-- Retire the oldest if the stack is full.
	while #self.cards >= MAX_VISIBLE do
		local oldest = table.remove(self.cards, 1)
		if oldest then
			self:Dismiss(oldest)
		end
	end

	local card = Components.frame({
		name = "Notification",
		parent = self.container,
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.color.surfaceRaised,
		radius = Theme.radius.lg,
		stroke = Theme.color.border,
		automaticSize = Enum.AutomaticSize.Y,
		layoutOrder = os.clock() * 1000 // 1,
	})

	Components.padding(card, {
		top = Theme.space.md,
		bottom = Theme.space.md,
		left = Theme.space.lg,
		right = Theme.space.md,
	}, uiScale)
	Components.list(card, { padding = Theme.space.xs, scale = uiScale })

	-- A coloured rule down the left edge carries the severity. Colour as
	-- information, not decoration.
	local accentBar = Components.frame({
		name = "Accent",
		parent = card,
		size = UDim2.new(0, math.round(2 * uiScale), 1, 0),
		color = accent,
		zIndex = 2,
	})
	accentBar.Position = UDim2.fromOffset(0, 0)

	Components.text({
		parent = card,
		text = notification.title,
		variant = "bodyStrong",
		color = Theme.color.textPrimary,
		size = UDim2.new(1, 0, 0, math.round(18 * uiScale)),
		layoutOrder = 1,
		scale = uiScale,
		truncate = true,
	})

	if notification.body then
		Components.text({
			parent = card,
			text = notification.body,
			variant = "small",
			color = Theme.color.textSecondary,
			size = UDim2.new(1, 0, 0, 0),
			automaticSize = Enum.AutomaticSize.Y,
			wrap = true,
			layoutOrder = 2,
			scale = uiScale,
		})
	end

	table.insert(self.cards, card)

	-- Slide in from the right.
	card.Position = UDim2.fromOffset(math.round(40 * uiScale), 0)
	card.BackgroundTransparency = 1
	TweenService:Create(card, Theme.tweenInfo(Theme.motion.normal), {
		Position = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 0,
	}):Play()

	task.delay(notification.duration or Timings.notificationDwellSeconds, function()
		local index = table.find(self.cards, card)
		if index then
			table.remove(self.cards, index)
		end
		self:Dismiss(card)
	end)
end

function NotificationController:Dismiss(card: Frame)
	if not card or not card.Parent then
		return
	end

	local tween = TweenService:Create(card, Theme.tweenInfo(Theme.motion.fast), {
		Position = UDim2.fromOffset(math.round(40 * self.scale), 0),
		BackgroundTransparency = 1,
	})
	tween:Play()
	tween.Completed:Once(function()
		if card then
			card:Destroy()
		end
	end)
end

-- Shorthand used by apps when a remote call fails.
function NotificationController:PushError(response: any)
	self:Push({
		title = "That did not work",
		body = response and response.message or "Try again in a moment.",
		kind = "critical",
	})
end

return NotificationController
