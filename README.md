# molo_soundemitters

In-game menu to add sound and decorate an MLO without CodeWalker. It shows which interior you're in (name, room, portals, placed elements), and you place GTA sounds, ambient loops, radios and any game object by aiming.

Standalone (no framework required).

## Install

1. Drop the `molo_soundemitters` folder into `resources/`.
2. In `server.cfg`: `ensure molo_soundemitters`
   To export into an MLO resource, FiveM requires a permission per MLO (a resource can't write into another one otherwise):
   `add_filesystem_permission molo_soundemitters write molo_asyleum`
3. In-game: **F7** or `/soundemitter`. No permission setup needed (see `Config.UseAce` if you want to restrict it later).

## The menu

- **MLO**: rooms (room tone, reverb), door sounds and audio occlusion of the MLO you're in, exported natively.
- **Interior**: where you are. That's either a vanilla name (385 interiors recognised) or the name you give your MLO. Also shows the hash, ID, current room, room list, portals, and everything placed inside.
- **Sounds**: ~3,770 positional sounds in categories, MLO ambience first: Room tones, HVAC & machinery, Electrical & tech (neon, hums, computers), Appliances (fridge, vending machine, TV…), Crowd & walla, Music, Water, Fire, Alarms & bells, Doors & elevators, Construction, Weather & creaks, Animals… Menu/HUD (2D) sounds are not included.
- **Emitters**: 713 vanilla static emitters (club/bar/restaurant music, TVs, alarms, crowds), relocated onto your point.
- **Radios / Objects / Mute**: radio stations, the 21,631 game props, and zones that mute a vanilla emitter.
- **Placed**: everything you placed, filterable by group or by current interior. Click to edit, TP.
- **Export**: active group + export to ship with an MLO.

Pick something, click **Place it**: the menu closes and you aim. **Aim ↩** (or Esc) goes back to aiming, **TAB** reopens the menu, **Exit** closes everything.

## Keys while aiming

| Key | Action |
|---|---|
| **E** | Place / confirm a move |
| **Q** | Preview the selection at the aimed point |
| **Wheel** | Hearing range |
| **Shift + wheel** | Raise / lower the point |
| **← →** | Rotate the object |
| **G** | Move the aimed element |
| **H** | Edit the aimed element |
| **X** (×2) | Delete the aimed element |
| **TAB** | Reopen the menu |
| **Backspace** | Cancel a move / exit |

Colours: blue = sound, teal = vanilla emitter, orange = radio, green = vanilla zone, purple = object, grey = disabled.

## Sound check (removes sounds you can't hear)

The ambience library comes from GTA's own sound name tables (`sounds.dat54`): room tones, fridges, AC units, neon hums, fountains, walla… Some of them need an audio bank that isn't loaded, so they don't play.

The first time you open **Sounds**, click **Check all sounds**. The check plays every sound for a split second, keeps the ones that actually start, and removes the others. It takes about a minute: stand still and lower your volume. The result is saved in `data/sound_check.json` and shared with everyone. You can also re-check a single category.

If a sound plays but you can't hear anything useful, click **✕** on its row to hide it. **Show removed** lets you bring sounds back.

## What you can place

- **Sound**: repeats in a loop when it ends, with an optional random pause (e.g. a bark every 20-60 s). Custom refs supported.
- **Vanilla emitter**: a vanilla static emitter moved onto your point. Its original location goes silent while in use, and each one can only be placed once. Custom names work too, including your own dat151 emitters.
- **Radio**: any of the 86 stations, including hidden ones (club, casino, TV). A vanilla emitter from a pool of 207 is reserved and moved to your point.
- **Object**: any game model or a prop from your MLO, on its own or as the visible source of a sound, ambient emitter or radio.
- **Vanilla zone**: while the player is in range, a vanilla emitter is muted (or turned on / set to a station), then restored.

Common options: name, group, range, visible object, **same interior only** (no sound leaking outside), time window (handles midnight, e.g. 22 → 6).

## Export into the MLO resource

**Export** → choose the group and **the MLO's resource** (preselected when it has the same name as the group). FiveM only lets a resource write into another one with a permission in `server.cfg`:

```
add_filesystem_permission molo_soundemitters write molo_asyleum
```

What the export writes into the MLO resource:

| File | Contains |
|---|---|
| `audio/molo_se_<group>_game.dat151.rel` | rooms (room tone, reverb) and door sounds, native |
| `stream/<interior proxy hash>.ymt` | audio occlusion, native |
| `audio/molo_se_<group>_game.dat151.rel` (same file) | placed sounds (no soundset), radios and TV / music emitters, as native StaticEmitters in `ambient_emitter_list_NN` |
| `audio/molo_se_<group>_player.lua` | only if needed: small generated client script for what can't be native (soundset sounds, random pauses, alarms, mute zones, objects) |

GTA only loads emitter lists named `ambient_emitter_list_NN` (vanilla uses 01 to 03), so the export names the list that way, with a number from 10 to 99 derived from the group name. Two MLOs must not use the same number: set it per group in `Config.EmitterListNumber` if needed. The MLO's `fxmanifest.lua` gets a marked block:

```lua
-- >>> molo_soundemitters (auto-generated, do not edit) >>>
data_file 'AUDIO_GAMEDATA' 'audio/molo_se_default_game.dat'
files { 'audio/molo_se_default_game.dat151.rel' }
client_script 'audio/molo_se_default_player.lua'
-- <<< molo_soundemitters <<<
```

Everything then works without `molo_soundemitters`. While the MLO's script runs, the editor stops playing that group so nothing plays twice. The block is re-added at every start of `molo_soundemitters` if it went missing (or run `molo_se_manifest` in the server console).

If the MLO already has its own `.dat151.rel` for the same interior, it is merged, the original goes to `audio/_molo_backup/` and its manifest line is commented out. An existing `.ymt` with the same name is backed up there too.

The game only reads audio files when you join: after an export, `refresh`, restart the MLO resource and **reconnect**.

## MLO tabs: rooms, doors, occlusion

Walk into the MLO. Three tabs read it from the game and feed the native export.

**MLO**: the ambience of each room. The room you're standing in is shown first ("You are here").
- **Room tone**: loops while you're inside. Search the library (room tone, aircon, neon, fridge, walla…) and preview with ▶.
- **Reverb**: a preset (dry, small room, medium room, large hall, warehouse).
- **Heard from outside**: how much of the room you hear from outside.
- Untick **Generate the rooms of this MLO** if it already ships its own audio dat151.

**Doors**: pick the sound of each door in a simple list: Wood, Metal, Glass, Bars / cell, Sliding (auto), Sliding bars, Elevator, Garage, Metal gate, Wooden gate, Chain-link gate, Barrier arm. A first guess is made from the model name. ▶ opens the door for 2 seconds so you can hear it.

### Occlusion tab (.ymt)

The **Occlusion** tab generates the occlusion file: sound is muffled through walls and only travels room to room through portals. It lists every portal with the entities that close it. Tick **Door** for doors (sound is blocked when shut) and **Glass** for windows, and set **Max occlusion** (0 to 1, default 1.0 = fully muffled when shut). **All to 1.0** resets every entity.

On export it is written to `stream/<interior proxy hash>.ymt` (streamed automatically, no manifest line needed). Untick it if the MLO already ships its own occlusion `.ymt`.

The paths (which portal leads where, up to 5 rooms away) are computed with ht_mlotool's algorithm. On 40 random MLOs the binary is byte-identical both to CodeWalker's conversion and to the original ht_mlotool code.

## Exports for your scripts

```lua
-- server: turn on / off for everyone (not saved), e.g. when a club opens
exports.molo_soundemitters:SetEmitterEnabled('se_123456789', true)
exports.molo_soundemitters:GetEmitters('molo_bahamas')

-- client: force locally (nil = back to server state)
exports.molo_soundemitters:SetLocalEmitterEnabled('se_123456789', false)
exports.molo_soundemitters:IsEmitterActive('se_123456789')
exports.molo_soundemitters:GetPropEntity('se_123456789')
```

## Settings (`config.lua`)

`Config.OpenKey` (F7), `Config.MaxActive` (24 active audio elements per client, closest first), `Config.PropDistance`, `Config.RotateSpeed`, `Config.TickMs`, keys, `Config.UseAce`.

## Credits

- Soundset sounds, radios, static emitters, audio banks, objects and interiors: [DurtyFree/gta-v-data-dumps](https://github.com/DurtyFree/gta-v-data-dumps) (GTA V v3717 / DLC mp2025_02).
- Ambience sound names (`sounds.dat54` nametables), door presets and DASL naming: [Monkeypolice188/Monkys-Audio-Research](https://github.com/Monkeypolice188/Monkys-Audio-Research).
- dat151 binary layout: [dexyfex/CodeWalker](https://github.com/dexyfex/CodeWalker) (`RelFile.cs`).
- MLO rooms / portals / InteriorRoom defaults and the occlusion path algorithm adapted from [Hedgehog-Technologies/ht_mlotool](https://github.com/Hedgehog-Technologies/ht_mlotool) (LGPL-3.0); the path algorithm itself comes from [pedr0fontoura/gtav-audio-occlusion](https://github.com/pedr0fontoura/gtav-audio-occlusion) (MIT).
