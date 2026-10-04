# Streatwear larping

A Roblox streetwear-brand simulator. You start in a bedroom with a laptop, create a brand, design a garment, get quotes from suppliers, order a sample, receive it as a parcel and inspect it.

This repository is the source of truth for the place. It is a [Rojo](https://rojo.space) project. It was migrated from Studio with `rojo syncback` from the place file `Streatwear larping.rbxl`.

## Toolchain

[Rokit](https://github.com/rojo-rbx/rokit) installs the toolchain, pinned in `rokit.toml`:

| Tool     | Version |
|----------|---------|
| rojo     | 7.7.1   |
| StyLua   | 2.5.2   |
| selene   | 0.32.0  |
| luau-lsp | 1.70.1  |
| lune     | 0.10.5  |

```sh
rokit install
```

## Build the place from the repo

```sh
rojo build default.project.json -o build.rbxl
```

Open `build.rbxl` in Roblox Studio and press Play. `*.rbxl` files are gitignored because they are build outputs.

## Live sync (later)

```sh
rojo serve default.project.json
```

Then connect with the Rojo Studio plugin. Do **not** run `rojo serve` while running `rojo syncback`.

## Pulling Studio-side edits back into the repo

Use this if you edited world geometry or other non-script content in Studio:

1. Save the place to a file, e.g. `~/Downloads/Streatwear larping.rbxl`.
2. `rojo syncback default.project.json --input <file> --dry-run --list`. Review the list.
3. `rojo syncback default.project.json --input <file>`, then review `git diff`.

## Quality checks

```sh
rojo build default.project.json -o build.rbxl   # must succeed
selene generate-roblox-std                       # once, creates roblox.yml
selene src
stylua --check src
```

## Layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
