--!strict
--[[
	InteractionController

	Turns tagged world objects into usable prompts, and routes the server's
	directives to the right part of the client.

	== Why ProximityPrompt ==

	It brings keyboard, gamepad and touch together with hold-to-activate,
	occlusion handling and automatic range checks. Writing three input paths by
	hand would be strictly worse, and the brief asks for mobile and controller
	support to be considered up front.

	The prompts are styled `Custom` so the visuals are ours rather than Roblox's
	default chrome.

	== Prompts grant nothing ==

	A prompt is a trigger and nothing more. Every activation goes to the server,
	which re-resolves the object in its own registry and re-checks distance and
	ownership. A player who edits or fabricates a prompt locally achieves
	nothing, which is why it is safe to build them from replicated attributes.
]]

local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net.Net)
local Logger = require(Shared.Util.Logger)

local UI = script.Parent.Parent.UI
local Theme = require(UI.Theme)
local Components = require(UI.Components)

local log = Logger.scope("Interact")

local InteractionController = {}
InteractionController.__index = InteractionController

local TAG = "Interactable"

function InteractionController.new(controllers: any)
	local self = setmetatable({}, InteractionController)
	self.controllers = controllers
	self.prompts = {} :: { [Instance]: ProximityPrompt }
	self.busy = false
	self.scale = 1
	return self
end

function InteractionController:Init()
	self.scale = Theme.scale(workspace.CurrentCamera.ViewportSize)

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	-- Host for custom prompt visuals.
	local gui = Instance.new("ScreenGui")
	gui.Name = "InteractionPrompts"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 5
	gui.Parent = playerGui
	self.gui = gui
end

function InteractionController:Start()
	for _, instance in ipairs(CollectionService:GetTagged(TAG)) do
		self:Attach(instance)
	end

	CollectionService:GetInstanceAddedSignal(TAG):Connect(function(instance)
		self:Attach(instance)
	end)

	CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(instance)
		self:Detach(instance)
	end)
end

-- ============================================================================
-- Prompt construction
-- ============================================================================

--[[
	Finds the part a prompt should hang on. ProximityPrompt must be parented to
	a BasePart or an Attachment, so a Model needs a representative part.
]]
local function promptHost(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

function InteractionController:Attach(instance: Instance)
	if self.prompts[instance] then
		return
	end

	local host = promptHost(instance)
	if not host then
		log:warn("no part to host a prompt on %s", instance:GetFullName())
		return
	end

	local name = instance:GetAttribute("InteractionName")
	local kind = instance:GetAttribute("InteractionKind")
	if type(name) ~= "string" or type(kind) ~= "string" then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Prompt"
	prompt.ObjectText = tostring(instance:GetAttribute("InteractionPrompt") or "")
	prompt.ActionText = tostring(instance:GetAttribute("InteractionAction") or "Use")
	prompt.HoldDuration = tonumber(instance:GetAttribute("InteractionHold")) or 0
	prompt.MaxActivationDistance = tonumber(instance:GetAttribute("InteractionDistance")) or 10
	prompt.RequiresLineOfSight = false
	-- Touch and mouse support without a separate code path.
	prompt.ClickablePrompt = true
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	-- Our own visuals rather than Roblox's default chrome.
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Parent = host

	self.prompts[instance] = prompt
	self:BuildPromptUI(prompt, instance)

	prompt.Triggered:Connect(function()
		self:Trigger(name, kind)
	end)
end

function InteractionController:Detach(instance: Instance)
	local prompt = self.prompts[instance]
	if prompt then
		prompt:Destroy()
		self.prompts[instance] = nil
	end
end

--[[
	Custom prompt visual: a small dark pill with the key, the object name and the
	action. Matches the OS typography so the world and the interface feel like
	one product.
]]
function InteractionController:BuildPromptUI(prompt: ProximityPrompt, instance: Instance)
	local uiScale = self.scale

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "PromptUI"
	billboard.Size = UDim2.fromOffset(math.round(190 * uiScale), math.round(44 * uiScale))
	billboard.StudsOffset = Vector3.new(0, 1.6, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = prompt.MaxActivationDistance + 6
	billboard.Enabled = false
	billboard.Parent = self.gui
	billboard.Adornee = prompt.Parent

	local pill = Components.frame({
		name = "Pill",
		parent = billboard,
		size = UDim2.fromScale(1, 1),
		color = Theme.color.void,
		transparency = 0.12,
		radius = Theme.radius.lg,
		stroke = Theme.color.borderStrong,
	})
	Components.padding(pill, { left = Theme.space.sm, right = Theme.space.md }, uiScale)

	-- Key cap.
	local keyCap = Components.frame({
		name = "Key",
		parent = pill,
		size = UDim2.fromOffset(math.round(24 * uiScale), math.round(24 * uiScale)),
		position = UDim2.new(0, 0, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		color = Theme.color.surfaceRaised,
		radius = Theme.radius.sm,
		stroke = Theme.color.borderStrong,
	})

	local keyLabel = Components.text({
		parent = keyCap,
		name = "KeyLabel",
		text = "E",
		variant = "micro",
		color = Theme.color.textPrimary,
		size = UDim2.fromScale(1, 1),
		align = Enum.TextXAlignment.Center,
		scale = uiScale,
	})

	-- Hold progress ring, drawn as a fill under the key cap.
	local holdFill = Components.frame({
		name = "HoldFill",
		parent = keyCap,
		size = UDim2.fromScale(0, 1),
		color = Theme.color.accent,
		transparency = 0.6,
		radius = Theme.radius.sm,
	})
	holdFill.ZIndex = 0

	local objectText = tostring(instance:GetAttribute("InteractionPrompt") or "")
	local actionText = tostring(instance:GetAttribute("InteractionAction") or "Use")

	Components.text({
		parent = pill,
		name = "Object",
		text = objectText,
		variant = "micro",
		color = Theme.color.textTertiary,
		size = UDim2.new(1, -math.round(34 * uiScale), 0, math.round(13 * uiScale)),
		position = UDim2.fromOffset(math.round(34 * uiScale), math.round(8 * uiScale)),
		scale = uiScale,
		truncate = true,
	})

	Components.text({
		parent = pill,
		name = "Action",
		text = actionText,
		variant = "small",
		color = Theme.color.textPrimary,
		size = UDim2.new(1, -math.round(34 * uiScale), 0, math.round(16 * uiScale)),
		position = UDim2.fromOffset(math.round(34 * uiScale), math.round(21 * uiScale)),
		scale = uiScale,
		truncate = true,
	})

	-- Fade in and out with range.
	prompt.PromptShown:Connect(function()
		billboard.Enabled = true
		pill.BackgroundTransparency = 1
		TweenService:Create(pill, Theme.tweenInfo(Theme.motion.fast), {
			BackgroundTransparency = 0.12,
		}):Play()
	end)

	prompt.PromptHidden:Connect(function()
		billboard.Enabled = false
	end)

	-- Hold feedback.
	prompt.PromptButtonHoldBegan:Connect(function()
		TweenService:Create(holdFill, TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear), {
			Size = UDim2.fromScale(1, 1),
		}):Play()
	end)

	prompt.PromptButtonHoldEnded:Connect(function()
		TweenService:Create(holdFill, Theme.tweenInfo(Theme.motion.fast), {
			Size = UDim2.fromScale(0, 1),
		}):Play()
	end)

	prompt.Triggered:Connect(function()
		holdFill.Size = UDim2.fromScale(0, 1)
	end)

	-- Clean up the billboard when the object goes away.
	prompt.Destroying:Once(function()
		if billboard then
			billboard:Destroy()
		end
	end)
end

-- ============================================================================
-- Dispatch
-- ============================================================================

--[[
	Sends the interaction and carries out whatever the server returns.

	`busy` prevents a second request while one is in flight -- without it, a
	player mashing E on a parcel could fire several opens before the first
	response lands.
]]
function InteractionController:Trigger(targetName: string, kind: string)
	if self.busy then
		return
	end
	self.busy = true

	task.spawn(function()
		local response = Net.invoke("Interact", { targetName = targetName, kind = kind })
		self.busy = false

		if not response.ok then
			-- "Too far" is normal play, not an error worth a card.
			if response.error ~= "TooFar" then
				self.controllers.notifications:Push({
					title = response.message or "That did not work",
					kind = "warning",
				})
			end
			return
		end

		self:HandleDirective(response.data)
	end)
end

--[[
	The client obeys; it never decides. Each directive maps to exactly one
	controller, which is what keeps world interaction decoupled from the UI.
]]
function InteractionController:HandleDirective(directive: any)
	if type(directive) ~= "table" or type(directive.action) ~= "string" then
		return
	end

	local payload = directive.payload or {}

	if directive.action == "OpenOS" then
		self.controllers.os:Open(payload.initialApp)
	elseif directive.action == "OpenParcel" then
		self.controllers.parcel:PlayOpening(payload.orderId)
	elseif directive.action == "InspectGarment" then
		self.controllers.inspection:Open(payload.orderId)
	elseif directive.action == "Message" then
		self.controllers.notifications:Push({
			title = tostring(payload.text or ""),
			kind = "info",
		})
	else
		log:warn("unknown directive %q", tostring(directive.action))
	end
end

-- Suppresses prompts while a full-screen interface is open, so E does not fire
-- a world interaction behind the laptop.
function InteractionController:SetPromptsEnabled(enabled: boolean)
	for _, prompt in pairs(self.prompts) do
		if prompt.Parent then
			prompt.Enabled = enabled
		end
	end
end

return InteractionController
