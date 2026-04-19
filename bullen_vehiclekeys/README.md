## Overview

This resource treats vehicle access as layered state:

- **Owned access** comes from your owned vehicle table.
- **Shared access** is persistent and revokable.
- **Physical key access** comes from an item with plate metadata.
- **Temporary stolen access** is session-only and personal to the thief.
- **Global unlocked door state** is separate from all of the above.

That separation matters because a vehicle can be physically unlocked without granting real ownership or permanent key access.

## Feature list

- QBCore + ox_lib oriented architecture
- ox_target support with optional qb-target support
- ox_inventory or qb-inventory physical key item support
- metadata-based keys tied to exact plate values using your configured inventory item
- persistent shared key access
- nearby owner share / revoke commands
- locksmith NPC/service for:
  - key duplication
  - alarm installation
- alarm data stored separately from ownership data
- repeated ambient NPC vehicle lock normalization
- lockpick flow with server-side final validation
- hotwire flow with session-only stolen access grants
- armed NPC carjacking with:
  - exact-driver targeting
  - aim hold requirement
  - server-authoritative final outcome selection
  - surrender / flee / aggressive branches
- searchable robbed NPCs for real metadata keys
- optional fake plate compatibility via entity statebags
- exports for external integration

## Dependencies

Required:
- `Burevestnik_lockpick_minigame` if you want to use the Burevestnik lockpick minigame.
- `lockpick` if you want to use the external lockpick NUI minigame backend.
- `ox_lib`

Required:

- `qb-core`
- `ox_lib`
- `oxmysql`

Optional:

- `ox_target`
- `qb-target`
- `ox_inventory`
- `qb-inventory`

## Installation

1. Place the folder in your resources directory.
2. Import `sql/bullen_vehiclekeys.sql`.
3. Ensure your server order includes:
   - `qb-core`
   - `ox_lib`
   - `oxmysql`
   - your target / inventory resource
   - `bullen_vehiclekeys`
4. Open `config.lua` and set:
   - framework ownership table values
   - inventory system
   - target system
   - locksmith locations
5. Add the configured key, blank key, and lockpick items to your inventory system if they do not already exist.
6. Restart the server.

Example ensure order:

```cfg
ensure ox_lib
ensure oxmysql
ensure qb-core
ensure ox_target
ensure ox_inventory
ensure bullen_vehiclekeys
```

## Resource structure

```text
bullen_vehiclekeys/
├─ fxmanifest.lua
├─ config.lua
├─ client/main.lua
├─ server/main.lua
├─ locales/en.lua
├─ sql/bullen_vehiclekeys.sql
└─ README.md
```

## Access model

The resource intentionally keeps access state separate:

### 1. Owned access
Resolved live from your configured owned vehicle table.

### 2. Shared access
Stored in `bullen_vehiclekeys_shared`. Intended for owner-granted persistent access that can be revoked later.

### 3. Physical key access
Granted by possession of a metadata key item with the configured plate field.

### 4. Temporary stolen access
Granted after successful hotwire or compatible theft outcome. This is **not** persisted and is **not** broadcast to other players.

### 5. Global unlocked door state
Stored as a replicated entity statebag flag. This only affects door lock state. It does **not** imply ownership or a real key.

## Anti-exploit design

This resource is built around a simple rule: the client can request, the server decides.

- target `canInteract` logic is intentionally lightweight and local
- no async server callback waits are used inside target visibility checks
- lockpick, hotwire, and carjacking all use server-generated attempt tokens
- the client can report that an action completed, but the server re-validates and resolves the final result
- temporary stolen access is only granted to the player who earned it
- ownership, alarm installation, shared access, and locksmith actions are validated server-side

## Config guide

`config.lua` is split into premium-style sections:

- `Config.General`
- `Config.Framework`
- `Config.Inventory`
- `Config.Target`
- `Config.OwnedKeys`
- `Config.SharedKeys`
- `Config.PhysicalKeys`
- `Config.TemporaryStolen`
- `Config.Locksmith`
- `Config.Alarms`
- `Config.NpcLockNormalization`
- `Config.Lockpick`
- `Config.Hotwire`
- `Config.Carjacking`
- `Config.WeaponProfiles`
- `Config.SpeedBands`
- `Config.AggressiveWeaponPools`
- `Config.Passengers`
- `Config.SearchableNpcKeys`
- `Config.FakePlates`
- `Config.Commands`
- `Config.Debug`

### Ownership provider

By default, owned access uses:

```lua
Config.Framework.Ownership = {
    Table = 'player_vehicles',
    OwnerColumn = 'citizenid',
    PlateColumn = 'plate',
}
```

If your server uses another schema, change those fields or supply `CustomResolver`.

### Inventory

Set the correct inventory bridge:

```lua
Config.Inventory.System = 'ox_inventory' -- or 'qb-inventory'
```

The resource expects:
- a vehicle key item
- a blank vehicle key item
- a lockpick item

### Target system

Choose one:

```lua
Config.Target.System = 'ox_target'
-- or
Config.Target.System = 'qb-target'
```

### Fake plates

If another resource uses entity statebags for fake plates, enable `Config.FakePlates.Enabled` and map the bag keys. Access checks will then prefer the real plate from state instead of the displayed plate.

## Locksmith section

Locksmith service is location-based and configurable.

Supported actions:

### Copy key
Rules:
- player must already have **owned** access
- a blank key item can be required
- money is charged
- duplicate metadata key item is created for that exact plate
- stolen temporary access does **not** qualify

### Install alarm
Rules:
- only the owner can install it
- alarm install persists in `bullen_vehiclekeys_alarms`
- alarm state is separate from vehicle ownership
- owner is charged based on config

## Alarm section

Alarm logic is intentionally separate from ownership and key state.

When an owned vehicle has an installed alarm:
- the owner can be notified when somebody starts breaking in
- the owner can be notified again when the breach succeeds
- horn/alarm effects are triggered locally around the vehicle

Default owner messages are:
- `Someone is trying to break into your vehicle`
- `Someone just broke into your vehicle`

## Lockpick / hotwire flow

### Lockpick
Lockpicking is the exterior breach step.

Flow:
1. player targets the vehicle or uses `/lockpick`
2. server validates distance, vehicle, and item requirements
3. client runs progress / skill check
4. client reports completion state
5. server re-validates and rolls the final result
6. on success:
   - vehicle becomes globally unlocked
   - vehicle is marked breached
   - ownership is **not** granted

### Hotwire
Hotwiring is the ignition bypass step.

Flow:
1. player enters a breached vehicle without access
2. driver-seat enforcement shuts the engine down
3. if the vehicle is breached, hotwire auto-starts
4. server resolves the final result
5. on success:
   - only that player gets session-only stolen driver access

If a player gets a real metadata key instead, hotwire is no longer required.

## Ambient NPC lock normalization

GTA ambient traffic does not stay locked on its own, so this resource treats ambient locking as a repeated normalization problem.

The client repeatedly scans nearby vehicles and:
- skips protected / owned plates
- skips player-occupied vehicles
- skips configured emergency / blacklisted classes and models
- keeps valid civilian ambient vehicles locked by default

This covers both:
- moving NPC-driven vehicles
- parked civilian ambient vehicles

## Carjacking section

Carjacking is a separate intimidation system from lockpicking.

Requirements:
- exact NPC driver target
- actual free-aim on the driver ped
- close distance
- line of sight
- aim cone requirement
- aim hold duration
- no player drivers

Server flow:
1. client requests begin
2. server validates driver / vehicle / range
3. client holds aim
4. client reports maintained aim
5. server re-validates and decides the final outcome

Possible outcomes:
- **driveoff**: driver panics and speeds away
- **surrender**: driver exits and flees
- **aggressive**: driver exits armed and fights

Weapon profiles and speed bands shape those outcomes:
- slower vehicles favor surrender
- faster vehicles favor driveoff
- stronger weapons can bias more serious reactions

Passengers can optionally mirror the driver outcome through config.

## Searchable NPC key retrieval

When an NPC exits after a carjacking and keeps the key:
- the driver ped is marked with searchable state
- the player can target that NPC later
- searching grants a **real physical key item**
- the key item is bound to the correct plate through metadata

This can be configured as:
- dead-only
- dead or incapacitated

If the key is never recovered, breach + hotwire still remains a valid fallback.

## Commands

Configured by default:

- `/vlock` — toggle the nearest/current accessible vehicle lock state
- `/lockpick` — fallback lockpick command
- `/givekeys [id]` — grant shared access
- `/revokekeys [id]` — revoke shared access

`/vlock` also registers a default key mapping in config.

## Exports

Server exports included:

```lua
exports('HasAccess', function(source, plate) end)
exports('HasRealAccess', function(source, plate) end)
exports('GrantTemporaryAccess', function(source, plate, reason) end)
exports('RevokeTemporaryAccess', function(source, plate) end)
exports('HasAlarmInstalled', function(plate) end)
exports('EnsurePhysicalKey', function(source, plate) end)
exports('ReplacePhysicalKey', function(source, plate) end)
```

## SQL tables

### `bullen_vehiclekeys_shared`
Persistent owner -> target shared access.

### `bullen_vehiclekeys_alarms`
Persistent alarm install state by plate.

## Troubleshooting / support notes

### Vehicles stay locked even after a successful breach
Check that the vehicle is networked and that your server is running OneSync. This script expects replicated entity statebags to exist for synchronized door state.

### Owned vehicles get caught by ambient normalization
Make sure `Config.Framework.Ownership` points to the correct table / owner / plate columns.

### Physical keys do not register
Check:
- the inventory bridge setting
- the configured key item name
- the metadata plate field name
- item display stays on your configured inventory item label while vehicle info is shown in metadata description

### Locksmith says the vehicle is invalid
Make sure the vehicle is physically close to the configured locksmith location and has a valid network ID.

### qb-target / ox_target interaction does not appear
Set the correct target bridge in config and ensure the target resource is started before `bullen_vehiclekeys`.

### Fake plates
Enable `Config.FakePlates` only if you already have a compatible fake-plate resource exposing the configured statebag keys.

## Final notes

This resource was intentionally kept modular inside the requested file layout:
- client-side visibility and NPC behavior stay local
- important theft outcomes resolve server-side
- persistent data is limited to clean, purpose-built tables
- access state remains clearly separated for maintainability and resale friendliness


## Lockpick minigame selection

`bullen_vehiclekeys` supports multiple explicitly selected lockpick minigame backends.

```lua
Config.Lockpick.Minigame = 'burevestnik' -- 'burevestnik' | 'ox_lib_skillcheck' | 'lockpick' | 'none'
```

Available options:
- `burevestnik` = uses the built-in Burevestnik export integration
- `ox_lib_skillcheck` = uses `Config.Lockpick.SkillCheck`
- `lockpick` = uses the built-in integration for the external `lockpick` resource
- `none` = skips the minigame and only runs the configured progressbar

Backend-specific resource names, exports, and tries are kept in the client integration so `config.lua` stays clean.

Default built-in backend mappings:
- `burevestnik` -> `exports['Burevestnik_lockpick_minigame']:Burevestnik_lockpick_minigame_start()`
- `lockpick` -> `exports['lockpick']:startLockpick(3)`

No automatic fallback is performed. The selected backend must be installed and started.

## Hotwire UX
By default in this build, hotwiring is progressbar-only after breach, with no additional minigame or skillcheck. The progress label is `Hotwiring vehicle`.


## Carjacking behavior update
This build tightens carjacking so it only starts while you are on foot, armed, actively free-aiming, and still aimed at the exact NPC driver during the full hold period. Exit outcomes are also blocked for moving vehicles and converted to drive-off instead.


## Carjacking behavior update
This build removes the passive carjacking detection loop and switches carjacking to an explicit, driver-side target action. The option is only visible when you are near the exact targeted vehicle's driver side and holding an allowed weapon.


## Ambient lock normalization update
This build limits ambient lock normalization to parked or unoccupied vehicles. Moving occupied NPC vehicles are ignored so nearby drivers are not disturbed by the normalization loop.


## Ambient lock split update
This build keeps moving occupied NPC vehicles locked with a lightweight lock-only pass, while the heavier normalization path remains limited to parked or unoccupied vehicles.


## Moving NPC vehicle lock update
This build stops globally locking occupied moving NPC vehicles. Instead, moving NPC-driven vehicles use a player-local entry deny so they stay inaccessible to the local player without disturbing the NPC driver AI.


## Ambient lock safety update
This build ensures no occupied vehicle ever goes through the global normalization path. Occupied NPC-driven vehicles now use only a local player entry deny, while only truly unoccupied ambient vehicles are globally normalized.


## Inventory label behavior

Physical keys now use the configured base inventory item label as-is.
Vehicle-specific identity is stored in metadata, using the configured plate field and optional description text.
This keeps inventory labels clean while still validating the correct key per vehicle.


## Key replacement behavior

- Physical keys now reuse the same base item and will not be duplicated if the player already has the current valid key for that vehicle.
- Locksmith replacement now rotates the vehicle's active key id. Older stolen or copied keys stop working after replacement.
- Apply the added `bullen_vehiclekeys_key_registry` SQL table before using the updated locksmith replacement flow.
