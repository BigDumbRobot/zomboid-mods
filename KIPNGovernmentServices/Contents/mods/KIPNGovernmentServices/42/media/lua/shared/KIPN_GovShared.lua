-- KIPN_GovShared.lua
--
-- Command and response names added by COMPUTER Safehouse and Land
-- Claims on top of KIP Network Terminal's KIPN.Shared tables.

require "KIPN_Shared"

KIPN = KIPN or {}
KIPN.Shared = KIPN.Shared or {}
KIPN.Shared.Commands = KIPN.Shared.Commands or {}
KIPN.Shared.ResponseEvents = KIPN.Shared.ResponseEvents or {}

KIPN.Shared.Commands.RENEW_CLAIM =
    KIPN.Shared.Commands.RENEW_CLAIM or "renewClaim"

KIPN.Shared.ResponseEvents.CLAIM_RENEWED =
    KIPN.Shared.ResponseEvents.CLAIM_RENEWED or "claimRenewed"
