fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'bullen'
description 'Production vehicle keys, locksmith, alarm, lockpick, and hotwire resource for QBCore / ox_lib servers.'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

ui_page 'html/index.html'

files {
    'locales/*.json',
    'html/index.html',
    'html/sounds/*.ogg'
}

client_scripts {
    'client/main.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

dependencies {
    'ox_lib',
    'qb-core',
    'oxmysql'
}
