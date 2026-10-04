# Architecture

## Filesystem ↔ DataModel

`default.project.json` maps each Roblox service to one directory under `src/`. The layout mirrors the Studio hierarchy exactly. Nothing was restructured during migration.

| Roblox service                          | Path                                       | Notes |
|-----------------------------------------|--------------------------------------------|-------|
| Workspace                               | `src/Workspace/`                           | World geometry as `.rbxm` (see below). Workspace properties in project file. |
| ReplicatedStorage                       | `src/ReplicatedStorage/`                   | `Shared/` modules, empty `Assets/` and `Remotes/` folders. |
| ReplicatedFirst                         | `src/ReplicatedFirst/`                     | Empty. |
| ServerScriptService                     | `src/ServerScriptService/`                 | `Server/` (Bootstrap, Services, Api, World). |
| ServerStorage                           | `src/ServerStorage/`                       | Empty `Templates/World` folder. |
| StarterGui                              | `src/StarterGui/`                          | Empty. All UI is built in code. |
| StarterPack                             | `src/StarterPack/`                         | Empty. |
| StarterPlayer.StarterPlayerScripts      | `src/StarterPlayer/StarterPlayerScripts/`  | `Client/` (Bootstrap, Controllers, UI). |
| StarterPlayer.StarterCharacterScripts   | `src/StarterPlayer/StarterCharacterScripts/` | Empty. |
| Lighting                                | `src/Lighting/`                            | Post-effects and Sky as `.model.json`. Lighting properties in project file. |
| SoundService                            | `src/SoundService/`                        | Empty. Properties in project file. |

File conventions (Rojo 7):

- `Name.luau` is a ModuleScript.
- `Name.server.luau` is a Script.
- `Name.client.luau` is a LocalScript.
- A directory is a Folder.
- `.gitkeep` files keep empty folders in git. Rojo ignores them.
- Service-level properties live in `$properties` in `default.project.json`. This covers Lighting, Workspace, SoundService, StarterPlayer and StarterGui.

## World representation

| File | Contents |
|------|----------|
| `src/Workspace/Bedroom.rbxm` | The authored bedroom: Shell, Desk (incl. Laptop), Chair, BedArea, Storage, Markers (DeliveryPoint, SpawnPoint), Lighting. |
| `src/Workspace/Baseplate.rbxm` | Baseplate. |
| `src/Workspace/Camera.rbxm` | Saved edit camera. |
| `src/Workspace/Terrain.rbxm` | Terrain (empty). |

The Bedroom has to be a binary model because many sibling parts share names, such as 5× `WindowFrame`, 4× `DeskLeg` and 3× `Skirting`. Rojo cannot represent same-named siblings as separate files. To edit the world, edit it in Studio and then run syncback (see README). Breaking the room into per-part files would first need unique names. That cleanup was deferred.

`WorldService` finds the parts it needs by name inside `Workspace.Bedroom`, using a manifest: Laptop and DeliveryPoint are required; Bed, Moodboard and SpawnPoint are optional. Keep those names stable.

## Runtime structure

### Server: `ServerScriptService/Server`

`Bootstrap.server.luau` first builds the remotes (`Net.build()` recreates `ReplicatedStorage.Remotes` from `Shared/Net/Protocol`). It then constructs every service with explicit constructor injection and runs `Init` on all of them, then `Start`, in this order:

`data → profiles → brand → products → quality → manufacturers → sampleOrders → interactions → world → delivery → dev → api`

- `Services/DataService`: persistence via a provider (DataStore when published, Memory while PlaceId is 0).
- `Services/ProfileService`: player session, ledger and the state projection sent to clients.
- `Services/BrandService`, `ProductService`, `QualityService`, `ManufacturerService`, `SampleOrderService`: the brand → design → supplier → sample loop.
- `Services/InteractionService` and `WorldService`: world interactions bound to the authored bedroom.
- `Services/DeliveryService`: physical parcels at `DeliveryPoint`.
- `Services/DevService`: dev commands, gated to Studio or an allow-list (`Shared/Config/Dev`).
- `Api/Handlers`: routes validated remote calls to services.
- `World/BedroomBuilder`: procedural builder used to author the bedroom. It is not called at runtime.

### Client: `StarterPlayer/StarterPlayerScripts/Client`

`Bootstrap.client.luau` waits for `ReplicatedStorage.Remotes`, then constructs and starts the controllers:

- Controllers: `StateController`, `NotificationController`, `CameraController`, `InteractionController`, `OSController` (the laptop), `ParcelController`, `InspectionController`.
- UI: `Shell` (the laptop OS), `Components`, `Theme`, and `Apps/` (`BrandApp`, `DesignApp`, `SupplierApp`).

### Shared: `ReplicatedStorage/Shared`

`Config/*` (data tables), `Net/Protocol` (the single declaration of every remote route, with schema and rate limit), `Net/Net`, `Garment/*` (garment rendering), `Util/*`, `Enums`, `Types`.

## Known migration leftovers (not yet cleaned up)

- `ServerScriptService/BedroomBuilder.luau` is an older, unreferenced copy of `Server/World/BedroomBuilder.luau`. It uses the non-existent `Enum.Material.Ceramic`. Kept for fidelity; candidate for deletion.
- `TextChatService` and other services not listed above are not managed by Rojo. They keep Roblox defaults in a built place.
- StyLua formatting has not been applied: 27 files would change. Run `stylua src` in a dedicated formatting-only commit.
