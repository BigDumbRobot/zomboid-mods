# Asset tools

These scripts build the 3D head stake's assets. They sit outside `Contents/`, so they are never uploaded. They use plain Python 3 with no packages. `png.py` and `tiles.py` are the helpers the others share.

In the commands below, `$G` is the game's media folder:

```sh
G="$HOME/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents/Java/media"
```

| Script | Builds |
|---|---|
| `gen_mannequins.py` | `scripts/Whisperers_Mannequins.txt`: one mannequin per vanilla skin. Keep it in step with `S.Skins` in `Whisperers_Stake.lua`. |
| `set_stake_tiles.py` | Properties in `whisperers_headstake.tiles`. Tile `_0` is the mannequin tile (`CustomName` must be exactly `Mannequin`). Tiles `_1` to `_3` are the old flat stakes. Every tile is `solidtrans`, so people and cars can't pass. |
| `stick.py` | `models_X/Skinned/Clothes/Whisp_StakeStick_M.x` and `_F.x`: the stick, weighted to the pelvis and neck. `python3 tools/stick.py "$G/models_X/Skinned/MaleBody.x" <out>` |
| `faceless.py` | `textures/Body/Whisp_FacelessOverlay.png`: flayed flesh over the face. `python3 tools/faceless.py "$G/textures/Body/" <out.png> [preview dir]` |
| `mask.py` | `models_X/Skinned/Clothes/Whisp_FaceMask_M.x` and `_F.x`: the body's own face triangles (brow to chin), pushed out slightly and weighted to the head, so any body skin fits. `python3 tools/mask.py "$G/models_X/Skinned/MaleBody.x" <out>` |
| `mask_textures.py` | `textures/WhispMask/<skin>.png`: each vanilla skin's face stretched, sagging and mutilated (dead pallor on human skins, hollow eyes, cuts, blood, raw stitched edge); each skin gets its own fixed wounds. `python3 tools/mask_textures.py "$G/textures/Body/" [preview dir]` |
| `gen_face_mask_xml.py` | `clothing/clothingItems/Whisp_FaceMask.xml`: the mask model with every vanilla skin as a texture choice, in the order of `S.MaskSkins` |
| `bounds.py`, `pose.py` | Measurements used to size the stick and pick the mannequin poses. |

Each generator reproduces the file currently in the mod byte for byte (checked 2026-09-25).
