local p = getPlayer()
DMMMPProbeStamp = tostring(getTimestampMs())
sendClientCommand(p, "LilBubbyDMMTest", "copySetup", {stamp = DMMMPProbeStamp})
DMMMPProbeResult = "asked server to drop map " .. DMMMPProbeStamp
