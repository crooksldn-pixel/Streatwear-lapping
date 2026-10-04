--!strict
--[[
	BedroomBuilder

	Builds the starting bedroom as SAVED Workspace geometry.

	This is run once from Studio (not at runtime) so the room becomes part of the
	place file: editable by hand like any normal build, costing nothing at
	startup. The builder is kept in source so the room can be regenerated or
	tweaked systematically, and so the layout is reviewable as code.

	== Scale ==

	A Roblox character is roughly 5 studs tall, so 1 stud is about 0.35m.
	Everything here is sized from that:

		room      18 x 16 studs  ~ 6.3m x 5.6m   a believable bedroom
		ceiling   9 studs        ~ 3.1m          tall enough for the camera
		desk      2.2 studs high ~ 0.77m         correct desk height
		bed       6.2 x 3.2      ~ 2.2m x 1.1m   a single bed

	Keeping these honest is what stops the room reading as a Roblox box.

	== Named markers ==

	WorldService looks up parts by name. The names here are the contract:
	Laptop, DeliveryPoint, Bed, Moodboard, SpawnPoint.
]]

local BedroomBuilder = {}

BedroomBuilder.ROOT_NAME = "Bedroom"

-- ---------------------------------------------------------------- dimensions
local ROOM_WIDTH = 18
local ROOM_DEPTH = 16
local WALL_HEIGHT = 9
local WALL_THICKNESS = 0.6
local FLOOR_THICKNESS = 0.6

-- ---------------------------------------------------------------- palette
-- Muted, warm-neutral. A young designer's room, not a showroom.
local PALETTE = {
	floor = Color3.fromRGB(122, 98, 76),
	rug = Color3.fromRGB(58, 60, 64),
	wall = Color3.fromRGB(216, 212, 203),
	wallAccent = Color3.fromRGB(74, 76, 82),
	ceiling = Color3.fromRGB(236, 234, 229),
	skirting = Color3.fromRGB(238, 236, 231),
	deskTop = Color3.fromRGB(196, 168, 132),
	deskLeg = Color3.fromRGB(46, 47, 50),
	bedFrame = Color3.fromRGB(74, 58, 44),
	bedding = Color3.fromRGB(196, 192, 182),
	pillow = Color3.fromRGB(232, 229, 222),
	duvet = Color3.fromRGB(86, 92, 86),
	laptopBody = Color3.fromRGB(78, 80, 86),
	laptopScreen = Color3.fromRGB(16, 17, 20),
	chair = Color3.fromRGB(52, 54, 58),
	shelf = Color3.fromRGB(188, 160, 126),
	cork = Color3.fromRGB(188, 152, 106),
	metal = Color3.fromRGB(142, 146, 152),
	door = Color3.fromRGB(228, 226, 220),
	box = Color3.fromRGB(176, 148, 112),
}

-- ---------------------------------------------------------------- helpers

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for key, value in pairs(props) do
		(p :: any)[key] = value
	end
	return p
end

local function group(name: string, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	return model
end

-- ============================================================================
-- Sections
-- ============================================================================

local function buildShell(root: Model)
	local shell = group("Shell", root)

	local floor = part({
		Name = "Floor",
		Size = Vector3.new(ROOM_WIDTH, FLOOR_THICKNESS, ROOM_DEPTH),
		CFrame = CFrame.new(0, -FLOOR_THICKNESS / 2, 0),
		Color = PALETTE.floor,
		Material = Enum.Material.WoodPlanks,
	})
	floor.Parent = shell

	local ceiling = part({
		Name = "Ceiling",
		Size = Vector3.new(ROOM_WIDTH, 0.5, ROOM_DEPTH),
		CFrame = CFrame.new(0, WALL_HEIGHT + 0.25, 0),
		Color = PALETTE.ceiling,
		Material = Enum.Material.Plaster,
	})
	ceiling.Parent = shell

	local halfW, halfD = ROOM_WIDTH / 2, ROOM_DEPTH / 2

	-- West wall (solid) -- the bed goes against this.
	part({
		Name = "WallWest",
		Size = Vector3.new(WALL_THICKNESS, WALL_HEIGHT, ROOM_DEPTH),
		CFrame = CFrame.new(-halfW, WALL_HEIGHT / 2, 0),
		Color = PALETTE.wall,
		Material = Enum.Material.Plaster,
	}).Parent = shell

	-- East wall, painted darker: the "working" wall the moodboard hangs on.
	part({
		Name = "WallEast",
		Size = Vector3.new(WALL_THICKNESS, WALL_HEIGHT, ROOM_DEPTH),
		CFrame = CFrame.new(halfW, WALL_HEIGHT / 2, 0),
		Color = PALETTE.wallAccent,
		Material = Enum.Material.Plaster,
	}).Parent = shell

	--[[
		North wall, built in four pieces around a window opening. A window is
		what stops an interior reading as a sealed box -- it gives the room
		daylight, a sense of outside, and a reason for the desk to be where it is.
	]]
	local windowWidth, windowHeight = 7, 4.2
	local windowSill = 3.4
	local sideWidth = (ROOM_WIDTH - windowWidth) / 2

	for _, side in ipairs({ -1, 1 }) do
		part({
			Name = "WallNorth" .. (side < 0 and "Left" or "Right"),
			Size = Vector3.new(sideWidth, WALL_HEIGHT, WALL_THICKNESS),
			CFrame = CFrame.new(side * (windowWidth / 2 + sideWidth / 2), WALL_HEIGHT / 2, -halfD),
			Color = PALETTE.wall,
			Material = Enum.Material.Plaster,
		}).Parent = shell
	end

	part({
		Name = "WallNorthUnderWindow",
		Size = Vector3.new(windowWidth, windowSill, WALL_THICKNESS),
		CFrame = CFrame.new(0, windowSill / 2, -halfD),
		Color = PALETTE.wall,
		Material = Enum.Material.Plaster,
	}).Parent = shell

	part({
		Name = "WallNorthAboveWindow",
		Size = Vector3.new(windowWidth, WALL_HEIGHT - windowSill - windowHeight, WALL_THICKNESS),
		CFrame = CFrame.new(0, windowSill + windowHeight + (WALL_HEIGHT - windowSill - windowHeight) / 2, -halfD),
		Color = PALETTE.wall,
		Material = Enum.Material.Plaster,
	}).Parent = shell

	-- Glazing + frame.
	local glass = part({
		Name = "WindowGlass",
		Size = Vector3.new(windowWidth - 0.3, windowHeight - 0.3, 0.14),
		CFrame = CFrame.new(0, windowSill + windowHeight / 2, -halfD),
		Color = Color3.fromRGB(214, 228, 238),
		Material = Enum.Material.Glass,
		Transparency = 0.72,
		Reflectance = 0.1,
		CanCollide = true,
	})
	glass.Parent = shell

	for _, spec in ipairs({
		{ Vector3.new(windowWidth, 0.26, 0.4), Vector3.new(0, windowSill, -halfD) },
		{ Vector3.new(windowWidth, 0.26, 0.4), Vector3.new(0, windowSill + windowHeight, -halfD) },
		{ Vector3.new(0.26, windowHeight, 0.4), Vector3.new(-windowWidth / 2, windowSill + windowHeight / 2, -halfD) },
		{ Vector3.new(0.26, windowHeight, 0.4), Vector3.new(windowWidth / 2, windowSill + windowHeight / 2, -halfD) },
		-- Centre mullion.
		{ Vector3.new(0.18, windowHeight, 0.34), Vector3.new(0, windowSill + windowHeight / 2, -halfD) },
	}) do
		part({
			Name = "WindowFrame",
			Size = spec[1],
			CFrame = CFrame.new(spec[2]),
			Color = PALETTE.skirting,
			Material = Enum.Material.Wood,
			CanCollide = false,
		}).Parent = shell
	end

	-- Window sill ledge.
	part({
		Name = "WindowSill",
		Size = Vector3.new(windowWidth + 0.8, 0.22, 1.1),
		CFrame = CFrame.new(0, windowSill - 0.1, -halfD + 0.45),
		Color = PALETTE.skirting,
		Material = Enum.Material.Wood,
	}).Parent = shell

	--[[
		South wall with a doorway. The door is where parcels arrive, which is why
		the opening is real rather than decorative -- the player walks toward it.
	]]
	local doorWidth, doorHeight = 4, 6.4
	local southSideWidth = (ROOM_WIDTH - doorWidth) / 2

	for _, side in ipairs({ -1, 1 }) do
		part({
			Name = "WallSouth" .. (side < 0 and "Left" or "Right"),
			Size = Vector3.new(southSideWidth, WALL_HEIGHT, WALL_THICKNESS),
			CFrame = CFrame.new(side * (doorWidth / 2 + southSideWidth / 2), WALL_HEIGHT / 2, halfD),
			Color = PALETTE.wall,
			Material = Enum.Material.Plaster,
		}).Parent = shell
	end

	part({
		Name = "WallSouthAboveDoor",
		Size = Vector3.new(doorWidth, WALL_HEIGHT - doorHeight, WALL_THICKNESS),
		CFrame = CFrame.new(0, doorHeight + (WALL_HEIGHT - doorHeight) / 2, halfD),
		Color = PALETTE.wall,
		Material = Enum.Material.Plaster,
	}).Parent = shell

	-- Door, hung slightly ajar so the room reads as lived-in and the delivery
	-- point beyond it is visible.
	local door = part({
		Name = "Door",
		Size = Vector3.new(doorWidth - 0.2, doorHeight - 0.1, 0.22),
		CFrame = CFrame.new(doorWidth / 2 - 0.1, (doorHeight - 0.1) / 2, halfD)
			* CFrame.Angles(0, math.rad(-28), 0)
			* CFrame.new(-(doorWidth - 0.2) / 2, 0, 0),
		Color = PALETTE.door,
		Material = Enum.Material.Wood,
	})
	door.Parent = shell

	part({
		Name = "DoorHandle",
		Size = Vector3.new(0.5, 0.16, 0.16),
		CFrame = door.CFrame * CFrame.new(-(doorWidth - 0.2) / 2 + 0.6, 0, 0.2),
		Color = PALETTE.metal,
		Material = Enum.Material.Metal,
		CanCollide = false,
	}).Parent = shell

	-- Skirting board around the floor edge. A small detail that does a lot of
	-- work in making an interior feel built rather than extruded.
	local skirtingHeight = 0.55
	for _, spec in ipairs({
		{ Vector3.new(ROOM_WIDTH, skirtingHeight, 0.2), Vector3.new(0, skirtingHeight / 2, -halfD + 0.4) },
		{ Vector3.new(0.2, skirtingHeight, ROOM_DEPTH), Vector3.new(-halfW + 0.4, skirtingHeight / 2, 0) },
		{ Vector3.new(0.2, skirtingHeight, ROOM_DEPTH), Vector3.new(halfW - 0.4, skirtingHeight / 2, 0) },
	}) do
		part({
			Name = "Skirting",
			Size = spec[1],
			CFrame = CFrame.new(spec[2]),
			Color = PALETTE.skirting,
			Material = Enum.Material.Wood,
			CanCollide = false,
		}).Parent = shell
	end
end

local function buildDesk(root: Model)
	local desk = group("Desk", root)
	local deskHeight = 2.2
	local deskZ = -ROOM_DEPTH / 2 + 1.9

	local top = part({
		Name = "DeskTop",
		Size = Vector3.new(7.4, 0.22, 3),
		CFrame = CFrame.new(0, deskHeight, deskZ),
		Color = PALETTE.deskTop,
		Material = Enum.Material.Wood,
	})
	top.Parent = desk

	-- Hairpin-style legs.
	for _, offset in ipairs({
		Vector3.new(-3.4, 0, -1.2), Vector3.new(3.4, 0, -1.2),
		Vector3.new(-3.4, 0, 1.2), Vector3.new(3.4, 0, 1.2),
	}) do
		part({
			Name = "DeskLeg",
			Size = Vector3.new(0.14, deskHeight, 0.14),
			CFrame = CFrame.new(offset.X, deskHeight / 2, deskZ + offset.Z),
			Color = PALETTE.deskLeg,
			Material = Enum.Material.Metal,
		}).Parent = desk
	end

	-- ---- laptop ----
	-- Named "Laptop": WorldService binds the interaction to this part.
	local laptopBase = part({
		Name = "Laptop",
		Size = Vector3.new(2.6, 0.14, 1.8),
		CFrame = CFrame.new(-0.4, deskHeight + 0.18, deskZ + 0.1),
		Color = PALETTE.laptopBody,
		Material = Enum.Material.Metal,
		CanCollide = false,
	})
	laptopBase.Parent = desk

	-- Keyboard deck.
	part({
		Name = "LaptopKeys",
		Size = Vector3.new(2.2, 0.03, 1.2),
		CFrame = laptopBase.CFrame * CFrame.new(0, 0.09, 0.15),
		Color = Color3.fromRGB(38, 39, 43),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
	}).Parent = desk

	-- Lid, tilted open.
	local lid = part({
		Name = "LaptopLid",
		Size = Vector3.new(2.6, 1.7, 0.1),
		CFrame = laptopBase.CFrame
			* CFrame.new(0, 0, -0.85)
			* CFrame.Angles(math.rad(-15), 0, 0)
			* CFrame.new(0, 0.85, 0),
		Color = PALETTE.laptopBody,
		Material = Enum.Material.Metal,
		CanCollide = false,
	})
	lid.Parent = desk

	-- Screen face. The client lights this up while the OS is open.
	local screen = part({
		Name = "LaptopScreen",
		Size = Vector3.new(2.36, 1.48, 0.04),
		CFrame = lid.CFrame * CFrame.new(0, 0, 0.07),
		Color = PALETTE.laptopScreen,
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
	})
	screen.Parent = desk

	-- Desk clutter: a mug, a sketchbook, a fabric swatch stack.
	part({
		Name = "Mug",
		Size = Vector3.new(0.52, 0.62, 0.52),
		CFrame = CFrame.new(2.5, deskHeight + 0.42, deskZ + 0.6),
		Color = Color3.fromRGB(226, 223, 214),
		Material = Enum.Material.Ceramic,
		Shape = Enum.PartType.Cylinder,
		CanCollide = false,
	}).Parent = desk

	local sketchbook = part({
		Name = "Sketchbook",
		Size = Vector3.new(1.7, 0.12, 2.2),
		CFrame = CFrame.new(-3.1, deskHeight + 0.17, deskZ + 0.3) * CFrame.Angles(0, math.rad(12), 0),
		Color = Color3.fromRGB(62, 62, 66),
		Material = Enum.Material.Fabric,
		CanCollide = false,
	})
	sketchbook.Parent = desk

	-- Stack of fabric swatches.
	for index, swatchColour in ipairs({
		Color3.fromRGB(42, 44, 48),
		Color3.fromRGB(198, 178, 148),
		Color3.fromRGB(138, 146, 122),
	}) do
		part({
			Name = "Swatch",
			Size = Vector3.new(1.1, 0.06, 1.1),
			CFrame = CFrame.new(3.0, deskHeight + 0.14 + index * 0.07, deskZ - 0.7)
				* CFrame.Angles(0, math.rad(index * 9), 0),
			Color = swatchColour,
			Material = Enum.Material.Fabric,
			CanCollide = false,
		}).Parent = desk
	end

	-- ---- chair ----
	local chair = group("Chair", root)
	local seatHeight = 1.5
	local chairZ = deskZ + 3.2

	part({
		Name = "Seat",
		Size = Vector3.new(2, 0.26, 2),
		CFrame = CFrame.new(-0.4, seatHeight, chairZ),
		Color = PALETTE.chair,
		Material = Enum.Material.Fabric,
	}).Parent = chair

	part({
		Name = "ChairBack",
		Size = Vector3.new(2, 2.4, 0.2),
		CFrame = CFrame.new(-0.4, seatHeight + 1.2, chairZ + 0.9) * CFrame.Angles(math.rad(-8), 0, 0),
		Color = PALETTE.chair,
		Material = Enum.Material.Fabric,
	}).Parent = chair

	part({
		Name = "ChairStem",
		Size = Vector3.new(0.26, seatHeight, 0.26),
		CFrame = CFrame.new(-0.4, seatHeight / 2, chairZ),
		Color = PALETTE.deskLeg,
		Material = Enum.Material.Metal,
		CanCollide = false,
	}).Parent = chair

	for index = 1, 5 do
		local angle = (index / 5) * math.pi * 2
		part({
			Name = "ChairFoot",
			Size = Vector3.new(1.1, 0.12, 0.16),
			CFrame = CFrame.new(-0.4, 0.12, chairZ)
				* CFrame.Angles(0, angle, 0)
				* CFrame.new(0.55, 0, 0),
			Color = PALETTE.deskLeg,
			Material = Enum.Material.Metal,
			CanCollide = false,
		}).Parent = chair
	end
end

local function buildBed(root: Model)
	local bed = group("BedArea", root)
	local bedX = -ROOM_WIDTH / 2 + 2.6
	local bedZ = 2.2

	-- Named "Bed": WorldService binds an interaction to this part.
	local frame = part({
		Name = "Bed",
		Size = Vector3.new(3.4, 1.1, 6.6),
		CFrame = CFrame.new(bedX, 0.55, bedZ),
		Color = PALETTE.bedFrame,
		Material = Enum.Material.Wood,
	})
	frame.Parent = bed

	part({
		Name = "Mattress",
		Size = Vector3.new(3.2, 0.7, 6.4),
		CFrame = CFrame.new(bedX, 1.45, bedZ),
		Color = PALETTE.bedding,
		Material = Enum.Material.Fabric,
	}).Parent = bed

	-- Duvet, pulled back rather than neatly made.
	part({
		Name = "Duvet",
		Size = Vector3.new(3.3, 0.42, 4.2),
		CFrame = CFrame.new(bedX, 1.95, bedZ + 1),
		Color = PALETTE.duvet,
		Material = Enum.Material.Fabric,
		CanCollide = false,
	}).Parent = bed

	part({
		Name = "Pillow",
		Size = Vector3.new(2.6, 0.46, 1.3),
		CFrame = CFrame.new(bedX, 2, bedZ - 2.5) * CFrame.Angles(math.rad(-6), 0, 0),
		Color = PALETTE.pillow,
		Material = Enum.Material.Fabric,
		CanCollide = false,
	}).Parent = bed

	part({
		Name = "Headboard",
		Size = Vector3.new(3.4, 2.4, 0.26),
		CFrame = CFrame.new(bedX, 1.9, bedZ - 3.3),
		Color = PALETTE.bedFrame,
		Material = Enum.Material.Wood,
	}).Parent = bed

	-- Rug between bed and desk.
	part({
		Name = "Rug",
		Size = Vector3.new(6, 0.06, 5),
		CFrame = CFrame.new(1.6, 0.03, 3.2),
		Color = PALETTE.rug,
		Material = Enum.Material.Fabric,
		CanCollide = false,
	}).Parent = bed
end

local function buildStorage(root: Model)
	local storage = group("Storage", root)
	local shelfX = ROOM_WIDTH / 2 - 1.2

	-- Open shelving against the accent wall.
	for index, height in ipairs({ 2.1, 4.1, 6.1 }) do
		part({
			Name = "Shelf" .. index,
			Size = Vector3.new(1.9, 0.18, 6),
			CFrame = CFrame.new(shelfX, height, -2),
			Color = PALETTE.shelf,
			Material = Enum.Material.Wood,
		}).Parent = storage
	end

	for _, zPosition in ipairs({ -5, 1 }) do
		part({
			Name = "ShelfUpright",
			Size = Vector3.new(1.9, 6.2, 0.16),
			CFrame = CFrame.new(shelfX, 3.1, zPosition),
			Color = PALETTE.shelf,
			Material = Enum.Material.Wood,
		}).Parent = storage
	end

	-- Folded tees and stock boxes on the shelves.
	local folded = {
		{ y = 2.4, z = -4.0, colour = Color3.fromRGB(28, 28, 30) },
		{ y = 2.7, z = -4.0, colour = Color3.fromRGB(226, 220, 206) },
		{ y = 4.4, z = -0.4, colour = Color3.fromRGB(69, 70, 74) },
		{ y = 4.7, z = -0.4, colour = Color3.fromRGB(138, 146, 122) },
	}
	for _, entry in ipairs(folded) do
		part({
			Name = "FoldedTee",
			Size = Vector3.new(1.5, 0.28, 1.5),
			CFrame = CFrame.new(shelfX, entry.y, entry.z),
			Color = entry.colour,
			Material = Enum.Material.Fabric,
			CanCollide = false,
		}).Parent = storage
	end

	for _, entry in ipairs({ { y = 2.45, z = -0.2 }, { y = 6.45, z = -3.6 } }) do
		part({
			Name = "StorageBox",
			Size = Vector3.new(1.6, 0.9, 1.8),
			CFrame = CFrame.new(shelfX, entry.y, entry.z),
			Color = PALETTE.box,
			Material = Enum.Material.Cardboard,
			CanCollide = false,
		}).Parent = storage
	end

	--[[
		Moodboard: a cork panel on the accent wall, deliberately EMPTY.
		It is wall space reserved for pinned designs, swatches and references
		once that system exists. Present now so the room already has a place for
		it rather than needing to be rearranged later.
	]]
	local board = part({
		Name = "Moodboard",
		Size = Vector3.new(0.2, 4.4, 6.4),
		CFrame = CFrame.new(ROOM_WIDTH / 2 - 0.4, 5, 4.4),
		Color = PALETTE.cork,
		Material = Enum.Material.Fabric,
		CanCollide = false,
	})
	board.Parent = storage

	part({
		Name = "MoodboardFrame",
		Size = Vector3.new(0.14, 4.8, 6.8),
		CFrame = CFrame.new(ROOM_WIDTH / 2 - 0.46, 5, 4.4),
		Color = Color3.fromRGB(52, 52, 56),
		Material = Enum.Material.Wood,
		CanCollide = false,
	}).Parent = storage

	-- Clothing rail in the corner, with a couple of hanging blanks.
	local railZ = 6.2
	part({
		Name = "RailBar",
		Size = Vector3.new(4.6, 0.12, 0.12),
		CFrame = CFrame.new(-2.2, 6, railZ),
		Color = PALETTE.metal,
		Material = Enum.Material.Metal,
		CanCollide = false,
	}).Parent = storage

	for _, side in ipairs({ -4.4, 0 }) do
		part({
			Name = "RailPost",
			Size = Vector3.new(0.12, 6, 0.12),
			CFrame = CFrame.new(-2.2 + side + 2.2, 3, railZ),
			Color = PALETTE.metal,
			Material = Enum.Material.Metal,
			CanCollide = false,
		}).Parent = storage
	end

	for index, colour in ipairs({
		Color3.fromRGB(24, 24, 26),
		Color3.fromRGB(242, 241, 237),
		Color3.fromRGB(154, 153, 150),
	}) do
		part({
			Name = "HangingBlank",
			Size = Vector3.new(1.9, 2.6, 0.18),
			CFrame = CFrame.new(-3.8 + index * 1.1, 4.5, railZ),
			Color = colour,
			Material = Enum.Material.Fabric,
			CanCollide = false,
		}).Parent = storage
	end
end

local function buildMarkers(root: Model)
	local markers = group("Markers", root)

	--[[
		DeliveryPoint -- where parcels land, just inside the door.
		Invisible and non-collidable: it is a position, not an object. Parcels
		are placed on top of it by DeliveryService.
	]]
	local delivery = part({
		Name = "DeliveryPoint",
		Size = Vector3.new(3, 0.2, 3),
		CFrame = CFrame.new(0.4, 0.1, ROOM_DEPTH / 2 - 2.6),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
	delivery.Parent = markers

	-- Doormat, so the delivery spot reads as meaningful before anything arrives.
	part({
		Name = "Doormat",
		Size = Vector3.new(3.4, 0.08, 2),
		CFrame = CFrame.new(0.4, 0.04, ROOM_DEPTH / 2 - 2.2),
		Color = Color3.fromRGB(86, 76, 62),
		Material = Enum.Material.Fabric,
		CanCollide = false,
	}).Parent = markers

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SpawnPoint"
	spawn.Size = Vector3.new(4, 0.2, 4)
	spawn.CFrame = CFrame.new(2, 0.1, 4.6)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Parent = markers
end

local function buildLighting(root: Model)
	local lighting = group("Lighting", root)

	-- Ceiling pendant.
	part({
		Name = "PendantCord",
		Size = Vector3.new(0.08, 1.6, 0.08),
		CFrame = CFrame.new(0, WALL_HEIGHT - 0.8, 1),
		Color = Color3.fromRGB(40, 40, 44),
		CanCollide = false,
	}).Parent = lighting

	local shade = part({
		Name = "PendantShade",
		Size = Vector3.new(1.8, 0.9, 1.8),
		CFrame = CFrame.new(0, WALL_HEIGHT - 1.9, 1),
		Color = Color3.fromRGB(240, 238, 232),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
	})
	shade.Parent = lighting

	local roomLight = Instance.new("PointLight")
	roomLight.Name = "RoomLight"
	roomLight.Brightness = 1.4
	roomLight.Range = 28
	roomLight.Color = Color3.fromRGB(255, 244, 224)
	roomLight.Shadows = true
	roomLight.Parent = shade

	--[[
		Desk lamp pointed at the work surface. A second, warmer, tighter light
		is what makes the desk read as the focus of the room rather than it
		being uniformly lit.
	]]
	local lampBase = part({
		Name = "LampBase",
		Size = Vector3.new(0.7, 0.12, 0.7),
		CFrame = CFrame.new(3.3, 2.38, -ROOM_DEPTH / 2 + 1.4),
		Color = Color3.fromRGB(44, 45, 48),
		Material = Enum.Material.Metal,
		CanCollide = false,
	})
	lampBase.Parent = lighting

	part({
		Name = "LampArm",
		Size = Vector3.new(0.1, 2.2, 0.1),
		CFrame = lampBase.CFrame * CFrame.new(0, 1.1, 0) * CFrame.Angles(math.rad(14), 0, 0),
		Color = Color3.fromRGB(44, 45, 48),
		Material = Enum.Material.Metal,
		CanCollide = false,
	}).Parent = lighting

	local lampHead = part({
		Name = "LampHead",
		Size = Vector3.new(0.8, 0.5, 0.8),
		CFrame = lampBase.CFrame * CFrame.new(0, 2.2, -0.5) * CFrame.Angles(math.rad(42), 0, 0),
		Color = Color3.fromRGB(44, 45, 48),
		Material = Enum.Material.Metal,
		CanCollide = false,
	})
	lampHead.Parent = lighting

	local deskLight = Instance.new("SpotLight")
	deskLight.Name = "DeskLight"
	deskLight.Brightness = 2.6
	deskLight.Range = 16
	deskLight.Angle = 78
	deskLight.Color = Color3.fromRGB(255, 238, 210)
	deskLight.Face = Enum.NormalId.Bottom
	deskLight.Shadows = true
	deskLight.Parent = lampHead
end

-- ============================================================================
-- Entry point
-- ============================================================================

function BedroomBuilder.build(parent: Instance?): Model
	local target = parent or workspace

	-- Idempotent: rebuilding replaces the previous room entirely.
	local existing = target:FindFirstChild(BedroomBuilder.ROOT_NAME)
	if existing then
		existing:Destroy()
	end

	local root = Instance.new("Model")
	root.Name = BedroomBuilder.ROOT_NAME

	buildShell(root)
	buildDesk(root)
	buildBed(root)
	buildStorage(root)
	buildMarkers(root)
	buildLighting(root)

	root.Parent = target

	-- Lock the shell so it cannot be nudged by accident while editing.
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end

	return root
end

BedroomBuilder.ROOM_WIDTH = ROOM_WIDTH
BedroomBuilder.ROOM_DEPTH = ROOM_DEPTH
BedroomBuilder.WALL_HEIGHT = WALL_HEIGHT

return BedroomBuilder
