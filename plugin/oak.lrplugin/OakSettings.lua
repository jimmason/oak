--[[ OAK persistent settings, backed by Lightroom plugin preferences. ]]

local LrPrefs = import "LrPrefs"

local OakSettings = {}

local DEFAULTS = {
    serviceUrl = "http://127.0.0.1:8420",
    maxKeywords = 8,
}

function OakSettings.prefs()
    local p = LrPrefs.prefsForPlugin()
    for k, v in pairs(DEFAULTS) do
        if p[k] == nil then p[k] = v end
    end
    return p
end

function OakSettings.get()
    local p = OakSettings.prefs()
    return {
        serviceUrl = p.serviceUrl ~= "" and p.serviceUrl or DEFAULTS.serviceUrl,
        maxKeywords = tonumber(p.maxKeywords) or DEFAULTS.maxKeywords,
    }
end

return OakSettings
