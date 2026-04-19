## bullen-vehiclekeys

🔑 Best VehicleKeys for QB-Core Framework 🔑

## Features
- owned vehicle key system
- vehicle lock / unlock
- shared keys between players
- locksmith key copy system
- lockpicking
- hotwiring
- carjacking
- vehicle alarm support
- fake plate support
- key item metadata support
- configurable minigame support
- configurable inventory / target compatibility



### Dependencies:
- [qb-core](https://pages.github.com/](https://github.com/qbcore-framework/qb-core))<br>
- [oxmysql](https://github.com/overextended/oxmysql)<br>
- [ox_lib](https://github.com/overextended/ox_lib)

### Supported/Configurable:
- [ox_inventory](https://github.com/overextended/ox_inventory) or [qb-inventory](https://github.com/qbcore-framework/qb-inventory)<br>
- [ox_target](https://github.com/overextended/ox_target) or [qb-target](https://github.com/qbcore-framework/qb-target)<br>

### Optional minigames
- [Burevestnik](https://github.com/Burevestnikdev/Burevestnik_lockpick_minigame_FiveM/tree/main)<br>
- [lockpick](https://github.com/havenstadrp/qb-lockpick)<br>
- [ox_lib skillcheck](https://github.com/overextended/ox_lib)

### Installation
- Delete qb-vehiclekeys
- Place bullen_vehiclekeys in your server resources folder.
- Import the included SQL file into your database.
- Open config.lua and set the correct options for your server

### Items for ox_inventory
<details>
    <summary>Expand</summary>
```['vehicle_key'] = {
    label = 'Vehicle Key',
    weight = 50,
    stack = false,
    close = true,
    description = 'A key for a specific vehicle'
},

['blank_key'] = {
    label = 'Blank Key',
    weight = 50,
    stack = true,
    close = true,
    description = 'A blank vehicle key ready to be cut'
},

['lockpick'] = {
    label = 'Lockpick',
    weight = 100,
    stack = true,
    close = true,
    description = 'Useful for opening locked vehicles'
},

['fakeplate'] = {
    label = 'Fake Plate',
    weight = 200,
    stack = true,
    close = true,
    description = 'A fake vehicle plate'
},

['platekit'] = {
    label = 'Plate Kit',
    weight = 300,
    stack = true,
    close = true,
    description = 'Tools and parts for fitting a plate'
},

['screwdriver'] = {
    label = 'Screwdriver',
    weight = 150,
    stack = true,
    close = true,
    description = 'Useful for vehicle work'
},```
