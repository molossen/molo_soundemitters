Config = {}

-- ─── Menu ───────────────────────────────────────────────────────────
Config.Command = 'soundemitter'   -- /soundemitter opens / closes the menu
Config.OpenKey = 'F7'             -- default key (each player can rebind it in FiveM Settings > Key Bindings)

-- No permissions by default: everyone can edit.
-- Set to true on a public server and add: add_ace group.admin molo.soundemitters allow
Config.UseAce = false
Config.Ace    = 'molo.soundemitters'

-- ─── Playback / streaming ────────────────────────────────────────────
Config.TickMs         = 250     -- streaming update rate (ms)
Config.MaxActive      = 24      -- max audio elements active at once per client (closest first)
Config.StreamMargin   = 5.0     -- extra distance (m) before a playing sound is cut (prevents flicker)
Config.PropDistance   = 120.0   -- spawn distance for placed objects
Config.SupportModel   = 'prop_boombox_01'  -- invisible anchor for radios / ambient emitters placed without an object

-- Export: placed sounds (without soundset), radios and vanilla radio emitters (TV, club music…) are written
-- as native StaticEmitters in the .dat151.rel, in a list named ambient_emitter_list_NN (the only names GTA loads).
-- What can't be native (soundset sounds, random pauses, alarms, mute zones, objects) goes into a small
-- generated client script (audio/molo_se_<group>_player.lua), only if there is any.
Config.NativeEmitters = true
-- Default loudness of native emitters, in dB (each element can override it: "Volume" in its settings).
-- Vanilla radio / TV emitters are +12 dB, which is what the editor plays when it moves a vanilla emitter.
Config.NativeMusicVolume = 12.0   -- radios, TV / music emitters
Config.NativeSoundVolume = 0.0    -- single sounds
-- Number of the emitter list per group (10-99). Default: derived from the group name. Two MLOs must not share one.
Config.EmitterListNumber = {
    -- molo_asyleum = 42,
}

-- ─── Editor ─────────────────────────────────────────────────────────
Config.RayDistance        = 60.0
Config.SurfaceOffset      = 0.15   -- sound point offset from the aimed surface (no object)
Config.PropSoundOffset    = 0.35   -- sound point height above a placed object
Config.EditorDrawDistance = 80.0
Config.DefaultRange       = 15.0
Config.DefaultGroup       = 'default'  -- use your MLO name, e.g. 'molo_bahamas'
Config.RotateSpeed        = 90.0       -- degrees / second with the arrow keys

-- ─── Packs shipped with MLOs (read-only) ────────────────────────────
Config.Packs = {
    -- 'packs/molo_bahamas.json',
}

-- ─── Keys while aiming (GTA control indexes) ────────────────────────
Config.Keys = {
    place   = 38,   -- E          place / confirm move
    grab    = 47,   -- G          move the aimed element
    delete  = 73,   -- X          delete the aimed element (press twice)
    edit    = 74,   -- H          edit the aimed element
    listen  = 44,   -- Q          preview the selection at the aimed point
    menu    = 37,   -- TAB        reopen the menu
    close   = 177,  -- BACKSPACE  cancel move / close
    shift   = 21,   -- SHIFT      + wheel = height instead of range
    up      = 15,   -- wheel up
    down    = 14,   -- wheel down
    rotL    = 174,  -- LEFT ARROW   rotate object
    rotR    = 175,  -- RIGHT ARROW
}
