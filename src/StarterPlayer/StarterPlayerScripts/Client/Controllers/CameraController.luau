--!strict
--[[
	CameraController

	Moves the camera between free play and a focused view of an object.

	== Why the camera moves at all ==

	The brief asks that using the laptop feel like the character is actually
	using it, and that the bedroom stay the primary space. A full-screen UI with
	a static camera would read as a menu pasted over a game. Leaning the camera
	in toward the desk, with the room still visible behind a partial dim, keeps
	the interface diegetic.

	The focus CFrame is derived from the target's own orientation, so the camera
	frames whatever it is given without per-object tuning.
]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Timings = require(Shared.Config.Timings)

local CameraController = {}
CameraController.__index = CameraController

function CameraController.new()
	local self = setmetatable({}, CameraController)
	self.focused = false
	self.savedCFrame = nil :: CFrame?
	self.savedType = nil :: Enum.CameraType?
	self.savedFov = nil :: number?
	self.activeTween = nil :: Tween?
	return self
end

function CameraController:Init() end
function CameraController:Start() end

local function camera(): Camera
	return workspace.CurrentCamera
end

--[[
	Frames `target` from the front.

	`distance` is measured along the target's own look vector, and `height` lifts
	the camera so it looks slightly down -- a head-height view of a desk object
	rather than a flat-on orthographic one.
]]
function CameraController:FocusOn(target: BasePart, options: {
	distance: number?,
	height: number?,
	pitch: number?,
	fov: number?,
	duration: number?,
}?)
	local cam = camera()
	local settings = options or {}

	if not self.focused then
		-- Remember exactly where we came from so Release restores it.
		self.savedCFrame = cam.CFrame
		self.savedType = cam.CameraType
		self.savedFov = cam.FieldOfView
		self.focused = true
	end

	cam.CameraType = Enum.CameraType.Scriptable

	local distance = settings.distance or 4.2
	local height = settings.height or 1.3
	local pitch = settings.pitch or -14

	--[[
		The laptop screen faces the chair, which is on its +Z side in local
		space. Offsetting along the target's own axes means this works for any
		orientation without hardcoding world directions.
	]]
	local basis = target.CFrame
	local position = basis * CFrame.new(0, height, distance)
	local lookAt = basis.Position + Vector3.new(0, height * 0.35, 0)

	local goal = CFrame.lookAt(position.Position, lookAt) * CFrame.Angles(math.rad(pitch), 0, 0)

	if self.activeTween then
		self.activeTween:Cancel()
	end

	local tween = TweenService:Create(
		cam,
		TweenInfo.new(
			settings.duration or Timings.cameraBlendSeconds,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{ CFrame = goal, FieldOfView = settings.fov or 55 }
	)
	self.activeTween = tween
	tween:Play()
end

function CameraController:Release(duration: number?)
	if not self.focused then
		return
	end

	local cam = camera()
	local player = Players.LocalPlayer

	if self.activeTween then
		self.activeTween:Cancel()
		self.activeTween = nil
	end

	--[[
		Returning to Custom instantly would snap the view. Instead, tween back to
		roughly where the player camera will resume, then hand control back once
		the motion finishes.
	]]
	local restoreCFrame = self.savedCFrame
	local restoreFov = self.savedFov or 70

	if restoreCFrame then
		local tween = TweenService:Create(
			cam,
			TweenInfo.new(
				duration or Timings.cameraBlendSeconds,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			),
			{ CFrame = restoreCFrame, FieldOfView = restoreFov }
		)
		tween:Play()
		tween.Completed:Once(function()
			cam.CameraType = self.savedType or Enum.CameraType.Custom
			cam.FieldOfView = restoreFov
			if player.Character then
				cam.CameraSubject = player.Character:FindFirstChildOfClass("Humanoid")
			end
		end)
	else
		cam.CameraType = Enum.CameraType.Custom
	end

	self.focused = false
	self.savedCFrame = nil
	self.savedType = nil
	self.savedFov = nil
end

function CameraController:IsFocused(): boolean
	return self.focused
end

return CameraController
