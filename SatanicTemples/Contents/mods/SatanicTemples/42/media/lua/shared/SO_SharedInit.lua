require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_Sandbox"
require "SacrificialOffering/SO_RecipeParser"
require "SacrificialOffering/SO_ZoneCompatibility"

SacrificialOffering.Logger.Info("Shared systems loaded", {
    version = SacrificialOffering.VERSION,
    target = SacrificialOffering.BUILD_TARGET,
})
