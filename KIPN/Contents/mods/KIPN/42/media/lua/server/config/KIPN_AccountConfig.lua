-- KIPN_AccountConfig.lua
--
-- Server-authoritative KIPN account configuration.
--
-- Responsibilities:
--   * Define account policy / limits.
--   * Define session policy.
--   * Expose an Initialize() method so KIPN_Server's
--     initializeService() can load it cleanly.
--
-- This module intentionally contains configuration only.
-- Actual account logic lives in KIPN_AuthService.lua.

if isClient() then return end

require "KIPN/KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.AccountConfig = KIPN.Server.AccountConfig or {}

local AccountConfig = KIPN.Server.AccountConfig

------------------------------------------------------------
-- ACCOUNT POLICY
------------------------------------------------------------

AccountConfig.MaxAccountsPerSteamId = 3
AccountConfig.MinUsernameLength = 3
AccountConfig.MaxUsernameLength = 20
AccountConfig.MinPasswordLength = 6
AccountConfig.MaxPasswordLength = 64
AccountConfig.UsernamePattern = "^[%w_.%-]+$"

------------------------------------------------------------
-- SESSION POLICY
------------------------------------------------------------

AccountConfig.SessionDurationDays = 30
AccountConfig.PersistentLoginEnabled = true

------------------------------------------------------------
-- SANDBOX OVERRIDES
------------------------------------------------------------
--
-- Admin-editable fields, defined in sandbox-options.txt under the
-- "KIPN" page. Values are applied on top of the hardcoded defaults
-- above so this file still works standalone if Sandbox Settings
-- for some reason aren't populated yet (e.g. very early boot).
------------------------------------------------------------

local function applySandboxOverrides()
    local sv = SandboxVars and SandboxVars.KIPN

    if not sv then
        print(
            "[KIPN ACCOUNT CONFIG] SandboxVars.KIPN not available " ..
            "yet; keeping hardcoded defaults."
        )
        return
    end

    if sv.MaxAccountsPerSteamId ~= nil then
        AccountConfig.MaxAccountsPerSteamId = sv.MaxAccountsPerSteamId
    end

    if sv.MinUsernameLength ~= nil then
        AccountConfig.MinUsernameLength = sv.MinUsernameLength
    end

    if sv.MaxUsernameLength ~= nil then
        AccountConfig.MaxUsernameLength = sv.MaxUsernameLength
    end

    if sv.MinPasswordLength ~= nil then
        AccountConfig.MinPasswordLength = sv.MinPasswordLength
    end

    if sv.MaxPasswordLength ~= nil then
        AccountConfig.MaxPasswordLength = sv.MaxPasswordLength
    end

    if sv.SessionDurationDays ~= nil then
        AccountConfig.SessionDurationDays = sv.SessionDurationDays
    end

    if sv.PersistentLoginEnabled ~= nil then
        AccountConfig.PersistentLoginEnabled = sv.PersistentLoginEnabled
    end

    if AccountConfig.MinUsernameLength > AccountConfig.MaxUsernameLength then
        print(
            "[KIPN ACCOUNT CONFIG] WARNING: MinUsernameLength > " ..
            "MaxUsernameLength in Sandbox Settings; clamping."
        )
        AccountConfig.MinUsernameLength = AccountConfig.MaxUsernameLength
    end

    if AccountConfig.MinPasswordLength > AccountConfig.MaxPasswordLength then
        print(
            "[KIPN ACCOUNT CONFIG] WARNING: MinPasswordLength > " ..
            "MaxPasswordLength in Sandbox Settings; clamping."
        )
        AccountConfig.MinPasswordLength = AccountConfig.MaxPasswordLength
    end
end

------------------------------------------------------------
-- INITIALIZE
------------------------------------------------------------

function AccountConfig.Initialize()
    applySandboxOverrides()
    print("[KIPN ACCOUNT CONFIG] Initialized.")
    return true
end