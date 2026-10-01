fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'molo_soundemitters'
author 'Molo Modding'
description 'In-game 3D sound emitter & object editor for MLOs (GTA V sounds, ambient emitters, radios, props)'
version '1.10.1'

shared_scripts {
    'config.lua',
    'shared/pool.lua',
}

client_scripts {
    'client/player.lua',
    'client/editor.lua',
}

server_scripts {
    'server/relwriter.lua',
    'server/occlusion.lua',
    'server/audioexport.lua',
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'data/sounds.json',
    'data/radios.json',
    'data/static_emitters.json',
    'data/banks.json',
    'data/objects.json',
    'data/interiors.json',
    'data/door_presets.json',
}
