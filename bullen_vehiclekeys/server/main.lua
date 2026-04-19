local QBCore = exports['qb-core']:GetCoreObject()
lib.locale()

-- ============================================================================
-- Server state
-- ============================================================================

local SessionAccess = {}
local PendingAttempts = {
    lockpick = {},
    hotwire = {},
    fakeplate = {},
}
local OwnerCache = {}
local SharedCache = {}
local AlarmCache = {}
local KeyRegistryCache = {}
local OwnershipVehicleColumnCache = {}

-- ============================================================================
-- Utility helpers
-- ============================================================================

local function debugPrint(...)
    if not Config.Debug.Enabled then
        return
    end

    local parts = { '[bullen_vehiclekeys]' }

    for i = 1, select('#', ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end

    print(table.concat(parts, ' '))
end

local function trimPlate(value)
    if not value then
        return nil
    end

    local plate = tostring(value)
    plate = plate:gsub('^%s+', ''):gsub('%s+$', '')
    plate = plate:gsub('%s+', ' ')
    plate = plate:upper()

    if plate == '' then
        return nil
    end

    return plate
end

local function trimIdentifier(value)
    if not value then
        return nil
    end

    local identifier = tostring(value)
    identifier = identifier:gsub('^%s+', ''):gsub('%s+$', '')

    if identifier == '' then
        return nil
    end

    return identifier
end

local function generateKeyId()
    local left = math.random(100000, 999999)
    local right = math.random(100000, 999999)
    return ('%d-%d-%d'):format(os.time(), left, right)
end

local function getPlayer(source)
    return QBCore.Functions.GetPlayer(source)
end

local function getCitizenId(source)
    local player = getPlayer(source)
    return player and player.PlayerData and player.PlayerData.citizenid or nil
end

local function getCharacterName(source)
    local player = getPlayer(source)

    if player and player.PlayerData and player.PlayerData.charinfo then
        local charinfo = player.PlayerData.charinfo
        local fullName = ((charinfo.firstname or '') .. ' ' .. (charinfo.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')

        if fullName ~= '' then
            return fullName
        end
    end

    return GetPlayerName(source) or ('ID %s'):format(source)
end

local function titleCaseWords(value)
    local normalized = tostring(value or ''):gsub('_', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')

    if normalized == '' then
        return nil
    end

    return (normalized:gsub('(%S+)', function(word)
        return word:sub(1, 1):upper() .. word:sub(2):lower()
    end))
end

local function getVehicleDisplayLabelFromModel(model)
    if not model then
        return nil
    end

    local modelKey = tostring(model):lower()
    local sharedVehicle = QBCore and QBCore.Shared and QBCore.Shared.Vehicles and QBCore.Shared.Vehicles[modelKey]

    if sharedVehicle then
        local brand = trimIdentifier(sharedVehicle.brand)
        local name = trimIdentifier(sharedVehicle.name)
        local label = trimIdentifier(sharedVehicle.label)

        if label then
            return label
        end

        if brand and name then
            return ('%s %s'):format(brand, name)
        end

        return name or brand or titleCaseWords(modelKey)
    end

    return titleCaseWords(modelKey)
end

local function ownershipTableHasVehicleColumn()
    local tableName = Config.Framework.Ownership.Table
    local cached = OwnershipVehicleColumnCache[tableName]

    if cached ~= nil then
        return cached
    end

    local result = MySQL.single.await(('SHOW COLUMNS FROM `%s` LIKE ?'):format(tableName), { 'vehicle' })
    local hasColumn = result ~= nil
    OwnershipVehicleColumnCache[tableName] = hasColumn
    return hasColumn
end

local function resolveOwnedVehicleLabel(row)
    if not row then
        return nil
    end

    local vehicleValue = row.vehicle

    if not vehicleValue then
        return nil
    end

    if type(vehicleValue) == 'string' then
        local trimmed = trimIdentifier(vehicleValue)

        if not trimmed then
            return nil
        end

        if trimmed:sub(1, 1) == '{' or trimmed:sub(1, 1) == '[' then
            local ok, decoded = pcall(json.decode, trimmed)

            if ok and type(decoded) == 'table' then
                vehicleValue = decoded.model or decoded.vehicle or decoded.modelName or decoded.spawncode or decoded.name or decoded.label or trimmed
            else
                vehicleValue = trimmed
            end
        else
            vehicleValue = trimmed
        end
    end

    return getVehicleDisplayLabelFromModel(vehicleValue)
end

local function notify(source, notifType, message)
    TriggerClientEvent('bullen_vehiclekeys:client:notify', source, notifType or 'inform', message)
end

local function getEntityFromNetId(netId, entityType)
    local id = tonumber(netId)

    if not id or id == 0 then
        return 0
    end

    local entity = NetworkGetEntityFromNetworkId(id)

    if entity == 0 or not DoesEntityExist(entity) then
        return 0
    end

    if entityType and GetEntityType(entity) ~= entityType then
        return 0
    end

    return entity
end

local function getVehicleFromNetId(netId)
    return getEntityFromNetId(netId, 2)
end

local function getPedFromNetId(netId)
    return getEntityFromNetId(netId, 1)
end

local function getPlayerCoords(source)
    local ped = GetPlayerPed(source)

    if ped == 0 or not DoesEntityExist(ped) then
        return nil
    end

    return GetEntityCoords(ped)
end

local function isPlayerNearEntity(source, entity, maxDistance)
    local playerCoords = getPlayerCoords(source)

    if not playerCoords or entity == 0 or not DoesEntityExist(entity) then
        return false
    end

    return #(playerCoords - GetEntityCoords(entity)) <= maxDistance
end

local function arePlayersNear(sourceA, sourceB, maxDistance)
    local coordsA = getPlayerCoords(sourceA)
    local coordsB = getPlayerCoords(sourceB)

    if not coordsA or not coordsB then
        return false
    end

    return #(coordsA - coordsB) <= maxDistance
end

local function createAttempt(kind, source, payload, ttlSeconds)
    local token = ('%s:%s:%s:%s'):format(kind, source, os.time(), math.random(111111, 999999))

    PendingAttempts[kind][token] = {
        source = source,
        expiresAt = os.time() + (ttlSeconds or 30),
        payload = payload or {},
    }

    return token
end

local function takeAttempt(kind, source, token)
    local bucket = PendingAttempts[kind]
    local data = bucket[token]

    if not data then
        return nil
    end

    bucket[token] = nil

    if data.source ~= source or data.expiresAt < os.time() then
        return nil
    end

    return data.payload
end

local function getStateBag(entity)
    if entity == 0 or not DoesEntityExist(entity) then
        return nil
    end

    return Entity(entity).state
end

local function setVehicleState(netId, key, value)
    local vehicle = getVehicleFromNetId(netId)

    if vehicle == 0 then
        return false
    end

    local state = getStateBag(vehicle)

    if not state then
        return false
    end

    state:set(key, value, true)
    return true
end

local function setPedSearchState(netId, payload)
    local ped = getPedFromNetId(netId)

    if ped == 0 then
        return false
    end

    local state = getStateBag(ped)

    if not state then
        return false
    end

    state:set('xvkSearchableKey', payload, true)
    return true
end

local function findSourceByCitizenId(citizenId)
    if not citizenId then
        return nil
    end

    for _, src in ipairs(GetPlayers()) do
        local serverId = tonumber(src)

        if getCitizenId(serverId) == citizenId then
            return serverId
        end
    end

    return nil
end

local function removeMoney(source, account, amount, reason)
    local player = getPlayer(source)

    if not player then
        return false
    end

    return player.Functions.RemoveMoney(account or Config.Framework.DefaultMoneyAccount, amount, reason or 'bullen_vehiclekeys')
end

local function hasEnoughMoney(source, account, amount)
    local player = getPlayer(source)

    if not player then
        return false
    end

    account = account or Config.Framework.DefaultMoneyAccount
    local balance = player.PlayerData.money and player.PlayerData.money[account] or 0

    return balance >= amount
end

-- ============================================================================
-- Ownership / shared access / alarm persistence
-- ============================================================================

local function getCachedKeyId(plate)
    local cacheEntry = KeyRegistryCache[plate]

    if cacheEntry and cacheEntry.expiresAt > os.time() then
        return cacheEntry.keyId or nil
    end

    return nil
end

local function cacheKeyId(plate, keyId)
    KeyRegistryCache[plate] = {
        keyId = keyId or false,
        expiresAt = os.time() + 60,
    }
end

local function fetchCurrentPhysicalKeyId(plate)
    plate = trimPlate(plate)

    if not plate then
        return nil
    end

    local cacheEntry = KeyRegistryCache[plate]

    if cacheEntry and cacheEntry.expiresAt > os.time() then
        return cacheEntry.keyId or nil
    end

    local row = MySQL.single.await('SELECT `current_key_id` FROM `bullen_vehiclekeys_key_registry` WHERE `plate` = ? LIMIT 1', { plate })
    local keyId = row and trimIdentifier(row.current_key_id) or nil
    cacheKeyId(plate, keyId)
    return keyId
end

local function setCurrentPhysicalKeyId(plate, keyId, updatedBy)
    plate = trimPlate(plate)
    keyId = trimIdentifier(keyId)

    if not plate or not keyId then
        return nil
    end

    MySQL.update.await([[
        INSERT INTO `bullen_vehiclekeys_key_registry` (`plate`, `current_key_id`, `updated_by`)
        VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE
            `current_key_id` = VALUES(`current_key_id`),
            `updated_by` = VALUES(`updated_by`),
            `updated_at` = CURRENT_TIMESTAMP
    ]], { plate, keyId, updatedBy })

    cacheKeyId(plate, keyId)
    return keyId
end

local function ensureCurrentPhysicalKeyId(plate, updatedBy)
    local keyId = fetchCurrentPhysicalKeyId(plate)

    if keyId then
        return keyId
    end

    return setCurrentPhysicalKeyId(plate, generateKeyId(), updatedBy)
end

local function rotateCurrentPhysicalKeyId(plate, updatedBy)
    return setCurrentPhysicalKeyId(plate, generateKeyId(), updatedBy)
end

local function fetchOwnerCitizenId(plate)
    plate = trimPlate(plate)

    if not plate then
        return nil
    end

    local cacheEntry = OwnerCache[plate]

    if cacheEntry and cacheEntry.expiresAt > os.time() then
        return cacheEntry.owner or nil
    end

    local owner

    if Config.Framework.Ownership.CustomResolver then
        local ok, customOwner = pcall(Config.Framework.Ownership.CustomResolver, plate)

        if ok then
            owner = trimIdentifier(customOwner)
        else
            debugPrint('Custom ownership resolver failed for', plate, customOwner)
        end
    else
        local query = ('SELECT `%s` AS owner FROM `%s` WHERE `%s` = ? LIMIT 1'):format(
            Config.Framework.Ownership.OwnerColumn,
            Config.Framework.Ownership.Table,
            Config.Framework.Ownership.PlateColumn
        )

        local row = MySQL.single.await(query, { plate })
        owner = row and trimIdentifier(row.owner) or nil
    end

    OwnerCache[plate] = {
        owner = owner or false,
        expiresAt = os.time() + (Config.Framework.Ownership.CacheSeconds or 60),
    }

    return owner
end

local function fetchOwnedVehicles(citizenId)
    citizenId = trimIdentifier(citizenId)

    if not citizenId then
        return {}
    end

    local selectFields = ('`%s` AS plate'):format(Config.Framework.Ownership.PlateColumn)

    if ownershipTableHasVehicleColumn() then
        selectFields = selectFields .. ', `vehicle` AS vehicle'
    end

    local query = ('SELECT %s FROM `%s` WHERE `%s` = ? ORDER BY `%s` ASC'):format(
        selectFields,
        Config.Framework.Ownership.Table,
        Config.Framework.Ownership.OwnerColumn,
        Config.Framework.Ownership.PlateColumn
    )

    local rows = MySQL.query.await(query, { citizenId }) or {}
    local response = {}

    for _, row in ipairs(rows) do
        local plate = trimPlate(row.plate)

        if plate then
            response[#response + 1] = {
                plate = plate,
                label = resolveOwnedVehicleLabel(row),
            }
        end
    end

    return response
end

local function fetchProtectedPlateMap(plates)
    local response = {}
    local unique = {}
    local missing = {}

    for _, rawPlate in ipairs(plates or {}) do
        local plate = trimPlate(rawPlate)

        if plate and not unique[plate] then
            unique[plate] = true

            local cacheEntry = OwnerCache[plate]

            if cacheEntry and cacheEntry.expiresAt > os.time() then
                response[plate] = cacheEntry.owner and true or false
            else
                missing[#missing + 1] = plate
            end
        end
    end

    if #missing > 0 then
        local placeholders = {}
        for i = 1, #missing do
            placeholders[i] = '?'
        end

        local query = ('SELECT `%s` AS owner, `%s` AS plate FROM `%s` WHERE `%s` IN (%s)'):format(
            Config.Framework.Ownership.OwnerColumn,
            Config.Framework.Ownership.PlateColumn,
            Config.Framework.Ownership.Table,
            Config.Framework.Ownership.PlateColumn,
            table.concat(placeholders, ',')
        )

        local rows = MySQL.query.await(query, missing) or {}
        local found = {}

        for _, row in ipairs(rows) do
            local plate = trimPlate(row.plate)
            local owner = trimIdentifier(row.owner)

            if plate then
                found[plate] = owner
                response[plate] = owner and true or false
                OwnerCache[plate] = {
                    owner = owner or false,
                    expiresAt = os.time() + (Config.Framework.Ownership.CacheSeconds or 60),
                }
            end
        end

        for _, plate in ipairs(missing) do
            if found[plate] == nil then
                response[plate] = false
                OwnerCache[plate] = {
                    owner = false,
                    expiresAt = os.time() + (Config.Framework.Ownership.CacheSeconds or 60),
                }
            end
        end
    end

    return response
end

local function getSharedCache(plate, ownerCitizenId)
    local cacheEntry = SharedCache[plate]

    if cacheEntry and cacheEntry.expiresAt > os.time() and cacheEntry.ownerCitizenId == ownerCitizenId then
        return cacheEntry
    end

    local rows = MySQL.query.await('SELECT owner_citizenid, shared_citizenid FROM bullen_vehiclekeys_shared WHERE plate = ?', { plate }) or {}
    local cache = {
        ownerCitizenId = ownerCitizenId,
        holders = {},
        expiresAt = os.time() + (Config.SharedKeys.CacheSeconds or 60),
    }

    for _, row in ipairs(rows) do
        local rowOwner = trimIdentifier(row.owner_citizenid)
        local sharedCitizenId = trimIdentifier(row.shared_citizenid)

        if rowOwner == ownerCitizenId and sharedCitizenId then
            cache.holders[sharedCitizenId] = true
        end
    end

    SharedCache[plate] = cache
    return cache
end

local function invalidateSharedCache(plate)
    SharedCache[trimPlate(plate)] = nil
end

local function hasSharedAccessForCitizen(citizenId, plate, ownerCitizenId)
    if not Config.SharedKeys.Enabled or not citizenId or not ownerCitizenId then
        return false
    end

    local cache = getSharedCache(plate, ownerCitizenId)
    return cache.holders[citizenId] == true
end

local function hasAlarmInstalled(plate)
    if not Config.Alarms.Enabled then
        return false
    end

    plate = trimPlate(plate)

    if not plate then
        return false
    end

    local cacheEntry = AlarmCache[plate]

    if cacheEntry and cacheEntry.expiresAt > os.time() then
        return cacheEntry.installed == true
    end

    local row = MySQL.single.await('SELECT plate FROM bullen_vehiclekeys_alarms WHERE plate = ? LIMIT 1', { plate })
    local installed = row ~= nil

    AlarmCache[plate] = {
        installed = installed,
        expiresAt = os.time() + 60,
    }

    return installed
end

local function invalidateAlarmCache(plate)
    AlarmCache[trimPlate(plate)] = nil
end

local function notifyVehicleOwner(plate, localeKey)
    if not Config.Alarms.Enabled or not Config.Alarms.NotifyOwner then
        return
    end

    local ownerCitizenId = fetchOwnerCitizenId(plate)

    if not ownerCitizenId then
        return
    end

    local ownerSource = findSourceByCitizenId(ownerCitizenId)

    if ownerSource then
        notify(ownerSource, 'error', locale(localeKey, plate))
    end
end

-- ============================================================================
-- Inventory wrappers
-- ============================================================================

local function qbAddItem(source, itemName, amount, metadata)
    local player = getPlayer(source)

    if not player then
        return false
    end

    local added = player.Functions.AddItem(itemName, amount, false, metadata or {})

    if added and TriggerClientEvent then
        TriggerClientEvent('inventory:client:ItemBox', source, QBCore.Shared.Items[itemName], 'add', amount)
    end

    return added
end

local function qbRemoveItem(source, itemName, amount, metadata)
    local player = getPlayer(source)

    if not player then
        return false
    end

    local removed = player.Functions.RemoveItem(itemName, amount, false, metadata or nil)

    if removed and TriggerClientEvent then
        TriggerClientEvent('inventory:client:ItemBox', source, QBCore.Shared.Items[itemName], 'remove', amount)
    end

    return removed
end

local function hasItem(source, itemName, amount)
    amount = amount or 1

    if Config.Inventory.System == 'ox_inventory' then
        local count = exports.ox_inventory:Search(source, 'count', itemName) or 0
        return count >= amount
    end

    local player = getPlayer(source)

    if not player then
        return false
    end

    local item = player.Functions.GetItemByName(itemName)
    return item and item.amount >= amount or false
end

local function removeGenericItem(source, itemName, amount)
    amount = amount or 1

    if Config.Inventory.System == 'ox_inventory' then
        return exports.ox_inventory:RemoveItem(source, itemName, amount)
    end

    return qbRemoveItem(source, itemName, amount)
end

local function addGenericItem(source, itemName, amount, metadata)
    amount = amount or 1

    if Config.Inventory.System == 'ox_inventory' then
        return exports.ox_inventory:AddItem(source, itemName, amount, metadata)
    end

    return qbAddItem(source, itemName, amount, metadata)
end

local function sanitizeFakePlateDisplay(value)
    if not value then
        return nil
    end

    local plate = tostring(value):upper()
    plate = plate:gsub('%s+', '')
    plate = plate:gsub('[^A-Z0-9]', '')

    local maxLetters = Config.FakePlates.Install.TextEntry.MaxLetters or 3
    local maxNumbers = Config.FakePlates.Install.TextEntry.MaxNumbers or 3

    local letters = plate:match('^([A-Z]+)')
    local numbers = plate:match('([0-9]+)$')

    if not letters or not numbers then
        return nil
    end

    if #letters < 1 or #letters > maxLetters then
        return nil
    end

    if #numbers < 1 or #numbers > maxNumbers then
        return nil
    end

    if (#letters + #numbers) ~= #plate then
        return nil
    end

    return letters .. numbers
end

local function getVehicleRealPlate(vehicle)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return nil
    end

    local state = getStateBag(vehicle)

    if Config.FakePlates.Enabled and state and state[Config.FakePlates.ActiveStatebag] and state[Config.FakePlates.RealPlateStatebag] then
        return trimPlate(state[Config.FakePlates.RealPlateStatebag])
    end

    return trimPlate(GetVehicleNumberPlateText(vehicle))
end

local function doesKeyMetadataMatch(plate, currentKeyId, metadata)
    metadata = metadata or {}

    if trimPlate(metadata[Config.PhysicalKeys.MetadataPlateField]) ~= plate then
        return false
    end

    if currentKeyId then
        return trimIdentifier(metadata[Config.PhysicalKeys.MetadataKeyIdField]) == currentKeyId
    end

    return true
end

local function removePhysicalKeysByPlate(source, plate)
    if not Config.PhysicalKeys.Enabled then
        return 0
    end

    plate = trimPlate(plate)

    if not plate then
        return 0
    end

    local removed = 0

    if Config.Inventory.System == 'ox_inventory' then
        local slots = exports.ox_inventory:Search(source, 'slots', Config.Inventory.KeyItem) or {}

        for _, slot in pairs(slots) do
            local metadata = slot.metadata or {}

            if trimPlate(metadata[Config.PhysicalKeys.MetadataPlateField]) == plate then
                local amount = tonumber(slot.count) or 1
                if exports.ox_inventory:RemoveItem(source, Config.Inventory.KeyItem, amount, metadata, slot.slot) then
                    removed = removed + amount
                end
            end
        end

        return removed
    end

    local player = getPlayer(source)

    if not player then
        return 0
    end

    for _, item in pairs(player.PlayerData.items or {}) do
        if item and item.name == Config.Inventory.KeyItem then
            local info = item.info or item.metadata or {}

            if trimPlate(info[Config.PhysicalKeys.MetadataPlateField]) == plate then
                local amount = tonumber(item.amount) or 1
                local slot = item.slot or false
                if player.Functions.RemoveItem(Config.Inventory.KeyItem, amount, slot) then
                    removed = removed + amount
                end
            end
        end
    end

    return removed
end

local function playerHasPhysicalKey(source, plate)
    if not Config.PhysicalKeys.Enabled then
        return false
    end

    plate = trimPlate(plate)

    if not plate then
        return false
    end

    local currentKeyId = fetchCurrentPhysicalKeyId(plate)

    if Config.Inventory.System == 'ox_inventory' then
        local slots = exports.ox_inventory:Search(source, 'slots', Config.Inventory.KeyItem) or {}

        for _, slot in pairs(slots) do
            if doesKeyMetadataMatch(plate, currentKeyId, slot.metadata or {}) then
                return true
            end
        end

        return false
    end

    local player = getPlayer(source)

    if not player then
        return false
    end

    for _, item in pairs(player.PlayerData.items or {}) do
        if item and item.name == Config.Inventory.KeyItem then
            local info = item.info or item.metadata or {}

            if doesKeyMetadataMatch(plate, currentKeyId, info) then
                return true
            end
        end
    end

    return false
end

local function addVehicleKeyItem(source, plate, options)
    if not Config.PhysicalKeys.Enabled then
        return false
    end

    plate = trimPlate(plate)
    options = options or {}

    if not plate then
        return false
    end

    if options.skipIfExists ~= false and playerHasPhysicalKey(source, plate) then
        return true
    end

    local keyId = options.keyId or ensureCurrentPhysicalKeyId(plate, options.updatedBy or getCitizenId(source) or 'system')

    if not keyId then
        return false
    end

    local metadata = {
        [Config.PhysicalKeys.MetadataPlateField] = plate,
        [Config.PhysicalKeys.MetadataKeyIdField] = keyId,
    }

    if Config.PhysicalKeys.IncludeDescription then
        metadata.description = Config.PhysicalKeys.DescriptionFormat:format(plate)
    end

    if Config.Inventory.System == 'ox_inventory' then
        return exports.ox_inventory:AddItem(source, Config.Inventory.KeyItem, 1, metadata)
    end

    return qbAddItem(source, Config.Inventory.KeyItem, 1, metadata)
end

local function replaceVehicleKeyItem(source, plate, updatedBy)
    plate = trimPlate(plate)

    if not plate then
        return false
    end

    local keyId = rotateCurrentPhysicalKeyId(plate, updatedBy or getCitizenId(source) or 'system')

    if not keyId then
        return false
    end

    removePhysicalKeysByPlate(source, plate)

    return addVehicleKeyItem(source, plate, {
        skipIfExists = false,
        keyId = keyId,
        updatedBy = updatedBy,
    })
end

-- ============================================================================
-- Access resolution
-- ============================================================================

local function grantTemporaryAccess(source, plate, reason)
    if not Config.TemporaryStolen.Enabled then
        return false
    end

    plate = trimPlate(plate)

    if not plate then
        return false
    end

    SessionAccess[source] = SessionAccess[source] or {}
    SessionAccess[source][plate] = {
        reason = reason or 'stolen',
        grantedAt = os.time(),
    }

    return true
end

local function revokeTemporaryAccess(source, plate)
    plate = trimPlate(plate)

    if not plate or not SessionAccess[source] then
        return false
    end

    SessionAccess[source][plate] = nil
    return true
end

local function hasTemporaryAccess(source, plate)
    plate = trimPlate(plate)

    return plate and SessionAccess[source] and SessionAccess[source][plate] ~= nil or false
end

local function resolveAccessState(source, plate)
    plate = trimPlate(plate)

    if not plate then
        return {
            plate = nil,
            owned = false,
            shared = false,
            physical = false,
            stolen = false,
            any = false,
            persistent = false,
            ownerCitizenId = nil,
            hasAlarm = false,
        }
    end

    local citizenId = getCitizenId(source)
    local ownerCitizenId = fetchOwnerCitizenId(plate)
    local owned = Config.OwnedKeys.Enabled and ownerCitizenId and citizenId and ownerCitizenId == citizenId or false
    local shared = hasSharedAccessForCitizen(citizenId, plate, ownerCitizenId)
    local physical = playerHasPhysicalKey(source, plate)
    local stolen = hasTemporaryAccess(source, plate)
    local hasAlarm = hasAlarmInstalled(plate)

    local access = {
        plate = plate,
        owned = owned,
        shared = shared,
        physical = physical,
        stolen = stolen,
        any = owned or shared or physical or stolen,
        persistent = owned or shared or physical,
        ownerCitizenId = ownerCitizenId,
        hasAlarm = hasAlarm,
    }

    if Config.Debug.Enabled and Config.Debug.PrintAccess then
        debugPrint('Access', source, plate, json.encode(access))
    end

    return access
end

local isNearLocksmith

local function pushAccessUpdate(source, plate)
    local access = resolveAccessState(source, plate)
    TriggerClientEvent('bullen_vehiclekeys:client:accessUpdated', source, plate, access)
    return access
end

-- ============================================================================
-- Shared callbacks
-- ============================================================================

lib.callback.register('bullen_vehiclekeys:server:getVehicleAccess', function(source, data)
    local plate = trimPlate(data and data.plate)

    if not plate and data and data.netId then
        local vehicle = getVehicleFromNetId(data.netId)

        if vehicle ~= 0 then
            plate = trimPlate(GetVehicleNumberPlateText(vehicle))
        end
    end

    return resolveAccessState(source, plate)
end)

lib.callback.register('bullen_vehiclekeys:server:getProtectedPlates', function(source, plates)
    return fetchProtectedPlateMap(plates or {})
end)

lib.callback.register('bullen_vehiclekeys:server:getOwnedVehiclesForAlarm', function(source)
    local nearService = isNearLocksmith(source)

    if not nearService then
        return {}
    end

    local citizenId = getCitizenId(source)
    local ownedVehicles = fetchOwnedVehicles(citizenId)
    local response = {}

    for _, entry in ipairs(ownedVehicles) do
        response[#response + 1] = {
            plate = entry.plate,
            label = entry.label,
            hasAlarm = hasAlarmInstalled(entry.plate),
        }
    end

    return response
end)

lib.callback.register('bullen_vehiclekeys:server:beginFakePlateInstall', function(source, data)
    if not Config.FakePlates.Enabled then
        return { ok = false, message = locale('fakeplate_disabled') }
    end

    local netId = tonumber(data and data.netId)
    local vehicle = getVehicleFromNetId(netId)

    if vehicle == 0 then
        return { ok = false, message = locale('invalid_vehicle') }
    end

    if not isPlayerNearEntity(source, vehicle, (Config.FakePlates.Install.Distance or 2.5) + 1.0) then
        return { ok = false, message = locale('too_far') }
    end

    local state = getStateBag(vehicle)
    if state and state[Config.FakePlates.ActiveStatebag] then
        return { ok = false, message = locale('fakeplate_already_active') }
    end

    local realPlate = getVehicleRealPlate(vehicle)
    local access = resolveAccessState(source, realPlate)

    if Config.FakePlates.Install.RequireAccess and not access.any then
        return { ok = false, message = locale('no_keys') }
    end

    if not hasItem(source, Config.FakePlates.Items.FakePlate, 1) then
        return { ok = false, message = locale('fakeplate_need_fakeplate') }
    end

    if not hasItem(source, Config.FakePlates.Items.PlateKit, 1) then
        return { ok = false, message = locale('fakeplate_need_platekit') }
    end

    if not hasItem(source, Config.FakePlates.Items.Screwdriver, 1) then
        return { ok = false, message = locale('fakeplate_need_screwdriver') }
    end

    local token = createAttempt('fakeplate', source, {
        netId = netId,
        realPlate = realPlate,
    }, 45)

    return {
        ok = true,
        token = token,
        realPlate = realPlate,
    }
end)

lib.callback.register('bullen_vehiclekeys:server:finishFakePlateInstall', function(source, token, result, displayPlate)
    local attempt = takeAttempt('fakeplate', source, token)

    if not attempt then
        return { ok = false, message = locale('fakeplate_install_cancelled') }
    end

    if result ~= 'success' then
        return { ok = false, message = locale('fakeplate_install_cancelled') }
    end

    local vehicle = getVehicleFromNetId(attempt.netId)

    if vehicle == 0 then
        return { ok = false, message = locale('invalid_vehicle') }
    end

    if not isPlayerNearEntity(source, vehicle, (Config.FakePlates.Install.Distance or 2.5) + 1.0) then
        return { ok = false, message = locale('too_far') }
    end

    local state = getStateBag(vehicle)
    if state and state[Config.FakePlates.ActiveStatebag] then
        return { ok = false, message = locale('fakeplate_already_active') }
    end

    local realPlate = getVehicleRealPlate(vehicle)
    local access = resolveAccessState(source, realPlate)

    if Config.FakePlates.Install.RequireAccess and not access.any then
        return { ok = false, message = locale('no_keys') }
    end

    local sanitizedDisplayPlate = sanitizeFakePlateDisplay(displayPlate)

    if not sanitizedDisplayPlate then
        return { ok = false, message = locale('fakeplate_invalid_format') }
    end

    if not hasItem(source, Config.FakePlates.Items.FakePlate, 1) then
        return { ok = false, message = locale('fakeplate_need_fakeplate') }
    end

    if not hasItem(source, Config.FakePlates.Items.PlateKit, 1) then
        return { ok = false, message = locale('fakeplate_need_platekit') }
    end

    if not hasItem(source, Config.FakePlates.Items.Screwdriver, 1) then
        return { ok = false, message = locale('fakeplate_need_screwdriver') }
    end

    if Config.FakePlates.Install.RemoveFakePlateItem and not removeGenericItem(source, Config.FakePlates.Items.FakePlate, 1) then
        return { ok = false, message = locale('fakeplate_need_fakeplate') }
    end

    if Config.FakePlates.Install.RemovePlateKitItem and not removeGenericItem(source, Config.FakePlates.Items.PlateKit, 1) then
        if Config.FakePlates.Install.RemoveFakePlateItem then
            addGenericItem(source, Config.FakePlates.Items.FakePlate, 1)
        end

        return { ok = false, message = locale('fakeplate_need_platekit') }
    end

    state:set(Config.FakePlates.RealPlateStatebag, attempt.realPlate or realPlate, true)
    state:set(Config.FakePlates.DisplayPlateStatebag, sanitizedDisplayPlate, true)
    state:set(Config.FakePlates.ActiveStatebag, true, true)

    TriggerClientEvent('bullen_vehiclekeys:client:applyFakePlateState', -1, attempt.netId, true, sanitizedDisplayPlate, attempt.realPlate or realPlate)

    return {
        ok = true,
        realPlate = attempt.realPlate or realPlate,
        displayPlate = sanitizedDisplayPlate,
        message = locale('fakeplate_install_success', sanitizedDisplayPlate),
    }
end)

-- ============================================================================
-- Lockpick flow
-- ============================================================================

lib.callback.register('bullen_vehiclekeys:server:beginLockpick', function(source, data)
    if not Config.Lockpick.Enabled then
        return { ok = false, message = locale('lockpick_disabled') }
    end

    local netId = tonumber(data and data.netId)
    local vehicle = getVehicleFromNetId(netId)

    if vehicle == 0 then
        return { ok = false, message = locale('invalid_vehicle') }
    end

    if not isPlayerNearEntity(source, vehicle, Config.Lockpick.Distance + 1.0) then
        return { ok = false, message = locale('too_far') }
    end

    if Config.Lockpick.RequireItem and not hasItem(source, Config.Inventory.LockpickItem, 1) then
        return { ok = false, message = locale('need_lockpick') }
    end

    local plate = trimPlate(data and data.plate or GetVehicleNumberPlateText(vehicle))
    local access = resolveAccessState(source, plate)

    if access.any then
        return { ok = false, message = locale('already_have_access') }
    end

    local model = GetEntityModel(vehicle)

    if Config.Lockpick.BlacklistedModels and Config.Lockpick.BlacklistedModels[model] then
        return { ok = false, message = locale('vehicle_blacklisted') }
    end

    if access.ownerCitizenId and access.hasAlarm then
        notifyVehicleOwner(plate, 'owner_alarm_try')
    end

    local token = createAttempt('lockpick', source, {
        netId = netId,
        plate = plate,
    }, 30)

    return {
        ok = true,
        token = token,
        duration = Config.Lockpick.DurationMs,
    }
end)

lib.callback.register('bullen_vehiclekeys:server:finishLockpick', function(source, token, result)
    local attempt = takeAttempt('lockpick', source, token)

    if not attempt then
        return { ok = false, message = locale('invalid_vehicle') }
    end

    local vehicle = getVehicleFromNetId(attempt.netId)

    if vehicle == 0 then
        return { ok = false, message = locale('invalid_vehicle') }
    end

    if not isPlayerNearEntity(source, vehicle, Config.Lockpick.Distance + 1.0) then
        return { ok = false, message = locale('too_far') }
    end

    local access = resolveAccessState(source, attempt.plate)

    if access.any then
        return { ok = false, message = locale('already_have_access') }
    end

    local success = false
    local brokeLockpick = false
    local finalMessage = locale('lockpick_failed')

    if result == 'success' then
        success = math.random() <= Config.Lockpick.SuccessChance
        brokeLockpick = math.random() <= (success and Config.Lockpick.BreakChanceOnSuccess or Config.Lockpick.BreakChanceOnFail)
        finalMessage = success and locale('lockpick_success') or locale('lockpick_failed')
    elseif result == 'cancel' then
        brokeLockpick = math.random() <= Config.Lockpick.BreakChanceOnCancel
        finalMessage = locale('lockpick_cancelled')
    else
        brokeLockpick = math.random() <= Config.Lockpick.BreakChanceOnFail
        finalMessage = locale('lockpick_failed')
    end

    if brokeLockpick and Config.Lockpick.RequireItem then
        removeGenericItem(source, Config.Inventory.LockpickItem, 1)
    end

    if success then
        setVehicleState(attempt.netId, 'xvkUnlocked', true)
        setVehicleState(attempt.netId, 'xvkBreached', true)

        if access.ownerCitizenId and access.hasAlarm then
            notifyVehicleOwner(attempt.plate, 'owner_alarm_breach')
        end
    end

    local shouldAlarmFx = (success and Config.Alarms.TriggerOnLockpickSuccess) or ((not success) and Config.Alarms.TriggerOnLockpickFail)

    if shouldAlarmFx then
        TriggerClientEvent('bullen_vehiclekeys:client:playAlarmFx', -1, attempt.netId, Config.Alarms.AlarmDurationMs, Config.Alarms.HornDurationMs)
    end

    return {
        ok = success,
        brokeLockpick = brokeLockpick,
        message = finalMessage,
    }
end)

-- ============================================================================
-- Hotwire flow
-- ============================================================================

lib.callback.register('bullen_vehiclekeys:server:beginHotwire', function(source, data)
    if not Config.Hotwire.Enabled then
        return { ok = false, message = locale('hotwire_disabled') }
    end

    local netId = tonumber(data and data.netId)
    local vehicle = getVehicleFromNetId(netId)

    if vehicle == 0 then
        return { ok = false, message = locale('invalid_vehicle') }
    end

    local plate = trimPlate(data and data.plate or GetVehicleNumberPlateText(vehicle))
    local access = resolveAccessState(source, plate)

    if access.any then
        return { ok = false, message = locale('already_have_access') }
    end

    local state = getStateBag(vehicle)

    if Config.Hotwire.RequireBreachedVehicle and not (state and state.xvkBreached) then
        return { ok = false, message = locale('hotwire_requires_breach') }
    end

    local playerPed = GetPlayerPed(source)

    if GetVehiclePedIsIn(playerPed, false) ~= vehicle then
        return { ok = false, message = locale('not_in_vehicle') }
    end

    if GetPedInVehicleSeat(vehicle, -1) ~= playerPed then
        return { ok = false, message = locale('must_be_driver') }
    end

    local token = createAttempt('hotwire', source, {
        netId = netId,
        plate = plate,
    }, 30)

    return {
        ok = true,
        token = token,
        duration = Config.Hotwire.DurationMs,
    }
end)

lib.callback.register('bullen_vehiclekeys:server:finishHotwire', function(source, token, result)
    local attempt = takeAttempt('hotwire', source, token)

    if not attempt then
        return { ok = false, message = locale('invalid_vehicle') }
    end

    local vehicle = getVehicleFromNetId(attempt.netId)

    if vehicle == 0 then
        return { ok = false, message = locale('invalid_vehicle') }
    end

    local playerPed = GetPlayerPed(source)

    if GetVehiclePedIsIn(playerPed, false) ~= vehicle then
        return { ok = false, message = locale('not_in_vehicle') }
    end

    if GetPedInVehicleSeat(vehicle, -1) ~= playerPed then
        return { ok = false, message = locale('must_be_driver') }
    end

    local access = resolveAccessState(source, attempt.plate)

    if access.any then
        return { ok = false, message = locale('already_have_access') }
    end

    local success = false
    local finalMessage

    if result == 'success' then
        success = math.random() <= Config.Hotwire.SuccessChance
        finalMessage = success and locale('hotwire_success') or locale('hotwire_failed')
    elseif result == 'cancel' then
        finalMessage = locale('hotwire_cancelled')
    else
        finalMessage = locale('hotwire_failed')
    end

    if success then
        grantTemporaryAccess(source, attempt.plate, 'hotwire')
    end

    local newAccess = success and pushAccessUpdate(source, attempt.plate) or nil

    return {
        ok = success,
        access = newAccess,
        message = finalMessage,
    }
end)


lib.callback.register('bullen_vehiclekeys:server:completeCarjack', function(source, data)
    if not (Config.Carjacking and Config.Carjacking.Enabled) then
        return { ok = false }
    end

    local netId = tonumber(data and data.netId)
    local vehicle = getVehicleFromNetId(netId)

    if vehicle == 0 then
        return { ok = false, message = locale('invalid_vehicle') }
    end

    if not isPlayerNearEntity(source, vehicle, ((Config.Carjacking and Config.Carjacking.AimDistance) or 25.0) + 5.0) then
        return { ok = false, message = locale('too_far') }
    end

    local plate = trimPlate(data and data.plate or GetVehicleNumberPlateText(vehicle))
    if not plate then
        return { ok = false, message = locale('invalid_vehicle') }
    end

    local pedNetIds = data and data.pedNetIds or {}
    local registered = 0

    for i = 1, #pedNetIds do
        local pedNetId = tonumber(pedNetIds[i])

        if pedNetId then
            local ped = getPedFromNetId(pedNetId)

            if ped ~= 0 and DoesEntityExist(ped) and not IsPedAPlayer(ped) and isPlayerNearEntity(source, ped, ((Config.Carjacking and Config.Carjacking.AimDistance) or 25.0) + 10.0) then
                if setPedSearchState(pedNetId, {
                    plate = plate,
                    searched = false,
                    source = 'carjack',
                }) then
                    registered = registered + 1
                end
            end
        end
    end

    return {
        ok = registered > 0,
        registered = registered,
    }
end)

-- ============================================================================
-- Searchable NPC key retrieval
-- ============================================================================

lib.callback.register('bullen_vehiclekeys:server:retrieveNpcKey', function(source, pedNetId)
    local ped = getPedFromNetId(pedNetId)

    if ped == 0 then
        return { ok = false, message = locale('search_failed') }
    end

    if not isPlayerNearEntity(source, ped, Config.Target.NpcKeySearch.Distance + 1.0) then
        return { ok = false, message = locale('too_far') }
    end

    local state = getStateBag(ped)
    local searchData = state and state.xvkSearchableKey or nil

    if not searchData or searchData.searched then
        return { ok = false, message = locale('search_already_done') }
    end

    local health = GetEntityHealth(ped) or 0
    local dead = health <= 0

    if Config.SearchableNpcKeys.DeadOnly then
        if not dead then
            return { ok = false, message = locale('search_too_healthy') }
        end
    else
        if not dead and health > Config.SearchableNpcKeys.IncapacitatedHealthThreshold then
            return { ok = false, message = locale('search_too_healthy') }
        end
    end

    local plate = trimPlate(searchData.plate)

    if not plate then
        return { ok = false, message = locale('search_failed') }
    end

    if not addVehicleKeyItem(source, plate) then
        return { ok = false, message = locale('search_failed') }
    end

    searchData.searched = true
    state:set('xvkSearchableKey', searchData, true)
    pushAccessUpdate(source, plate)

    return {
        ok = true,
        plate = plate,
        message = locale('search_key_success', plate),
    }
end)

-- ============================================================================
-- Locksmith actions
-- ============================================================================

isNearLocksmith = function(source)
    local coords = getPlayerCoords(source)

    if not coords then
        return false
    end

    for _, location in ipairs(Config.Locksmith.Locations or {}) do
        local targetCoords = vec3(location.coords.x, location.coords.y, location.coords.z)

        if #(coords - targetCoords) <= Config.Locksmith.ServiceRadius then
            return true, location
        end
    end

    return false, nil
end

local function validateLocksmithVehicle(source, vehicleNetId, plate)
    local vehicle = getVehicleFromNetId(vehicleNetId)

    if vehicle == 0 then
        return nil, locale('invalid_vehicle')
    end

    local nearService, location = isNearLocksmith(source)

    if not nearService then
        return nil, locale('locksmith_no_location')
    end

    local vehicleCoords = GetEntityCoords(vehicle)
    local serviceCoords = vec3(location.coords.x, location.coords.y, location.coords.z)

    if #(vehicleCoords - serviceCoords) > Config.Locksmith.VehicleRadius then
        return nil, locale('locksmith_no_vehicle')
    end

    if not isPlayerNearEntity(source, vehicle, Config.Locksmith.VehicleRadius + 1.0) then
        return nil, locale('too_far')
    end

    plate = trimPlate(plate or GetVehicleNumberPlateText(vehicle))

    if not plate then
        return nil, locale('share_invalid_plate')
    end

    return {
        vehicle = vehicle,
        plate = plate,
        location = location,
    }, nil
end

RegisterNetEvent('bullen_vehiclekeys:server:copyKeyAtLocksmith', function(vehicleNetId, plate)
    local source = source

    if not Config.Locksmith.Enabled or not Config.Locksmith.CopyKey.Enabled then
        return
    end

    local context, errorMessage = validateLocksmithVehicle(source, vehicleNetId, plate)

    if not context then
        notify(source, 'error', errorMessage)
        return
    end

    local access = resolveAccessState(source, context.plate)

    if not access.owned then
        notify(source, 'error', locale('locksmith_not_owned'))
        return
    end

    if Config.Locksmith.CopyKey.RequireBlankKey and not hasItem(source, Config.Inventory.BlankKeyItem, 1) then
        notify(source, 'error', locale('locksmith_need_blank'))
        return
    end

    if not hasEnoughMoney(source, Config.Locksmith.CopyKey.MoneyAccount, Config.Locksmith.CopyKey.Cost) then
        notify(source, 'error', locale('not_enough_money'))
        return
    end

    if Config.Locksmith.CopyKey.RequireBlankKey then
        removeGenericItem(source, Config.Inventory.BlankKeyItem, 1)
    end

    removeMoney(source, Config.Locksmith.CopyKey.MoneyAccount, Config.Locksmith.CopyKey.Cost, 'bullen_vehiclekeys:copy_key')

    if not replaceVehicleKeyItem(source, context.plate, getCitizenId(source)) then
        notify(source, 'error', locale('search_failed'))
        return
    end

    pushAccessUpdate(source, context.plate)
    notify(source, 'success', locale('locksmith_copy_success', context.plate))
end)

RegisterNetEvent('bullen_vehiclekeys:server:installAlarmForOwnedVehicle', function(plate)
    local source = source

    if not Config.Locksmith.Enabled or not Config.Locksmith.Alarm.Enabled then
        return
    end

    local nearService = isNearLocksmith(source)

    if not nearService then
        notify(source, 'error', locale('locksmith_no_location'))
        return
    end

    plate = trimPlate(plate)

    if not plate then
        notify(source, 'error', locale('share_invalid_plate'))
        return
    end

    local access = resolveAccessState(source, plate)

    if not access.owned then
        notify(source, 'error', locale('locksmith_not_owned'))
        return
    end

    if hasAlarmInstalled(plate) then
        notify(source, 'error', locale('locksmith_alarm_exists'))
        return
    end

    if not hasEnoughMoney(source, Config.Locksmith.Alarm.MoneyAccount, Config.Locksmith.Alarm.Cost) then
        notify(source, 'error', locale('not_enough_money'))
        return
    end

    removeMoney(source, Config.Locksmith.Alarm.MoneyAccount, Config.Locksmith.Alarm.Cost, 'bullen_vehiclekeys:install_alarm')
    MySQL.insert.await('INSERT INTO bullen_vehiclekeys_alarms (plate, installed_by) VALUES (?, ?) ON DUPLICATE KEY UPDATE installed_by = VALUES(installed_by)', {
        plate,
        getCitizenId(source)
    })
    invalidateAlarmCache(plate)
    notify(source, 'success', locale('locksmith_alarm_success', plate))
end)

-- ============================================================================
-- Lock state / shared key actions
-- ============================================================================

RegisterNetEvent('bullen_vehiclekeys:server:toggleLocks', function(vehicleNetId, plate)
    local source = source
    local vehicle = getVehicleFromNetId(vehicleNetId)

    if vehicle == 0 then
        notify(source, 'error', locale('invalid_vehicle'))
        return
    end

    if not isPlayerNearEntity(source, vehicle, Config.General.NearestVehicleDistance + 2.0) then
        notify(source, 'error', locale('too_far'))
        return
    end

    plate = trimPlate(plate or GetVehicleNumberPlateText(vehicle))
    local access = resolveAccessState(source, plate)

    if not access.any then
        notify(source, 'error', locale('no_keys'))
        return
    end

    local state = getStateBag(vehicle)
    local newUnlockedState = not (state and state.xvkUnlocked == true)

    setVehicleState(vehicleNetId, 'xvkUnlocked', newUnlockedState)
    TriggerClientEvent('bullen_vehiclekeys:client:applyDoorState', -1, vehicleNetId, newUnlockedState)
    TriggerClientEvent('bullen_vehiclekeys:client:playLockToggleSound', source)
    notify(source, newUnlockedState and 'success' or 'inform', locale(newUnlockedState and 'lock_state_unlocked' or 'lock_state_locked'))
end)

RegisterNetEvent('bullen_vehiclekeys:server:shareKeys', function(targetId, plate)
    local source = source
    targetId = tonumber(targetId)
    plate = trimPlate(plate)

    if not targetId then
        notify(source, 'error', locale('no_player_nearby'))
        return
    end

    if targetId == source then
        notify(source, 'error', locale('cannot_target_self'))
        return
    end

    if not arePlayersNear(source, targetId, Config.SharedKeys.GiveDistance) then
        notify(source, 'error', locale('target_not_nearby'))
        return
    end

    if not plate then
        notify(source, 'error', locale('share_invalid_plate'))
        return
    end

    local access = resolveAccessState(source, plate)

    if not access.owned and not (Config.SharedKeys.AllowSharedHoldersToReshare and access.shared) then
        notify(source, 'error', locale('share_owner_only'))
        return
    end

    local ownerCitizenId = access.ownerCitizenId
    local targetCitizenId = getCitizenId(targetId)

    if not ownerCitizenId or not targetCitizenId then
        notify(source, 'error', locale('share_owner_only'))
        return
    end

    MySQL.insert.await('INSERT INTO bullen_vehiclekeys_shared (plate, owner_citizenid, shared_citizenid) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE owner_citizenid = VALUES(owner_citizenid)', {
        plate,
        ownerCitizenId,
        targetCitizenId,
    })
    invalidateSharedCache(plate)

    notify(source, 'success', locale('share_success'))
    notify(targetId, 'success', locale('share_received', getCharacterName(source), plate))
    pushAccessUpdate(targetId, plate)
end)

RegisterNetEvent('bullen_vehiclekeys:server:revokeKeys', function(targetId, plate)
    local source = source
    targetId = tonumber(targetId)
    plate = trimPlate(plate)

    if not targetId then
        notify(source, 'error', locale('no_player_nearby'))
        return
    end

    if targetId == source then
        notify(source, 'error', locale('cannot_target_self'))
        return
    end

    if not arePlayersNear(source, targetId, Config.SharedKeys.GiveDistance) then
        notify(source, 'error', locale('target_not_nearby'))
        return
    end

    if not plate then
        notify(source, 'error', locale('share_invalid_plate'))
        return
    end

    local access = resolveAccessState(source, plate)

    if not access.owned then
        notify(source, 'error', locale('share_owner_only'))
        return
    end

    local targetCitizenId = getCitizenId(targetId)

    if not targetCitizenId then
        return
    end

    MySQL.update.await('DELETE FROM bullen_vehiclekeys_shared WHERE plate = ? AND owner_citizenid = ? AND shared_citizenid = ?', {
        plate,
        access.ownerCitizenId,
        targetCitizenId,
    })
    invalidateSharedCache(plate)

    notify(source, 'success', locale('share_removed'))
    notify(targetId, 'error', locale('share_revoked', getCharacterName(source), plate))
    pushAccessUpdate(targetId, plate)
end)

-- ============================================================================
-- Exports / cleanup
-- ============================================================================

exports('HasAccess', function(source, plate)
    return resolveAccessState(source, plate).any
end)

exports('HasRealAccess', function(source, plate)
    local access = resolveAccessState(source, plate)
    return access.owned or access.shared or access.physical
end)

exports('GrantTemporaryAccess', function(source, plate, reason)
    local granted = grantTemporaryAccess(source, plate, reason)

    if granted then
        pushAccessUpdate(source, plate)
    end

    return granted
end)

exports('RevokeTemporaryAccess', function(source, plate)
    local revoked = revokeTemporaryAccess(source, plate)

    if revoked then
        pushAccessUpdate(source, plate)
    end

    return revoked
end)

exports('HasAlarmInstalled', function(plate)
    return hasAlarmInstalled(plate)
end)

exports('EnsurePhysicalKey', function(source, plate)
    local added = addVehicleKeyItem(source, plate, { skipIfExists = true })

    if added then
        pushAccessUpdate(source, plate)
    end

    return added
end)

exports('ReplacePhysicalKey', function(source, plate)
    local replaced = replaceVehicleKeyItem(source, plate)

    if replaced then
        pushAccessUpdate(source, plate)
    end

    return replaced
end)

AddEventHandler('playerDropped', function()
    local source = source

    if Config.TemporaryStolen.ClearOnDrop then
        SessionAccess[source] = nil
    end
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    debugPrint('Resource started.')
end)
