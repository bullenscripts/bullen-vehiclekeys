Config = {}

--[[-------------------------------------------------------------------------
    bullen_vehiclekeys
    Premium vehicle key / theft / locksmith / alarm resource for QBCore servers.

    The resource is built around four distinct access layers:
      1. owned access               -> resolved from your owned vehicle table
      2. shared access              -> persistent DB-granted access from an owner
      3. physical key access        -> item metadata key tied to a plate
      4. temporary stolen access    -> session-only access granted after theft

    Door lock state is separate from access. A vehicle can be:
      - globally unlocked for everyone (door state)
      - breached/unlocked after a lockpick
      - still require a key / hotwire for ignition
---------------------------------------------------------------------------]]

Config.General = {
    Locale = 'en',
    NotifyPosition = 'top',
    AccessCacheMs = 15000,
    NearestVehicleDistance = 10.0,
    NearestPlayerDistance = 4.0,
    RequireNetworkedEntities = true,
}

Config.Framework = {
    Name = 'qbcore',
    DefaultMoneyAccount = 'cash',

    -- Default ownership resolver:
    -- SELECT citizenid FROM player_vehicles WHERE plate = ?
    Ownership = {
        Table = 'player_vehicles',
        OwnerColumn = 'citizenid',
        PlateColumn = 'plate',
        CacheSeconds = 60,
        CustomResolver = nil, -- function(plate) return citizenid or nil end
    },
}

Config.Inventory = {
    System = 'ox_inventory', -- 'ox_inventory' or 'qb-inventory'
    KeyItem = 'vehicle_key',
    BlankKeyItem = 'blank_key',
    LockpickItem = 'lockpick',
}


Config.Locksmith = {
    Enabled = true,
    UsePed = true,
    ServiceRadius = 5.0,
    VehicleRadius = 8.0,

    CopyKey = {
        Enabled = true,
        RequireOwnedAccess = true,
        RequireBlankKey = true,
        Cost = 500,
        MoneyAccount = 'cash',
    },

    Alarm = {
        Enabled = true,
        Cost = 2500,
        MoneyAccount = 'cash',
    },

    Locations = {
        {
            id = 'pillbox',
            coords = vec4(214.01, -807.39, 30.80, 250.32),
            ped = 's_m_m_autoshop_01',
            scenario = 'WORLD_HUMAN_CLIPBOARD',
            blip = {
                Enabled = true,
                Sprite = 134,
                Scale = 0.75,
                Colour = 47,
                Name = 'Locksmith',
            },
        },
    },
}

Config.Target = {
    Enabled = true,
    System = 'ox_target', -- 'ox_target' or 'qb-target'

    Locksmith = {
        Enabled = true,
        Icon = 'fa-solid fa-key',
        Label = 'Use Locksmith',
        Distance = 2.0,
    },

    VehicleLockpick = {
        Enabled = true,
        Icon = 'fa-solid fa-screwdriver-wrench',
        Label = 'Lockpick Vehicle',
        Distance = 2.2,
    },

    NpcKeySearch = {
        Enabled = true,
        Icon = 'fa-solid fa-key',
        Label = 'Search for Vehicle Key',
        Distance = 2.0,
    },

    FakePlateInstall = {
        Enabled = true,
        Icon = 'fa-solid fa-id-card',
        Label = 'Install Fake Plate',
        Distance = 2.2,
        RearDistance = 1.6,
    },
}

Config.OwnedKeys = {
    Enabled = true,
}

Config.SharedKeys = {
    Enabled = true,
    Persistent = true,
    CacheSeconds = 60,
    GiveDistance = 4.0,
    AllowSharedHoldersToReshare = false,
    AllowOwnerToRevoke = true,
}

Config.PhysicalKeys = {
    Enabled = true,
    MetadataPlateField = 'plate',
    MetadataKeyIdField = 'key_id',
    IncludeDescription = true,
    DescriptionFormat = 'Plate: %s',
}

Config.TemporaryStolen = {
    Enabled = true,
    ClearOnDrop = true,
}

Config.Alarms = {
    Enabled = true,
    NotifyOwner = true,
    TriggerOnLockpickFail = true,
    TriggerOnLockpickSuccess = true,
    HornDurationMs = 1800,
    AlarmDurationMs = 6000,
}

Config.NpcLockNormalization = {
    Enabled = true,
    IntervalMs = 3500,
    Radius = 65.0,
    Cap = 24,
    ProtectedPlateCacheMs = 60000,

    -- Emergency / service classes are skipped by default.
    SkipVehicleClasses = {
        [18] = true, -- emergency
        [19] = true, -- military
        [20] = true, -- commercial
        [21] = true, -- trains
    },

    SkipVehicleModels = {
        [`police`] = true,
        [`police2`] = true,
        [`police3`] = true,
        [`police4`] = true,
        [`policeb`] = true,
        [`policet`] = true,
        [`ambulance`] = true,
        [`fbi`] = true,
        [`fbi2`] = true,
        [`firetruk`] = true,
        [`rhino`] = true,
    },

    RequireCivilianDriverForMoving = false,
    IncludeParkedVehicles = true,
    OnlyUnoccupiedOrParked = true,
    MovingDriverLockOnly = false,
    MovingDriverLocalPlayerLock = true,
}

Config.Lockpick = {
    Enabled = true,
    RequireItem = true,
    Distance = 2.2,
    DurationMs = 9000,
    SuccessChance = 0.68,
    BreakChanceOnSuccess = 0.15,
    BreakChanceOnFail = 0.45,
    BreakChanceOnCancel = 0.10,

    -- Choose the lockpick minigame explicitly.
    -- Options: 'burevestnik', 'ox_lib_skillcheck', 'lockpick', 'none'
    Minigame = 'burevestnik',

    -- Built-in ox_lib skillcheck settings used when Minigame = 'ox_lib_skillcheck'.
    SkillCheck = {
        Enabled = false,
        Difficulties = { 'medium', 'medium', 'hard' },
        Inputs = { 'e', 'e', 'e' },
        StartDelayMs = 150,
    },

    Progress = {
        Label = 'Lockpicking vehicle...',
        UseWhileDead = false,
        CanCancel = true,
        Disable = {
            move = true,
            car = true,
            combat = true,
        },
        Anim = {
            dict = 'veh@break_in@0h@p_m_one@',
            clip = 'low_force_entry_ds',
            flag = 49,
        }
    },

    BlacklistedModels = {
        [`rhino`] = true,
    },
}

Config.Hotwire = {
    Enabled = true,
    AutoOnEnter = true,
    RequireBreachedVehicle = true,
    DurationMs = 7000,
    SuccessChance = 0.72,
    CooldownMs = 10000,

    SkillCheck = {
        Enabled = false,
        Difficulties = { 'medium', 'hard' },
        Inputs = { 'e', 'e', 'e' },
        StartDelayMs = 150,
    },

    Progress = {
        Label = 'Hotwiring vehicle',
        UseWhileDead = false,
        CanCancel = true,
        Disable = {
            move = true,
            car = false,
            combat = true,
        },
        Anim = {
            dict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
            clip = 'machinic_loop_mechandplayer',
            flag = 49,
        }
    },
}

Config.SearchableNpcKeys = {
    Enabled = true,
    DeadOnly = false, -- false = dead or incapacitated, true = dead only
    IncapacitatedHealthThreshold = 125,
    SearchDurationMs = 3500,

    Progress = {
        Label = 'Searching for vehicle key...',
        UseWhileDead = false,
        CanCancel = true,
        Disable = {
            move = true,
            car = true,
            combat = true,
        },
        Anim = {
            dict = 'amb@medic@standing@kneel@base',
            clip = 'base',
            flag = 49,
        }
    },
}

Config.FakePlates = {
    Enabled = true,

    -- Fake plate state is fully separated from real ownership/access.
    -- Access checks continue to use the real underlying plate via these statebag keys.
    ActiveStatebag = 'xvkFakePlateActive',
    RealPlateStatebag = 'xvkRealPlate',
    DisplayPlateStatebag = 'xvkFakePlateDisplay',

    Items = {
        FakePlate = 'fakeplate',
        PlateKit = 'platekit',
        Screwdriver = 'screwdriver',
    },

    Install = {
        Distance = 2.5,
        RequireAccess = true,
        RemoveFakePlateItem = true,
        RemovePlateKitItem = true,
        RemoveScrewdriverItem = false,
        DurationMs = 7000,

        Minigame = {
            Type = 'none',
        },

        Progress = {
            Label = 'Installing fake plate',
            UseWhileDead = false,
            CanCancel = true,
            Disable = {
                move = true,
                car = true,
                combat = true,
            },
            Anim = {
                dict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                clip = 'machinic_loop_mechandplayer',
                flag = 49,
            }
        },

        TextEntry = {
            MaxLetters = 3,
            MaxNumbers = 3,
            Example = 'ABC123',
        },
    },
}


Config.Carjacking = {
    Enabled = true,
    AllowedWeapons = {
        [`WEAPON_PISTOL`] = true,
        [`WEAPON_COMBATPISTOL`] = true,
        [`WEAPON_APPISTOL`] = true,
        [`WEAPON_HEAVYPISTOL`] = true,
        [`WEAPON_MACHINEPISTOL`] = true,
        [`WEAPON_MICROSMG`] = true,
        [`WEAPON_SMG`] = true,
        [`WEAPON_PUMPSHOTGUN`] = true,
    },

    EnableReactions = {
        DriveAway = true,
        Surrender = false,
        Fight = true,
    },

    ReactionWeights = {
        DriveAway = 34,
        Surrender = 33,
        Fight = 33,
    },

    AttackWeapons = {
        { weapon = `WEAPON_PISTOL`,        weight = 15, ammo = 250, type = 'ranged' },
        { weapon = `WEAPON_COMBATPISTOL`,  weight = 15, ammo = 250, type = 'ranged' },
        { weapon = `WEAPON_HEAVYPISTOL`,   weight = 15, ammo = 250, type = 'ranged' },
        { weapon = `WEAPON_APPISTOL`,      weight = 10, ammo = 250, type = 'ranged' },
        { weapon = `WEAPON_MACHINEPISTOL`, weight = 10, ammo = 300, type = 'ranged' },
        { weapon = `WEAPON_MICROSMG`,      weight = 10, ammo = 300, type = 'ranged' },
        { weapon = `WEAPON_KNIFE`,         weight = 12, ammo = 1,   type = 'melee'  },
        { weapon = `WEAPON_BAT`,           weight = 13, ammo = 1,   type = 'melee'  },
    },

    AimCheckInterval = 0,
    AimDistance = 25.0,
    RequiredAimTime = 450,
    ReactionCooldown = 12000,
    VehicleStopTimeout = 3500,
    FleeDistance = 150.0,
    FleeReinforceTime = 8000,
    FightAccuracyMin = 35,
    FightAccuracyMax = 60,

    MeleeChaseTime = 10000,
    MeleeRepathInterval = 600,
    MeleeAttackDistance = 2.2,
    MeleeRunSpeed = 3.0,

    DriveAwayStyle = 447,
    DriveAwaySpeed = 44.0,
    DriveAwayRetaskTime = 6000,
    DriveAwayRetaskInterval = 900,
    DriveAwayTargetDistance = 140.0,
    DriveAwayStopRange = 8.0,
    DriveAwayReseatDriver = true,
    DriveAwayCommitDuration = 1200,
    DriveAwayCommitInterval = 200,
    DriveAwayCommitMinSpeed = 12.0,
}

Config.Commands = {
    ToggleLocks = {
        Enabled = true,
        Name = 'vlock',
        Description = 'Toggle the nearest accessible vehicle lock state',
        KeyMapping = 'L',
    },

    Lockpick = {
        Enabled = true,
        Name = 'lockpick',
        Description = 'Fallback lockpick command when target is disabled',
    },

    GiveKeys = {
        Enabled = true,
        Name = 'givekeys',
        Description = 'Give shared key access for the nearest/current vehicle',
    },

    RevokeKeys = {
        Enabled = true,
        Name = 'revokekeys',
        Description = 'Revoke shared key access for the nearest/current vehicle',
    },
}

Config.Debug = {
    Enabled = false,
    PrintLockNormalization = false,
    PrintAccess = false,
}
