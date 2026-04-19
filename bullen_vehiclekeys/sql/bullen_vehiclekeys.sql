CREATE TABLE IF NOT EXISTS `bullen_vehiclekeys_shared` (
    `plate` VARCHAR(16) NOT NULL,
    `owner_citizenid` VARCHAR(64) NOT NULL,
    `shared_citizenid` VARCHAR(64) NOT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`plate`, `shared_citizenid`),
    KEY `idx_xvk_shared_owner` (`owner_citizenid`),
    KEY `idx_xvk_shared_target` (`shared_citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `bullen_vehiclekeys_alarms` (
    `plate` VARCHAR(16) NOT NULL,
    `installed_by` VARCHAR(64) NULL,
    `installed_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`plate`),
    KEY `idx_xvk_alarm_installed_by` (`installed_by`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


CREATE TABLE IF NOT EXISTS `bullen_vehiclekeys_key_registry` (
    `plate` VARCHAR(16) NOT NULL,
    `current_key_id` VARCHAR(128) NOT NULL,
    `updated_by` VARCHAR(64) NULL,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`plate`),
    KEY `idx_xvk_key_registry_updated_by` (`updated_by`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
