--!strict
--[[
	OSController

	Owns the laptop session: camera, input, movement lock, screen glow, and the
	Shell's lifecycle.

	The Shell draws the interface. This controller decides when the player is
	"sitting at the laptop" and manages everything that implies:

		* camera leans in toward the screen, room still visible behind
		* character movement is frozen (they are sitting down)
		* world prompts are suppressed, so E does not fire a world interaction
		  through the interface
		* the physical laptop screen lights up, so the room reflects what the
		  player is doing
		* Escape steps away

	Every one of those is undone on close, including on respawn, so a player who
	dies at the desk does not wake up frozen with a dark screen.
]]

local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Timings = require(Shared.Config.Timings)

local UI = script.Parent.Parent.UI
local Theme = require(UI.Theme)
local Shell = require(UI.Shell)

local OSController = {}
OSController.__index = OSController

-- See the note in Start(): Escape is reserved by CoreGUI and unusable.
OSController.CLOSE_KEY = Enum.KeyCode.Q

-- Walk speed is restored to whatever it was, not to a constant, so this cannot
-- quietly reset a player buffed elsewhere later.
local LAPTOP_SCREEN_ON = Color3.fromRGB(26, 28, 34)
local LAPTOP_SCREEN_OFF = Color3.fromRGB(16, 17, 20)

function OSController.new(controllers: any)
	local self = setmetatable({}, OSController)
	self.controllers = controllers
	self.shell = Shell.new(controllers)
	self.savedWalkSpeed = nil :: number?
	self.savedJumpPower = nil :: number?
	return self
end

function OSController:Init()
	self.shell:Build()

	self.shell.onClosed = function()
		self:OnShellClosed()
	end
end

function OSController:Start()
	-- Mirror server state into the shell.
	self.controllers.state.changed:connect(function(state)
		self.shell:OnStateChanged(state)
	end)

	--[[
		Q steps away from the desk -- NOT Escape.

		Escape is permanently bound to Roblox's CoreGUI menu. It never reaches a
		game script as unprocessed input, so an Escape handler here would simply
		never fire while also opening the Roblox menu over the interface. Verified
		in play: the input layer refuses to deliver the key at all.

		Q is unbound by default and sits under the hand already on WASD.
	]]
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == OSController.CLOSE_KEY and self.shell:IsOpen() then
			self.shell:Close()
		end
	end)

	--[[
		If the character respawns while the laptop is open, the saved walk speed
		belongs to a Humanoid that no longer exists. Closing on respawn is the
		safe, predictable behaviour.
	]]
	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(function()
		if self.shell:IsOpen() then
			self.shell:Close()
		else
			-- Clear any state left over from a character that died mid-session.
			self.savedWalkSpeed = nil
			self.savedJumpPower = nil
		end
	end)
end

-- ============================================================================
-- Session
-- ============================================================================

function OSController:Open(initialAppId: string?)
	if self.shell:IsOpen() then
		return
	end

	self:LockCharacter()
	self.controllers.interactions:SetPromptsEnabled(false)
	self:SetScreenLit(true)
	self:FocusCamera()

	self.shell:Open(initialAppId)
end

function OSController:Close()
	self.shell:Close()
end

-- Everything the Open path changed is undone here, in one place.
function OSController:OnShellClosed()
	self.controllers.camera:Release()
	self.controllers.interactions:SetPromptsEnabled(true)
	self:SetScreenLit(false)
	self:UnlockCharacter()
end

-- ============================================================================
-- Character
-- ============================================================================

local function humanoid(): Humanoid?
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

function OSController:LockCharacter()
	local human = humanoid()
	if not human then
		return
	end

	-- Record the real values rather than assuming defaults.
	self.savedWalkSpeed = human.WalkSpeed
	self.savedJumpPower = human.UseJumpPower and human.JumpPower or human.JumpHeight

	human.WalkSpeed = 0
	if human.UseJumpPower then
		human.JumpPower = 0
	else
		human.JumpHeight = 0
	end
end

function OSController:UnlockCharacter()
	local human = humanoid()
	if not human then
		return
	end

	if self.savedWalkSpeed then
		human.WalkSpeed = self.savedWalkSpeed
		self.savedWalkSpeed = nil
	end
	if self.savedJumpPower then
		if human.UseJumpPower then
			human.JumpPower = self.savedJumpPower
		else
			human.JumpHeight = self.savedJumpPower
		end
		self.savedJumpPower = nil
	end
end

-- ============================================================================
-- World feedback
-- ============================================================================

function OSController:LaptopScreen(): BasePart?
	local bedroom = workspace:FindFirstChild("Bedroom")
	if not bedroom then
		return nil
	end
	local screen = bedroom:FindFirstChild("LaptopScreen", true)
	return screen and screen:IsA("BasePart") and screen or nil
end

--[[
	Lights the physical laptop screen in the room.

	Small touch, but it is what connects the interface to the object: the player
	sees their own screen glow in the bedroom rather than a UI appearing from
	nowhere.
]]
function OSController:SetScreenLit(lit: boolean)
	local screen = self:LaptopScreen()
	if not screen then
		return
	end

	TweenService:Create(screen, Theme.tweenInfo(Theme.motion.slow), {
		Color = if lit then LAPTOP_SCREEN_ON else LAPTOP_SCREEN_OFF,
	}):Play()

	local glow = screen:FindFirstChild("ScreenGlow") :: PointLight?
	if lit then
		if not glow then
			glow = Instance.new("PointLight")
			glow.Name = "ScreenGlow"
			glow.Color = Color3.fromRGB(150, 180, 230)
			glow.Range = 9
			glow.Brightness = 0
			glow.Parent = screen
		end
		TweenService:Create(glow :: PointLight, Theme.tweenInfo(Theme.motion.slow), {
			Brightness = 1.1,
		}):Play()
	elseif glow then
		local fade = TweenService:Create(glow, Theme.tweenInfo(Theme.motion.normal), { Brightness = 0 })
		fade:Play()
		fade.Completed:Once(function()
			if glow and glow.Parent then
				glow:Destroy()
			end
		end)
	end
end

function OSController:FocusCamera()
	local screen = self:LaptopScreen()
	if not screen then
		return
	end

	-- Close enough to read, far enough that the desk and window stay in frame.
	self.controllers.camera:FocusOn(screen, {
		distance = 3.6,
		height = 0.9,
		pitch = -8,
		fov = 52,
		duration = Timings.cameraBlendSeconds,
	})
end

function OSController:RegisterApp(id: string, app: any)
	self.shell:RegisterApp(id, app)
end

function OSController:IsOpen(): boolean
	return self.shell:IsOpen()
end

return OSController
