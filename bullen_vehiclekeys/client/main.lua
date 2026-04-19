local QBCore = exports['qb-core']:GetCoreObject()
lib.locale()

-- ============================================================================
-- Client state
-- ============================================================================

local AccessCache = {}
local ProtectionCache = {}
local HotwireActive = false
local HotwireCooldown = {}
local HotwireVehicle = 0
local LocksmithPeds = {}
local TextUiVisible = false
local CurrentTextUiMessage = nil

local function playLockToggleSound()
    SendNUIMessage({
        action = 'playLockToggleSound',
        volume = 1.0
    })
end

local LockpickMinigameBackends = {
    burevestnik = {
        resource = 'Burevestnik_lockpick_minigame',
        export = 'Burevestnik_lockpick_minigame_start',
    },
    lockpick = {
        resource = 'lockpick',
        export = 'startLockpick',
        tries = 3,
    },
}

local function getConfiguredLockpickMinigameType()
    local minigame = Config.Lockpick and Config.Lockpick.Minigame

    if type(minigame) == 'string' then
        return minigame
    end

    if type(minigame) == 'table' then
        return minigame.Type or 'none'
    end

    return 'none'
end


CreateThread(function()
    local minigameType = getConfiguredLockpickMinigameType()

    if minigameType == 'burevestnik' then
        local resourceName = LockpickMinigameBackends.burevestnik.resource

        if GetResourceState(resourceName) ~= 'started' then
            print(('[bullen_vehiclekeys] WARNING: Lockpick backend is set to Burevestnik, but resource "%s" is not started.'):format(resourceName))
        end
    elseif minigameType == 'lockpick' then
        local resourceName = LockpickMinigameBackends.lockpick.resource

        if GetResourceState(resourceName) ~= 'started' then
            print(('[bullen_vehiclekeys] WARNING: Lockpick backend is set to lockpick, but resource "%s" is not started.'):format(resourceName))
        end
    elseif minigameType == 'ox_lib_skillcheck' then
        if not lib then
            print('[bullen_vehiclekeys] WARNING: Lockpick backend is set to ox_lib_skillcheck, but ox_lib is not available.')
        end
    end
end)

local CarjackProcessedVehicles = {}
local CarjackVehicleReactions = {}
local CarjackAimState = {
    vehicle = nil,
    startedAt = 0
}

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

local function notify(notifType, message)
    lib.notify({
        title = 'Vehicle Keys',
        description = message,
        type = notifType or 'inform',
        position = Config.General.NotifyPosition,
    })
end

local function showTextUi(message)
    if TextUiVisible and CurrentTextUiMessage == message then
        return
    end

    if TextUiVisible then
        lib.hideTextUI()
    end

    lib.showTextUI(message)
    TextUiVisible = true
    CurrentTextUiMessage = message
end

local function hideTextUi()
    if TextUiVisible then
        lib.hideTextUI()
        TextUiVisible = false
        CurrentTextUiMessage = nil
    end
end

local function ensureNetId(entity)
    if entity == 0 or not DoesEntityExist(entity) then
        return nil
    end

    if not NetworkGetEntityIsNetworked(entity) then
        NetworkRegisterEntityAsNetworked(entity)
    end

    local netId = NetworkGetNetworkIdFromEntity(entity)

    if netId == 0 then
        return nil
    end

    SetNetworkIdCanMigrate(netId, true)
    return netId
end

local function getVehicleState(vehicle)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return nil
    end

    return Entity(vehicle).state
end

local function resolveVehiclePlate(vehicle)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return nil, nil, false
    end

    local state = getVehicleState(vehicle)

    if Config.FakePlates.Enabled and state and state[Config.FakePlates.ActiveStatebag] and state[Config.FakePlates.RealPlateStatebag] then
        local realPlate = trimPlate(state[Config.FakePlates.RealPlateStatebag])
        local displayPlate = trimPlate(state[Config.FakePlates.DisplayPlateStatebag] or GetVehicleNumberPlateText(vehicle))
        return realPlate, displayPlate or realPlate, true
    end

    local plate = trimPlate(GetVehicleNumberPlateText(vehicle))
    return plate, plate, false
end

local function cacheAccess(plate, access)
    plate = trimPlate(plate)

    if not plate or not access then
        return
    end

    AccessCache[plate] = {
        data = access,
        expiresAt = GetGameTimer() + (Config.General.AccessCacheMs or 15000),
    }
end

local function getCachedAccess(plate)
    plate = trimPlate(plate)

    if not plate then
        return nil
    end

    local cacheEntry = AccessCache[plate]

    if cacheEntry and cacheEntry.expiresAt > GetGameTimer() then
        return cacheEntry.data
    end

    return nil
end

local function cacheProtection(plate, owned)
    plate = trimPlate(plate)

    if not plate then
        return
    end

    ProtectionCache[plate] = {
        owned = owned == true,
        expiresAt = GetGameTimer() + (Config.NpcLockNormalization.ProtectedPlateCacheMs or 60000),
    }
end

local function isPlateProtected(plate)
    plate = trimPlate(plate)

    if not plate then
        return false
    end

    local cacheEntry = ProtectionCache[plate]

    if cacheEntry and cacheEntry.expiresAt > GetGameTimer() then
        return cacheEntry.owned == true
    end

    return false
end

local function getClosestVehicle(coords, maxDistance)
    local closestVehicle = 0
    local closestDistance = maxDistance or Config.General.NearestVehicleDistance
    local vehicles = GetGamePool('CVehicle')

    for _, vehicle in ipairs(vehicles) do
        if DoesEntityExist(vehicle) then
            local distance = #(GetEntityCoords(vehicle) - coords)

            if distance <= closestDistance then
                closestDistance = distance
                closestVehicle = vehicle
            end
        end
    end

    return closestVehicle, closestDistance
end

local function getVehicleInFront(maxDistance)
    local ped = PlayerPedId()
    local startCoords = GetEntityCoords(ped)
    local forward = GetEntityForwardVector(ped)
    local endCoords = startCoords + (forward * (maxDistance or 4.0))
    local ray = StartShapeTestRay(startCoords.x, startCoords.y, startCoords.z + 0.6, endCoords.x, endCoords.y, endCoords.z + 0.6, 10, ped, 0)
    local _, hit, _, _, entityHit = GetShapeTestResult(ray)

    if hit == 1 and entityHit ~= 0 and DoesEntityExist(entityHit) and GetEntityType(entityHit) == 2 then
        return entityHit
    end

    return 0
end

local function getClosestPlayer(maxDistance)
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local closestPlayer = nil
    local closestDistance = maxDistance or Config.General.NearestPlayerDistance

    for _, player in ipairs(GetActivePlayers()) do
        if player ~= PlayerId() then
            local targetPed = GetPlayerPed(player)

            if targetPed ~= 0 and DoesEntityExist(targetPed) then
                local distance = #(GetEntityCoords(targetPed) - myCoords)

                if distance <= closestDistance then
                    closestDistance = distance
                    closestPlayer = GetPlayerServerId(player)
                end
            end
        end
    end

    return closestPlayer, closestDistance
end

local function applyDoorState(vehicle, unlocked)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return
    end

    SetVehicleDoorsLocked(vehicle, unlocked and 1 or 2)
    SetVehicleDoorsLockedForAllPlayers(vehicle, not unlocked)
end


local function applyLocalPlayerVehicleEntryLock(vehicle, locked)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return
    end

    SetVehicleDoorsLockedForPlayer(vehicle, PlayerId(), locked == true)
end

local function isNpcPed(ped)
    return ped ~= 0
        and DoesEntityExist(ped)
        and IsEntityAPed(ped)
        and not IsPedAPlayer(ped)
        and not IsPedDeadOrDying(ped, true)
end

local function isAllowedCarjackWeapon()
    if not (Config.Carjacking and Config.Carjacking.Enabled) then
        return false
    end

    local weapon = GetSelectedPedWeapon(PlayerPedId())
    return Config.Carjacking.AllowedWeapons and Config.Carjacking.AllowedWeapons[weapon] == true
end

local function isVehicleModelAllowedForCarjack(vehicle)
    if vehicle == 0 or not DoesEntityExist(vehicle) or not IsEntityAVehicle(vehicle) then
        return false
    end

    local model = GetEntityModel(vehicle)
    if IsThisModelABicycle(model) or IsThisModelABike(model) then
        return false
    end

    return true
end

local function isValidNpcDriver(driver)
    return isNpcPed(driver) and IsPedInAnyVehicle(driver, false)
end

local function isThreatReactableVehicle(vehicle)
    if not isVehicleModelAllowedForCarjack(vehicle) then
        return false
    end

    local driver = GetPedInVehicleSeat(vehicle, -1)
    return isValidNpcDriver(driver)
end

local function markCarjackProcessed(vehicle)
    CarjackProcessedVehicles[vehicle] = GetGameTimer() + (Config.Carjacking.ReactionCooldown or 12000)
end

local function isCarjackProcessed(vehicle)
    local expires = CarjackProcessedVehicles[vehicle]
    if not expires then return false end
    if expires <= GetGameTimer() then
        CarjackProcessedVehicles[vehicle] = nil
        CarjackVehicleReactions[vehicle] = nil
        return false
    end
    return true
end

local function clearCarjackAimState()
    CarjackAimState.vehicle = nil
    CarjackAimState.startedAt = 0
end

local function rotationToDirection(rot)
    local rotZ = math.rad(rot.z)
    local rotX = math.rad(rot.x)
    local cosX = math.abs(math.cos(rotX))
    return vector3(-math.sin(rotZ) * cosX, math.cos(rotZ) * cosX, math.sin(rotX))
end

local function raycastFromCamera(distance)
    local camRot = GetGameplayCamRot(2)
    local camCoord = GetGameplayCamCoord()
    local direction = rotationToDirection(camRot)
    local destination = camCoord + (direction * distance)

    local ray = StartShapeTestRay(
        camCoord.x, camCoord.y, camCoord.z,
        destination.x, destination.y, destination.z,
        10,
        PlayerPedId(),
        0
    )

    local _, hit, _, _, entityHit = GetShapeTestResult(ray)
    if hit == 1 and entityHit ~= 0 and DoesEntityExist(entityHit) then
        return entityHit
    end

    return 0
end

local function getCarjackTargetVehicle()
    local playerPed = PlayerPedId()
    local playerId = PlayerId()

    if IsPedInAnyVehicle(playerPed, false) then
        return nil
    end

    if not isAllowedCarjackWeapon() or not IsPlayerFreeAiming(playerId) then
        return nil
    end

    local entity = 0
    local aimed, aimedEntity = GetEntityPlayerIsFreeAimingAt(playerId)
    if aimed and aimedEntity ~= 0 and DoesEntityExist(aimedEntity) then
        entity = aimedEntity
    else
        entity = raycastFromCamera((Config.Carjacking and Config.Carjacking.AimDistance) or 25.0)
    end

    if entity == 0 then
        return nil
    end

    local vehicle = 0

    if IsEntityAVehicle(entity) then
        vehicle = entity
    elseif IsEntityAPed(entity) and IsPedInAnyVehicle(entity, false) then
        vehicle = GetVehiclePedIsIn(entity, false)
    else
        return nil
    end

    if vehicle == 0 or not isThreatReactableVehicle(vehicle) then
        return nil
    end

    local playerCoords = GetEntityCoords(playerPed)
    local vehicleCoords = GetEntityCoords(vehicle)
    if #(playerCoords - vehicleCoords) > ((Config.Carjacking and Config.Carjacking.AimDistance) or 25.0) then
        return nil
    end

    return vehicle
end

local function getVehicleOccupants(vehicle)
    local occupants = {}
    local maxPassengers = GetVehicleMaxNumberOfPassengers(vehicle)

    local driver = GetPedInVehicleSeat(vehicle, -1)
    if isNpcPed(driver) then
        occupants[#occupants + 1] = { ped = driver, seat = -1, isDriver = true }
    end

    for seat = 0, maxPassengers do
        local ped = GetPedInVehicleSeat(vehicle, seat)
        if isNpcPed(ped) then
            occupants[#occupants + 1] = { ped = ped, seat = seat, isDriver = false }
        end
    end

    return occupants
end

local CarjackHostileRelationship = nil

local function ensureCarjackHostileRelationship()
    if CarjackHostileRelationship then
        return CarjackHostileRelationship
    end

    local group = GetHashKey('xvk_carjack_hostile')
    AddRelationshipGroup('xvk_carjack_hostile')
    CarjackHostileRelationship = group

    SetRelationshipBetweenGroups(5, group, `PLAYER`)
    SetRelationshipBetweenGroups(5, `PLAYER`, group)

    return CarjackHostileRelationship
end

local function preparePedForReaction(ped)
    local hostileGroup = ensureCarjackHostileRelationship()

    SetPedRelationshipGroupHash(ped, hostileGroup)
    SetBlockingOfNonTemporaryEvents(ped, true)
    TaskSetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    SetPedCanRagdoll(ped, true)
    SetPedAsEnemy(ped, true)
    SetCanAttackFriendly(ped, true, false)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCombatAttributes(ped, 5, true)
    SetPedCombatAttributes(ped, 13, true)
    SetPedCombatAttributes(ped, 21, true)
    SetPedCombatAttributes(ped, 46, true)
    SetPedCombatAbility(ped, 2)
    SetPedAlertness(ped, 3)
    SetPedSeeingRange(ped, 120.0)
    SetPedHearingRange(ped, 120.0)
end

local function leaveVehicleForced(ped, vehicle)
    if not DoesEntityExist(ped) or not DoesEntityExist(vehicle) then return end

    ClearPedTasks(ped)
    TaskLeaveVehicle(ped, vehicle, 0)

    local timeout = GetGameTimer() + 2500
    while GetGameTimer() < timeout do
        if not IsPedInAnyVehicle(ped, false) then
            return true
        end
        Wait(50)
    end

    if IsPedInAnyVehicle(ped, false) then
        ClearPedTasksImmediately(ped)
        TaskLeaveVehicle(ped, vehicle, 16)
        Wait(100)
    end

    return not IsPedInAnyVehicle(ped, false)
end

local function reinforceFlee(ped, playerPed)
    CreateThread(function()
        local untilTime = GetGameTimer() + ((Config.Carjacking and Config.Carjacking.FleeReinforceTime) or 8000)

        while GetGameTimer() < untilTime do
            if not DoesEntityExist(ped) or IsPedDeadOrDying(ped, true) then
                break
            end

            if IsPedInAnyVehicle(ped, false) then
                leaveVehicleForced(ped, GetVehiclePedIsIn(ped, false))
            end

            preparePedForReaction(ped)
            TaskSmartFleePed(ped, playerPed, (Config.Carjacking and Config.Carjacking.FleeDistance) or 150.0, -1, false, false)
            SetPedFleeAttributes(ped, 0, true)

            Wait(700)
        end
    end)
end

local function pickAttackWeapon()
    local totalWeight = 0

    for i = 1, #(Config.Carjacking.AttackWeapons or {}) do
        local entry = Config.Carjacking.AttackWeapons[i]
        local weight = entry.weight or 0
        if weight > 0 then
            totalWeight = totalWeight + weight
        end
    end

    if totalWeight <= 0 then
        return `WEAPON_PISTOL`, 250, 'ranged'
    end

    local roll = math.random(1, totalWeight)
    local running = 0

    for i = 1, #Config.Carjacking.AttackWeapons do
        local entry = Config.Carjacking.AttackWeapons[i]
        local weight = entry.weight or 0
        if weight > 0 then
            running = running + weight
            if roll <= running then
                return entry.weapon, entry.ammo or 250, entry.type or 'ranged'
            end
        end
    end

    return `WEAPON_PISTOL`, 250, 'ranged'
end

local function setupRangedCombatPed(ped, playerPed, weapon, ammo)
    RemoveAllPedWeapons(ped, true)
    GiveWeaponToPed(ped, weapon, ammo, false, true)
    preparePedForReaction(ped)
    SetCurrentPedWeapon(ped, weapon, true)
    SetPedDropsWeaponsWhenDead(ped, false)
    SetPedCombatMovement(ped, 2)
    SetPedCombatRange(ped, 2)
    SetPedAccuracy(ped, math.random((Config.Carjacking and Config.Carjacking.FightAccuracyMin) or 35, (Config.Carjacking and Config.Carjacking.FightAccuracyMax) or 60))
    ClearPedTasksImmediately(ped)
    TaskCombatPed(ped, playerPed, 0, 16)
end

local function reinforceMeleeAttack(ped, playerPed, weapon)
    CreateThread(function()
        local untilTime = GetGameTimer() + ((Config.Carjacking and Config.Carjacking.MeleeChaseTime) or 10000)
        local attackDistance = ((Config.Carjacking and Config.Carjacking.MeleeAttackDistance) or 2.2)
        local runSpeed = ((Config.Carjacking and Config.Carjacking.MeleeRunSpeed) or 3.0)
        local repathInterval = ((Config.Carjacking and Config.Carjacking.MeleeRepathInterval) or 600)

        while GetGameTimer() < untilTime do
            if not DoesEntityExist(ped) or not DoesEntityExist(playerPed) or IsPedDeadOrDying(ped, true) then
                break
            end

            if IsPedInAnyVehicle(ped, false) then
                leaveVehicleForced(ped, GetVehiclePedIsIn(ped, false))
                Wait(150)
            end

            preparePedForReaction(ped)
            SetCurrentPedWeapon(ped, weapon, true)
            SetPedCombatMovement(ped, 3)
            SetPedCombatRange(ped, 0)
            SetPedMaxMoveBlendRatio(ped, runSpeed)

            local pedCoords = GetEntityCoords(ped)
            local playerCoords = GetEntityCoords(playerPed)
            local dist = #(pedCoords - playerCoords)

            if dist > attackDistance + 0.75 then
                ClearPedTasks(ped)
                TaskGoToEntity(ped, playerPed, -1, attackDistance, runSpeed, 0.0, 0)
            else
                ClearPedTasks(ped)
                TaskPutPedDirectlyIntoMelee(ped, playerPed, 0.0, -1.0, 0.0, 0)
            end

            TaskCombatHatedTargetsAroundPed(ped, 60.0, 0)
            Wait(repathInterval)
        end

        if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
            ClearPedTasks(ped)
            TaskCombatPed(ped, playerPed, 0, 16)
        end
    end)
end

local function setupMeleeCombatPed(ped, playerPed, weapon)
    RemoveAllPedWeapons(ped, true)
    GiveWeaponToPed(ped, weapon, 1, false, true)
    preparePedForReaction(ped)
    SetCurrentPedWeapon(ped, weapon, true)
    SetPedDropsWeaponsWhenDead(ped, false)
    SetPedCombatMovement(ped, 3)
    SetPedCombatRange(ped, 0)
    ClearPedTasksImmediately(ped)
    TaskCombatPed(ped, playerPed, 0, 16)

    reinforceMeleeAttack(ped, playerPed, weapon)
end

local function setupCombatPed(ped, playerPed)
    local weapon, ammo, weaponType = pickAttackWeapon()

    if weaponType == 'melee' then
        setupMeleeCombatPed(ped, playerPed, weapon)
    else
        setupRangedCombatPed(ped, playerPed, weapon, ammo)
    end
end

local function registerCarjackKeyCarriers(vehicle, occupants)
    local plate = select(1, resolveVehiclePlate(vehicle))
    local netId = ensureNetId(vehicle)

    if not plate or not netId then
        return nil
    end

    local pedNetIds = {}

    for i = 1, #(occupants or {}) do
        local ped = occupants[i].ped
        if ped and ped ~= 0 and DoesEntityExist(ped) and not IsPedAPlayer(ped) then
            local pedNetId = ensureNetId(ped)
            if pedNetId then
                pedNetIds[#pedNetIds + 1] = pedNetId
            end
        end
    end

    if #pedNetIds == 0 then
        return nil
    end

    return lib.callback.await('bullen_vehiclekeys:server:completeCarjack', false, {
        plate = plate,
        netId = netId,
        pedNetIds = pedNetIds,
    })
end

local function getAheadTarget(vehicle)
    local coords = GetEntityCoords(vehicle)
    local fwd = GetEntityForwardVector(vehicle)
    return coords + (fwd * ((Config.Carjacking and Config.Carjacking.DriveAwayTargetDistance) or 140.0))
end

local function reinforceCommitPush(driver, vehicle)
    CreateThread(function()
        local untilTime = GetGameTimer() + ((Config.Carjacking and Config.Carjacking.DriveAwayCommitDuration) or 1200)
        while GetGameTimer() < untilTime do
            if not DoesEntityExist(driver) or not DoesEntityExist(vehicle) or IsPedDeadOrDying(driver, true) then
                break
            end

            if GetPedInVehicleSeat(vehicle, -1) == driver then
                SetVehicleForwardSpeed(vehicle, (Config.Carjacking and Config.Carjacking.DriveAwayCommitMinSpeed) or 12.0)
            end

            Wait((Config.Carjacking and Config.Carjacking.DriveAwayCommitInterval) or 200)
        end
    end)
end

local function reinforceNaturalDriveAway(driver, vehicle)
    CreateThread(function()
        local untilTime = GetGameTimer() + ((Config.Carjacking and Config.Carjacking.DriveAwayRetaskTime) or 6000)

        while GetGameTimer() < untilTime do
            if not DoesEntityExist(driver) or not DoesEntityExist(vehicle) or IsPedDeadOrDying(driver, true) then
                break
            end

            if Config.Carjacking.DriveAwayReseatDriver and GetPedInVehicleSeat(vehicle, -1) ~= driver then
                SetPedIntoVehicle(driver, vehicle, -1)
                Wait(50)
            end

            if GetPedInVehicleSeat(vehicle, -1) == driver then
                local target = getAheadTarget(vehicle)
                preparePedForReaction(driver)
                ClearPedSecondaryTask(driver)
                TaskVehicleDriveToCoordLongrange(
                    driver,
                    vehicle,
                    target.x, target.y, target.z,
                    Config.Carjacking.DriveAwaySpeed,
                    Config.Carjacking.DriveAwayStyle,
                    Config.Carjacking.DriveAwayStopRange
                )
            end

            Wait(Config.Carjacking.DriveAwayRetaskInterval)
        end
    end)
end

local function doDriveAway(vehicle, occupants)
    SetVehicleDoorsLocked(vehicle, 2)

    for i = 1, #occupants do
        local occ = occupants[i]
        if occ.isDriver and DoesEntityExist(occ.ped) then
            if Config.Carjacking.DriveAwayReseatDriver and GetPedInVehicleSeat(vehicle, -1) ~= occ.ped then
                SetPedIntoVehicle(occ.ped, vehicle, -1)
                Wait(50)
            end

            if GetPedInVehicleSeat(vehicle, -1) == occ.ped then
                local target = getAheadTarget(vehicle)
                preparePedForReaction(occ.ped)
                ClearPedSecondaryTask(occ.ped)
                TaskVehicleDriveToCoordLongrange(
                    occ.ped,
                    vehicle,
                    target.x, target.y, target.z,
                    Config.Carjacking.DriveAwaySpeed,
                    Config.Carjacking.DriveAwayStyle,
                    Config.Carjacking.DriveAwayStopRange
                )
                reinforceCommitPush(occ.ped, vehicle)
                reinforceNaturalDriveAway(occ.ped, vehicle)
            end
        end
    end
end

local function doSurrender(vehicle, occupants, playerPed)
    local driver = GetPedInVehicleSeat(vehicle, -1)
    if driver ~= 0 then
        ClearPedTasks(driver)
        TaskVehicleTempAction(driver, vehicle, 27, Config.Carjacking.VehicleStopTimeout)
    end

    CreateThread(function()
        local timeout = GetGameTimer() + Config.Carjacking.VehicleStopTimeout
        while GetGameTimer() < timeout do
            if not DoesEntityExist(vehicle) then
                return
            end

            if GetEntitySpeed(vehicle) <= 1.2 then
                break
            end

            Wait(75)
        end

        SetVehicleDoorsLocked(vehicle, 1)

        for i = 1, #occupants do
            local ped = occupants[i].ped
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                leaveVehicleForced(ped, vehicle)
            end
        end

        Wait(350)

        for i = 1, #occupants do
            local ped = occupants[i].ped
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                ClearPedTasksImmediately(ped)
                preparePedForReaction(ped)
                TaskHandsUp(ped, 1200, playerPed, -1, true)
            end
        end

        Wait(1000)

        for i = 1, #occupants do
            local ped = occupants[i].ped
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                reinforceFlee(ped, playerPed)
            end
        end
    end)
end

local function doFight(vehicle, occupants, playerPed)
    local driver = GetPedInVehicleSeat(vehicle, -1)
    if driver ~= 0 then
        ClearPedTasks(driver)
        TaskVehicleTempAction(driver, vehicle, 27, 2200)
    end

    CreateThread(function()
        local timeout = GetGameTimer() + 2200
        while GetGameTimer() < timeout do
            if not DoesEntityExist(vehicle) then
                return
            end

            if GetEntitySpeed(vehicle) <= 1.2 then
                break
            end

            Wait(50)
        end

        SetVehicleDoorsLocked(vehicle, 1)

        for i = 1, #occupants do
            local ped = occupants[i].ped
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                leaveVehicleForced(ped, vehicle)
            end
        end

        Wait(350)

        for i = 1, #occupants do
            local ped = occupants[i].ped
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                setupCombatPed(ped, playerPed)
            end
        end
    end)
end

local function getEnabledReactionWeight(name)
    if not Config.Carjacking.EnableReactions[name] then
        return 0
    end

    local weight = Config.Carjacking.ReactionWeights[name] or 0
    if weight < 0 then
        weight = 0
    end

    return weight
end

local function pickCarjackReaction()
    local choices = {
        { name = 'driveaway', weight = getEnabledReactionWeight('DriveAway') },
        { name = 'surrender', weight = getEnabledReactionWeight('Surrender') },
        { name = 'fight', weight = getEnabledReactionWeight('Fight') },
    }

    local totalWeight = 0
    for i = 1, #choices do
        totalWeight = totalWeight + choices[i].weight
    end

    if totalWeight <= 0 then
        return 'surrender'
    end

    local roll = math.random(1, totalWeight)
    local running = 0

    for i = 1, #choices do
        running = running + choices[i].weight
        if roll <= running then
            return choices[i].name
        end
    end

    return choices[#choices].name
end

local function handleCarjackReaction(vehicle)
    if isCarjackProcessed(vehicle) then return end
    markCarjackProcessed(vehicle)

    local occupants = getVehicleOccupants(vehicle)
    if #occupants == 0 then
        return
    end

    registerCarjackKeyCarriers(vehicle, occupants)

    local reaction = pickCarjackReaction()
    CarjackVehicleReactions[vehicle] = reaction

    local playerPed = PlayerPedId()

    if reaction == 'driveaway' then
        doDriveAway(vehicle, occupants)
    elseif reaction == 'surrender' then
        doSurrender(vehicle, occupants, playerPed)
    elseif reaction == 'fight' then
        doFight(vehicle, occupants, playerPed)
    else
        doSurrender(vehicle, occupants, playerPed)
    end
end

local function checkCarjackAttempt()
    if not (Config.Carjacking and Config.Carjacking.Enabled) then
        clearCarjackAimState()
        return
    end

    local vehicle = getCarjackTargetVehicle()
    if not vehicle or isCarjackProcessed(vehicle) then
        clearCarjackAimState()
        return
    end

    if CarjackAimState.vehicle ~= vehicle then
        CarjackAimState.vehicle = vehicle
        CarjackAimState.startedAt = GetGameTimer()
        return
    end

    if GetGameTimer() - CarjackAimState.startedAt >= Config.Carjacking.RequiredAimTime then
        handleCarjackReaction(vehicle)
        clearCarjackAimState()
    end
end

local function getVehicleRearWorldPosition(vehicle)
    local minDim, maxDim = GetModelDimensions(GetEntityModel(vehicle))
    return GetOffsetFromEntityInWorldCoords(vehicle, 0.0, minDim.y - 0.2, math.max(0.1, minDim.z + ((maxDim.z - minDim.z) * 0.35)))
end

local function isNearVehicleRear(vehicle, maxDistance)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return false
    end

    local pedCoords = GetEntityCoords(PlayerPedId())
    local rearCoords = getVehicleRearWorldPosition(vehicle)
    return #(pedCoords - rearCoords) <= (maxDistance or (Config.Target.FakePlateInstall and Config.Target.FakePlateInstall.RearDistance) or 1.6)
end

local function promptFakePlateText()
    local textConfig = Config.FakePlates.Install.TextEntry or {}

    AddTextEntry('XVK_FAKEPLATE_ENTRY', locale('fakeplate_input_instruction'))
    DisplayOnscreenKeyboard(1, 'XVK_FAKEPLATE_ENTRY', '', '', '', '', '', (textConfig.MaxLetters or 3) + (textConfig.MaxNumbers or 3))

    while UpdateOnscreenKeyboard() == 0 do
        DisableAllControlActions(0)
        Wait(0)
    end

    EnableAllControlActions(0)

    if GetOnscreenKeyboardResult() then
        local result = tostring(GetOnscreenKeyboardResult()):upper()
        result = result:gsub('%s+', '')
        result = result:gsub('[^A-Z0-9]', '')

        local maxLetters = textConfig.MaxLetters or 3
        local maxNumbers = textConfig.MaxNumbers or 3

        local letters = result:match('^([A-Z]+)')
        local numbers = result:match('([0-9]+)$')

        if letters and numbers and (#letters >= 1 and #letters <= maxLetters) and (#numbers >= 1 and #numbers <= maxNumbers) and (#letters + #numbers == #result) then
            return letters .. numbers
        end

        notify('error', locale('fakeplate_invalid_format'))
        return nil
    end

    return nil
end

local function applyFakePlateDisplay(vehicle)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return
    end

    local state = getVehicleState(vehicle)

    if not state or not Config.FakePlates.Enabled then
        return
    end

    if state[Config.FakePlates.ActiveStatebag] and state[Config.FakePlates.DisplayPlateStatebag] then
        SetVehicleNumberPlateText(vehicle, tostring(state[Config.FakePlates.DisplayPlateStatebag]))
    elseif state[Config.FakePlates.RealPlateStatebag] then
        SetVehicleNumberPlateText(vehicle, tostring(state[Config.FakePlates.RealPlateStatebag]))
    end
end

local function flashVehicleLights(vehicle)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return
    end

    SetVehicleLights(vehicle, 2)
    Wait(120)
    SetVehicleLights(vehicle, 0)
    Wait(120)
    SetVehicleLights(vehicle, 2)
    Wait(120)
    SetVehicleLights(vehicle, 0)
end

local function requestVehicleAccess(vehicle)
    local plate = select(1, resolveVehiclePlate(vehicle))
    local netId = ensureNetId(vehicle)

    if not plate or not netId then
        return nil
    end

    local access = lib.callback.await('bullen_vehiclekeys:server:getVehicleAccess', false, {
        plate = plate,
        netId = netId,
    })

    if access then
        cacheAccess(plate, access)
    end

    return access
end

local function runOxLibSkillCheck(skillConfig)
    if not skillConfig or skillConfig.Enabled == false then
        return true
    end

    Wait((skillConfig.StartDelayMs or 150))

    local difficulties = skillConfig.Difficulties or { 'medium' }
    local inputs = skillConfig.Inputs

    if not inputs or #inputs == 0 then
        inputs = { 'e', 'e', 'e' }
    end

    local passed = lib.skillCheck(difficulties, inputs)

    if passed == nil then
        return false
    end

    return passed == true
end

local function runBurevestnikMinigame()
    local backend = LockpickMinigameBackends.burevestnik
    local resourceName = backend.resource

    if GetResourceState(resourceName) ~= 'started' then
        return nil, 'resource_missing'
    end

    local ok, result = pcall(function()
        return exports[resourceName][backend.export]()
    end)

    if not ok then
        return nil, 'export_failed'
    end

    return result == true, nil
end

local function runLockpickMinigame()
    local backend = LockpickMinigameBackends.lockpick
    local resourceName = backend.resource

    if GetResourceState(resourceName) ~= 'started' then
        return nil, 'resource_missing'
    end

    local ok, result = pcall(function()
        return exports[resourceName][backend.export](backend.tries)
    end)

    if not ok then
        return nil, 'export_failed'
    end

    return result == true, nil
end

local function runConfiguredInteraction(configSection, localeFallback)
    -- Hotwire now supports progressbar-only mode by setting SkillCheck.Enabled = false in config.
    local interactionResult = 'success'
    local minigameSetting = configSection.Minigame
    local minigameType

    if type(minigameSetting) == 'string' then
        minigameType = minigameSetting
    elseif type(minigameSetting) == 'table' then
        minigameType = minigameSetting.Type
    else
        minigameType = nil
    end

    minigameType = minigameType or ((configSection.SkillCheck and configSection.SkillCheck.Enabled) and 'ox_lib_skillcheck' or 'none')

    if minigameType == 'burevestnik' then
        local passed, err = runBurevestnikMinigame()

        if passed == nil then
            notify('error', ('Configured Burevestnik minigame is unavailable: %s'):format(err or 'unknown'))
            interactionResult = 'cancel'
        elseif passed == false then
            interactionResult = 'fail'
        end
    elseif minigameType == 'ox_lib_skillcheck' then
        local passed = runOxLibSkillCheck(configSection.SkillCheck)

        if passed == false then
            interactionResult = 'fail'
        end
    elseif minigameType == 'lockpick' then
        local passed, err = runLockpickMinigame()

        if passed == nil then
            notify('error', ('Configured lockpick minigame is unavailable: %s'):format(err or 'unknown'))
            interactionResult = 'cancel'
        elseif passed == false then
            interactionResult = 'fail'
        end
    elseif minigameType == 'none' then
        interactionResult = 'success'
    else
        notify('error', ('Invalid lockpick minigame type: %s'):format(tostring(minigameType)))
        interactionResult = 'cancel'
    end

    if interactionResult == 'success' then
        local progressData = configSection.Progress or {}
        local completed = lib.progressBar({
            duration = configSection.DurationMs,
            label = progressData.Label or locale(localeFallback),
            useWhileDead = progressData.UseWhileDead or false,
            canCancel = progressData.CanCancel ~= false,
            disable = progressData.Disable or {},
            anim = progressData.Anim and {
                dict = progressData.Anim.dict,
                clip = progressData.Anim.clip,
                flag = progressData.Anim.flag or 49,
            } or nil
        })

        if not completed then
            interactionResult = 'cancel'
        end
    end

    return interactionResult
end

local function isPlayerOccupyingVehicle(vehicle)
    local maxSeats = GetVehicleMaxNumberOfPassengers(vehicle)

    for seat = -1, maxSeats - 1 do
        local ped = GetPedInVehicleSeat(vehicle, seat)

        if ped ~= 0 and IsPedAPlayer(ped) then
            return true
        end
    end

    return false
end

local function isVehicleExcluded(vehicle)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return true
    end

    if IsEntityDead(vehicle) then
        return true
    end

    local model = GetEntityModel(vehicle)
    local class = GetVehicleClass(vehicle)

    if Config.NpcLockNormalization.SkipVehicleClasses[class] then
        return true
    end

    if Config.NpcLockNormalization.SkipVehicleModels[model] then
        return true
    end

    return false
end

local function isValidAmbientVehicle(vehicle)
    if vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then
        return false
    end

    local model = GetEntityModel(vehicle)

    if isVehicleExcluded(vehicle) or (Config.NpcLockNormalization.BlacklistedModels and Config.NpcLockNormalization.BlacklistedModels[model]) then
        return false
    end

    local occupied = false

    for seat = -1, GetVehicleModelNumberOfSeats(model) - 2 do
        local ped = GetPedInVehicleSeat(vehicle, seat)
        if ped ~= 0 and DoesEntityExist(ped) then
            occupied = true
            break
        end
    end

    -- Never push occupied vehicles through the global normalization path.
    if occupied then
        return false
    end

    return Config.NpcLockNormalization.IncludeParkedVehicles ~= false
end

local function getVehicleContextForPlayerActions()
    local ped = PlayerPedId()
    local vehicle = 0

    if IsPedInAnyVehicle(ped, false) then
        vehicle = GetVehiclePedIsIn(ped, false)
    end

    if vehicle == 0 then
        vehicle = getVehicleInFront(Config.General.NearestVehicleDistance)
    end

    if vehicle == 0 then
        vehicle = getClosestVehicle(GetEntityCoords(ped), Config.General.NearestVehicleDistance)
    end

    if vehicle == 0 then
        return nil
    end

    local plate = select(1, resolveVehiclePlate(vehicle))
    local netId = ensureNetId(vehicle)

    if not plate or not netId then
        return nil
    end

    return {
        vehicle = vehicle,
        plate = plate,
        netId = netId,
    }
end

-- ============================================================================
-- Notifications / synced effects
-- ============================================================================

RegisterNetEvent('bullen_vehiclekeys:client:notify', function(notifType, message)
    notify(notifType, message)
end)

RegisterNetEvent('bullen_vehiclekeys:client:accessUpdated', function(plate, access)
    cacheAccess(plate, access)
end)

RegisterNetEvent('bullen_vehiclekeys:client:applyDoorState', function(netId, unlocked)
    local vehicle = NetToVeh(netId)

    if vehicle ~= 0 and DoesEntityExist(vehicle) then
        applyDoorState(vehicle, unlocked == true)
        flashVehicleLights(vehicle)
    end
end)

RegisterNetEvent('bullen_vehiclekeys:client:playLockToggleSound', function()
    playLockToggleSound()
end)

RegisterNetEvent('bullen_vehiclekeys:client:applyFakePlateState', function(netId, active, displayPlate, realPlate)
    local vehicle = NetToVeh(netId)

    if vehicle ~= 0 and DoesEntityExist(vehicle) then
        local state = getVehicleState(vehicle)

        if state then
            state:set(Config.FakePlates.ActiveStatebag, active == true, false)
            state:set(Config.FakePlates.DisplayPlateStatebag, displayPlate, false)
            state:set(Config.FakePlates.RealPlateStatebag, realPlate, false)
        end

        applyFakePlateDisplay(vehicle)
    end
end)

RegisterNetEvent('bullen_vehiclekeys:client:playAlarmFx', function(netId, alarmDurationMs, hornDurationMs)
    local vehicle = NetToVeh(netId)

    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return
    end

    if hornDurationMs and hornDurationMs > 0 then
        StartVehicleHorn(vehicle, hornDurationMs, `HELDDOWN`, false)
    end

    if alarmDurationMs and alarmDurationMs > 0 then
        SetVehicleAlarm(vehicle, true)
        StartVehicleAlarm(vehicle)
    end
end)

AddStateBagChangeHandler('xvkUnlocked', nil, function(bagName, _, value)
    local entity = GetEntityFromStateBagName(bagName)

    if entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return
    end

    applyDoorState(entity, value == true)
end)

-- ============================================================================
-- Lockpick / hotwire
-- ============================================================================

local function attemptLockpick(vehicle)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        notify('error', locale('no_vehicle'))
        return
    end

    local plate = select(1, resolveVehiclePlate(vehicle))
    local netId = ensureNetId(vehicle)

    if not plate or not netId then
        notify('error', locale('lockpick_failed'))
        return
    end

    local begin = lib.callback.await('bullen_vehiclekeys:server:beginLockpick', false, {
        plate = plate,
        netId = netId,
    })

    if not begin or not begin.ok then
        notify('error', begin and begin.message or locale('lockpick_failed'))
        return
    end

    local result = runConfiguredInteraction(Config.Lockpick, 'progress_lockpick')
    local finish = lib.callback.await('bullen_vehiclekeys:server:finishLockpick', false, begin.token, result)

    if not finish then
        notify('error', locale('lockpick_failed'))
        return
    end

    if finish.brokeLockpick then
        notify('error', locale('lockpick_broken'))
    end

    notify(finish.ok and 'success' or 'error', finish.message or locale(finish.ok and 'lockpick_success' or 'lockpick_failed'))
end

local function attemptFakePlateInstall(vehicle)
    if not Config.FakePlates.Enabled then
        notify('error', locale('fakeplate_disabled'))
        return
    end

    if vehicle == 0 or not DoesEntityExist(vehicle) then
        notify('error', locale('no_vehicle'))
        return
    end

    if not isNearVehicleRear(vehicle, Config.Target.FakePlateInstall and Config.Target.FakePlateInstall.RearDistance or 1.6) then
        notify('error', locale('fakeplate_not_rear'))
        return
    end

    local state = getVehicleState(vehicle)
    if state and state[Config.FakePlates.ActiveStatebag] then
        notify('error', locale('fakeplate_already_active'))
        return
    end

    local realPlate = select(1, resolveVehiclePlate(vehicle))
    local netId = ensureNetId(vehicle)

    if not realPlate or not netId then
        notify('error', locale('invalid_vehicle'))
        return
    end

    local begin = lib.callback.await('bullen_vehiclekeys:server:beginFakePlateInstall', false, {
        plate = realPlate,
        netId = netId,
    })

    if not begin or not begin.ok then
        notify('error', begin and begin.message or locale('fakeplate_install_cancelled'))
        return
    end

    local result = runConfiguredInteraction(Config.FakePlates.Install, 'fakeplate_progress')

    if result ~= 'success' then
        local finishCancel = lib.callback.await('bullen_vehiclekeys:server:finishFakePlateInstall', false, begin.token, result, nil)
        notify('error', finishCancel and finishCancel.message or locale('fakeplate_install_cancelled'))
        return
    end

    local requestedPlate = promptFakePlateText()

    if not requestedPlate then
        local finishNoInput = lib.callback.await('bullen_vehiclekeys:server:finishFakePlateInstall', false, begin.token, 'cancel', nil)
        notify('error', finishNoInput and finishNoInput.message or locale('fakeplate_install_cancelled'))
        return
    end

    local finish = lib.callback.await('bullen_vehiclekeys:server:finishFakePlateInstall', false, begin.token, 'success', requestedPlate)

    if not finish then
        notify('error', locale('fakeplate_install_cancelled'))
        return
    end

    if finish.ok then
        applyFakePlateDisplay(vehicle)
    end

    notify(finish.ok and 'success' or 'error', finish.message or locale(finish.ok and 'fakeplate_install_success' or 'fakeplate_install_cancelled'))
end

RegisterNetEvent('bullen_vehiclekeys:client:attemptFakePlateInstall', function(vehicle)
    attemptFakePlateInstall(vehicle)
end)

local function attemptHotwire(vehicle)
    if HotwireActive or vehicle == 0 or not DoesEntityExist(vehicle) then
        return
    end

    local plate = select(1, resolveVehiclePlate(vehicle))
    local netId = ensureNetId(vehicle)

    if not plate or not netId then
        return
    end

    HotwireActive = true
    HotwireVehicle = vehicle

    SetVehicleEngineOn(vehicle, false, true, true)
    SetVehicleUndriveable(vehicle, true)
    SetVehicleForwardSpeed(vehicle, 0.0)

    local begin = lib.callback.await('bullen_vehiclekeys:server:beginHotwire', false, {
        plate = plate,
        netId = netId,
    })

    if not begin or not begin.ok then
        HotwireActive = false
        HotwireVehicle = 0
        HotwireCooldown[plate] = GetGameTimer() + (Config.Hotwire.CooldownMs or 10000)

        if begin and begin.message then
            notify('error', begin.message)
        end

        return
    end

    local hotwireConfig = table.clone(Config.Hotwire or {})
    hotwireConfig.Progress = table.clone((Config.Hotwire and Config.Hotwire.Progress) or {})
    hotwireConfig.Progress.Disable = table.clone((hotwireConfig.Progress and hotwireConfig.Progress.Disable) or {})
    hotwireConfig.Progress.Disable.car = true

    local result = runConfiguredInteraction(hotwireConfig, 'progress_hotwire')
    local finish = lib.callback.await('bullen_vehiclekeys:server:finishHotwire', false, begin.token, result)
    HotwireActive = false
    HotwireVehicle = 0

    if finish and finish.access then
        cacheAccess(plate, finish.access)
    end

    if finish and finish.ok then
        notify('success', finish.message or locale('hotwire_success'))
        SetVehicleUndriveable(vehicle, false)
        SetVehicleEngineOn(vehicle, true, false, true)
        return
    end

    HotwireCooldown[plate] = GetGameTimer() + (Config.Hotwire.CooldownMs or 10000)
    notify('error', finish and finish.message or locale('hotwire_failed'))
end


-- ============================================================================
-- Search NPC flow
-- ============================================================================

local function searchNpcForKey(ped)
    local netId = ensureNetId(ped)

    if not netId then
        notify('error', locale('search_failed'))
        return
    end

    local progressData = Config.SearchableNpcKeys.Progress or {}
    local completed = lib.progressCircle({
        duration = Config.SearchableNpcKeys.SearchDurationMs,
        label = progressData.Label or locale('progress_search'),
        position = 'bottom',
        useWhileDead = progressData.UseWhileDead or false,
        canCancel = progressData.CanCancel ~= false,
        disable = progressData.Disable or {},
        anim = progressData.Anim and {
            dict = progressData.Anim.dict,
            clip = progressData.Anim.clip,
            flag = progressData.Anim.flag or 49,
        } or nil
    })

    if not completed then
        return
    end

    local response = lib.callback.await('bullen_vehiclekeys:server:retrieveNpcKey', false, netId)

    if response and response.ok then
        notify('success', response.message or locale('search_key_success', response.plate))
    else
        notify('error', response and response.message or locale('search_failed'))
    end
end

-- ============================================================================
-- Target integration
-- ============================================================================

local function canLockpickVehicle(entity, distance)
    if not Config.Target.Enabled or not Config.Lockpick.Enabled or not Config.Target.VehicleLockpick.Enabled then
        return false
    end

    if entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return false
    end

    if distance > Config.Target.VehicleLockpick.Distance then
        return false
    end

    if isVehicleExcluded(entity) then
        return false
    end

    local state = getVehicleState(entity)

    if state and state.xvkUnlocked then
        return false
    end

    local plate = select(1, resolveVehiclePlate(entity))
    local access = getCachedAccess(plate)

    if access and access.any then
        return false
    end

    return true
end

local function canSearchNpc(entity, distance)
    if not Config.Target.Enabled or not Config.SearchableNpcKeys.Enabled or not Config.Target.NpcKeySearch.Enabled then
        return false
    end

    if entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 1 then
        return false
    end

    if distance > Config.Target.NpcKeySearch.Distance then
        return false
    end

    if IsPedAPlayer(entity) then
        return false
    end

    local state = Entity(entity).state
    local searchData = state and state.xvkSearchableKey or nil

    if not searchData or searchData.searched then
        return false
    end

    if Config.SearchableNpcKeys.DeadOnly then
        return IsEntityDead(entity)
    end

    return IsEntityDead(entity) or GetEntityHealth(entity) <= Config.SearchableNpcKeys.IncapacitatedHealthThreshold
end

local function registerOxTarget()
    exports.ox_target:addGlobalVehicle({
        {
            name = 'xvk_lockpick_vehicle',
            label = locale('target_lockpick'),
            icon = Config.Target.VehicleLockpick.Icon,
            distance = Config.Target.VehicleLockpick.Distance,
            canInteract = canLockpickVehicle,
            onSelect = function(data)
                attemptLockpick(data.entity)
            end,
        },
        {
            name = 'xvk_fake_plate_install',
            label = locale('target_fake_plate_install'),
            icon = Config.Target.FakePlateInstall.Icon,
            distance = Config.Target.FakePlateInstall.Distance,
            canInteract = function(entity, distance)
                if not Config.FakePlates.Enabled or not Config.Target.FakePlateInstall.Enabled then
                    return false
                end

                if entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
                    return false
                end

                if distance > Config.Target.FakePlateInstall.Distance then
                    return false
                end

                local state = getVehicleState(entity)
                if state and state[Config.FakePlates.ActiveStatebag] then
                    return false
                end

                return isNearVehicleRear(entity, Config.Target.FakePlateInstall.RearDistance)
            end,
            onSelect = function(data)
                TriggerEvent('bullen_vehiclekeys:client:attemptFakePlateInstall', data.entity)
            end,
        }
    })

    exports.ox_target:addGlobalPed({
        {
            name = 'xvk_search_key',
            label = locale('target_search_key'),
            icon = Config.Target.NpcKeySearch.Icon,
            distance = Config.Target.NpcKeySearch.Distance,
            canInteract = canSearchNpc,
            onSelect = function(data)
                searchNpcForKey(data.entity)
            end,
        }
    })
end

local function registerQbTarget()
    exports['qb-target']:AddGlobalVehicle({
        options = {
            {
                icon = Config.Target.VehicleLockpick.Icon,
                label = locale('target_lockpick'),
                action = function(entity)
                    attemptLockpick(entity)
                end,
                canInteract = function(entity, distance)
                    return canLockpickVehicle(entity, distance)
                end,
            },
            {
                icon = Config.Target.FakePlateInstall.Icon,
                label = locale('target_fake_plate_install'),
                action = function(entity)
                    TriggerEvent('bullen_vehiclekeys:client:attemptFakePlateInstall', entity)
                end,
                canInteract = function(entity, distance)
                    if not Config.FakePlates.Enabled or not Config.Target.FakePlateInstall.Enabled then
                        return false
                    end

                    if entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
                        return false
                    end

                    if distance > Config.Target.FakePlateInstall.Distance then
                        return false
                    end

                    local state = getVehicleState(entity)
                    if state and state[Config.FakePlates.ActiveStatebag] then
                        return false
                    end

                    return isNearVehicleRear(entity, Config.Target.FakePlateInstall.RearDistance)
                end,
            }
        },
        distance = math.max(Config.Target.VehicleLockpick.Distance, Config.Target.FakePlateInstall.Distance)
    })

    exports['qb-target']:AddGlobalPed({
        options = {
            {
                icon = Config.Target.NpcKeySearch.Icon,
                label = locale('target_search_key'),
                action = function(entity)
                    searchNpcForKey(entity)
                end,
                canInteract = function(entity, distance)
                    return canSearchNpc(entity, distance)
                end,
            }
        },
        distance = Config.Target.NpcKeySearch.Distance
    })
end

local function registerTargets()
    if not Config.Target.Enabled then
        return
    end

    if Config.Target.System == 'qb-target' then
        registerQbTarget()
        return
    end

    registerOxTarget()
end

-- ============================================================================
-- Locksmith NPC / menu
-- ============================================================================

local function getNearbyLocksmithLocation()
    local coords = GetEntityCoords(PlayerPedId())

    for _, location in ipairs(Config.Locksmith.Locations or {}) do
        local targetCoords = vec3(location.coords.x, location.coords.y, location.coords.z)

        if #(coords - targetCoords) <= Config.Locksmith.ServiceRadius then
            return location
        end
    end

    return nil
end

local function getLocksmithVehicle()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    if IsPedInAnyVehicle(ped, false) then
        local vehicle = GetVehiclePedIsIn(ped, false)

        if vehicle ~= 0 then
            return vehicle
        end
    end

    return getClosestVehicle(coords, Config.Locksmith.VehicleRadius)
end

local function openLocksmithAlarmVehicleMenu()
    local ownedVehicles = lib.callback.await('bullen_vehiclekeys:server:getOwnedVehiclesForAlarm', false) or {}

    if #ownedVehicles == 0 then
        notify('error', locale('locksmith_no_owned_vehicles'))
        return
    end

    local options = {}

    for _, entry in ipairs(ownedVehicles) do
        local plate = entry.plate
        local vehicleLabel = entry.label or plate
        local hasAlarm = entry.hasAlarm == true
        local baseDescription = ('Plate: %s'):format(plate)

        if hasAlarm then
            baseDescription = baseDescription .. '\n' .. locale('locksmith_alarm_exists')
        else
            baseDescription = baseDescription .. '\n' .. locale('locksmith_alarm_desc', plate)
        end

        options[#options + 1] = {
            title = vehicleLabel,
            description = baseDescription,
            icon = 'shield',
            disabled = hasAlarm,
            onSelect = function()
                TriggerServerEvent('bullen_vehiclekeys:server:installAlarmForOwnedVehicle', plate)
            end,
        }
    end

    lib.registerContext({
        id = 'xvk_locksmith_alarm_vehicle_menu',
        title = locale('locksmith_alarm_vehicle_menu_title'),
        menu = 'xvk_locksmith_menu',
        options = options,
    })
    lib.showContext('xvk_locksmith_alarm_vehicle_menu')
end

local function openLocksmithMenu()
    local location = getNearbyLocksmithLocation()

    if not location then
        notify('error', locale('locksmith_no_location'))
        return
    end

    local vehicle = getLocksmithVehicle()
    local plate, netId

    if vehicle ~= 0 then
        plate = select(1, resolveVehiclePlate(vehicle))
        netId = ensureNetId(vehicle)
    end

    local options = {}

    if Config.Locksmith.CopyKey.Enabled then
        if vehicle == 0 or not plate or not netId then
            options[#options + 1] = {
                title = locale('locksmith_copy_title'),
                description = locale('locksmith_no_vehicle'),
                icon = 'key',
                disabled = true,
            }
        else
            options[#options + 1] = {
                title = locale('locksmith_copy_title'),
                description = (locale('locksmith_copy_desc', plate) .. ' | Cash: $' .. tostring(Config.Locksmith.CopyKey.Cost)),
                icon = 'key',
                onSelect = function()
                    TriggerServerEvent('bullen_vehiclekeys:server:copyKeyAtLocksmith', netId, plate)
                end,
            }
        end
    end

    if Config.Locksmith.Alarm.Enabled then
        options[#options + 1] = {
            title = locale('locksmith_alarm_title'),
            description = (locale('locksmith_alarm_menu_desc') .. ' | Cash: $' .. tostring(Config.Locksmith.Alarm.Cost)),
            icon = 'shield',
            onSelect = function()
                openLocksmithAlarmVehicleMenu()
            end,
        }
    end

    lib.registerContext({
        id = 'xvk_locksmith_menu',
        title = locale('locksmith_title'),
        options = options,
    })
    lib.showContext('xvk_locksmith_menu')
end

local function registerLocksmithTargetForPed(ped)
    if not Config.Target.Enabled or not Config.Target.Locksmith.Enabled then
        return
    end

    if Config.Target.System == 'qb-target' then
        exports['qb-target']:AddTargetEntity(ped, {
            options = {
                {
                    icon = Config.Target.Locksmith.Icon,
                    label = locale('target_locksmith'),
                    action = function()
                        openLocksmithMenu()
                    end,
                }
            },
            distance = Config.Target.Locksmith.Distance
        })
    else
        exports.ox_target:addLocalEntity(ped, {
            {
                name = ('xvk_locksmith_%s'):format(ped),
                icon = Config.Target.Locksmith.Icon,
                label = locale('target_locksmith'),
                distance = Config.Target.Locksmith.Distance,
                onSelect = function()
                    openLocksmithMenu()
                end,
            }
        })
    end
end

CreateThread(function()
    if not Config.Locksmith.Enabled or not Config.Locksmith.UsePed then
        return
    end

    for _, location in ipairs(Config.Locksmith.Locations or {}) do
        local model = joaat(location.ped)

        RequestModel(model)
        while not HasModelLoaded(model) do
            Wait(0)
        end

        local ped = CreatePed(0, model, location.coords.x, location.coords.y, location.coords.z - 1.0, location.coords.w, false, false)

        if ped ~= 0 and DoesEntityExist(ped) then
            SetEntityAsMissionEntity(ped, true, true)
            SetEntityInvincible(ped, true)
            SetEntityVisible(ped, true, false)
            SetEntityCollision(ped, true, true)
            SetBlockingOfNonTemporaryEvents(ped, true)
            FreezeEntityPosition(ped, true)
            SetPedCanRagdoll(ped, false)
            SetPedDiesWhenInjured(ped, false)
            SetPedCanBeTargetted(ped, false)

            if location.scenario then
                TaskStartScenarioInPlace(ped, location.scenario, 0, true)
            end

            LocksmithPeds[#LocksmithPeds + 1] = ped
            registerLocksmithTargetForPed(ped)
        end

        if location.blip and location.blip.Enabled then
            local blip = AddBlipForCoord(location.coords.x, location.coords.y, location.coords.z)
            SetBlipSprite(blip, location.blip.Sprite)
            SetBlipScale(blip, location.blip.Scale)
            SetBlipColour(blip, location.blip.Colour)
            SetBlipAsShortRange(blip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentString(location.blip.Name)
            EndTextCommandSetBlipName(blip)
        end

        SetModelAsNoLongerNeeded(model)
    end
end)


AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    for i = 1, #LocksmithPeds do
        local ped = LocksmithPeds[i]
        if ped and DoesEntityExist(ped) then
            DeleteEntity(ped)
        end
    end
end)

CreateThread(function()
    if Config.Target.Enabled then
        return
    end

    while true do
        local waitTime = 1000
        local location = getNearbyLocksmithLocation()

        if location then
            waitTime = 0
            showTextUi(('[E] %s'):format(locale('target_locksmith')))

            if IsControlJustReleased(0, 38) then
                openLocksmithMenu()
            end
        else
            hideTextUi()
        end

        Wait(waitTime)
    end
end)

-- ============================================================================
-- Ambient NPC lock normalization
-- ============================================================================

CreateThread(function()
    if not Config.NpcLockNormalization.Enabled then
        return
    end

    while true do
        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        local vehicles = GetGamePool('CVehicle')
        local candidates = {}
        local platesToQuery = {}

        for _, vehicle in ipairs(vehicles) do
            if #candidates >= Config.NpcLockNormalization.Cap then
                break
            end

            if DoesEntityExist(vehicle) and #(GetEntityCoords(vehicle) - coords) <= Config.NpcLockNormalization.Radius then
                local state = getVehicleState(vehicle)
                local plate = select(1, resolveVehiclePlate(vehicle))

                if plate then
                    local cacheEntry = ProtectionCache[plate]
                    if not cacheEntry or cacheEntry.expiresAt <= GetGameTimer() then
                        platesToQuery[#platesToQuery + 1] = plate
                    end
                end

                if state and state.xvkUnlocked == true then
                    applyDoorState(vehicle, true)
                    applyLocalPlayerVehicleEntryLock(vehicle, false)
                elseif isValidAmbientVehicle(vehicle) and plate then
                    candidates[#candidates + 1] = {
                        vehicle = vehicle,
                        plate = plate,
                    }
                end
            end
        end

        if #platesToQuery > 0 then
            local protectedMap = lib.callback.await('bullen_vehiclekeys:server:getProtectedPlates', false, platesToQuery) or {}

            for plate, owned in pairs(protectedMap) do
                cacheProtection(plate, owned)
            end
        end


        for _, entry in ipairs(candidates) do
            if not isPlateProtected(entry.plate) then
                applyDoorState(entry.vehicle, false)
            end
        end

        if Config.Debug.Enabled and Config.Debug.PrintLockNormalization then
            debugPrint('Normalized ambient vehicles:', #candidates)
        end

        Wait(Config.NpcLockNormalization.IntervalMs)
    end
end)

CreateThread(function()
    if not Config.FakePlates.Enabled then
        return
    end

    while true do
        local pedCoords = GetEntityCoords(PlayerPedId())
        local vehicles = GetGamePool('CVehicle')

        for _, vehicle in ipairs(vehicles) do
            if DoesEntityExist(vehicle) and #(GetEntityCoords(vehicle) - pedCoords) <= (Config.NpcLockNormalization.Radius or 80.0) then
                applyFakePlateDisplay(vehicle)
            end
        end

        Wait(1500)
    end
end)

-- ============================================================================
-- Driver seat access enforcement + auto hotwire
-- ============================================================================

CreateThread(function()
    local lastVehicle = 0
    local lastPlate = nil

    while true do
        local waitTime = 100
        local ped = PlayerPedId()

        if IsPedInAnyVehicle(ped, false) then
            local vehicle = GetVehiclePedIsIn(ped, false)

            if vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == ped then
                waitTime = 0

                local plate = select(1, resolveVehiclePlate(vehicle))
                local access = getCachedAccess(plate)

                if vehicle ~= lastVehicle or plate ~= lastPlate or not access then
                    access = requestVehicleAccess(vehicle)
                    lastVehicle = vehicle
                    lastPlate = plate
                end

                if access and access.any then
                    SetVehicleUndriveable(vehicle, false)
                else
                    SetVehicleEngineOn(vehicle, false, true, true)
                    SetVehicleUndriveable(vehicle, true)
                    SetVehicleForwardSpeed(vehicle, 0.0)
                    DisableControlAction(0, 59, true)
                    DisableControlAction(0, 60, true)
                    DisableControlAction(0, 63, true)
                    DisableControlAction(0, 64, true)
                    DisableControlAction(0, 71, true)
                    DisableControlAction(0, 72, true)
                    DisableControlAction(0, 75, true)

                    local state = getVehicleState(vehicle)
                    local cooldownUntil = HotwireCooldown[plate] or 0

                    if Config.Hotwire.Enabled and Config.Hotwire.AutoOnEnter and state and state.xvkBreached and GetGameTimer() >= cooldownUntil and not HotwireActive then
                        attemptHotwire(vehicle)
                    end
                end
            else
                lastVehicle = 0
                lastPlate = nil
            end
        else
            lastVehicle = 0
            lastPlate = nil
            HotwireVehicle = 0
        end

        Wait(waitTime)
    end
end)



CreateThread(function()
    math.randomseed(GetGameTimer())

    while true do
        checkCarjackAttempt()
        Wait((Config.Carjacking and Config.Carjacking.AimCheckInterval) or 0)
    end
end)

-- ============================================================================
-- Commands
-- ============================================================================

if Config.Commands.ToggleLocks.Enabled then
    RegisterCommand(Config.Commands.ToggleLocks.Name, function()
        local context = getVehicleContextForPlayerActions()

        if not context then
            notify('error', locale('no_vehicle'))
            return
        end

        TriggerServerEvent('bullen_vehiclekeys:server:toggleLocks', context.netId, context.plate)
    end, false)

    RegisterKeyMapping(Config.Commands.ToggleLocks.Name, Config.Commands.ToggleLocks.Description, 'keyboard', Config.Commands.ToggleLocks.KeyMapping)
end

if Config.Commands.Lockpick.Enabled then
    RegisterCommand(Config.Commands.Lockpick.Name, function()
        local context = getVehicleContextForPlayerActions()

        if not context then
            notify('error', locale('no_vehicle'))
            return
        end

        attemptLockpick(context.vehicle)
    end, false)
end

if Config.Commands.GiveKeys.Enabled then
    RegisterCommand(Config.Commands.GiveKeys.Name, function(_, args)
        local context = getVehicleContextForPlayerActions()

        if not context then
            notify('error', locale('no_vehicle'))
            return
        end

        local targetId = tonumber(args[1])

        if not targetId then
            targetId = getClosestPlayer(Config.SharedKeys.GiveDistance)
        end

        if not targetId then
            notify('error', locale('no_player_nearby'))
            return
        end

        TriggerServerEvent('bullen_vehiclekeys:server:shareKeys', targetId, context.plate)
    end, false)
end

if Config.Commands.RevokeKeys.Enabled then
    RegisterCommand(Config.Commands.RevokeKeys.Name, function(_, args)
        local context = getVehicleContextForPlayerActions()

        if not context then
            notify('error', locale('no_vehicle'))
            return
        end

        local targetId = tonumber(args[1])

        if not targetId then
            targetId = getClosestPlayer(Config.SharedKeys.GiveDistance)
        end

        if not targetId then
            notify('error', locale('no_player_nearby'))
            return
        end

        TriggerServerEvent('bullen_vehiclekeys:server:revokeKeys', targetId, context.plate)
    end, false)
end

-- ============================================================================
-- Resource startup
-- ============================================================================

CreateThread(function()
    registerTargets()
end)
