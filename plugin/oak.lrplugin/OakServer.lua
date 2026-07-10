--[[ OAK service lifecycle: health check, start (detached), wait, stop.

The plugin lives at <root>\plugin\oak.lrplugin and the Python service at
<root>\service with its venv at <root>\.venv, so all paths are derived from
the plugin location.
]]

local LrFileUtils = import "LrFileUtils"
local LrHttp = import "LrHttp"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"

local OakJson = require "OakJson"
local OakSettings = require "OakSettings"

local OakServer = {}

local function rootDir()
    return LrPathUtils.parent(LrPathUtils.parent(_PLUGIN.path))
end

function OakServer.url()
    return OakSettings.get().serviceUrl
end

function OakServer.isRunning()
    local body = LrHttp.get(OakServer.url() .. "/health", nil, 3)
    if not body then return false end
    local parsed = OakJson.decode(body)
    return parsed ~= nil and parsed.status == "ok"
end

--- Launch the service as a detached, windowless process. Must be called from
--- an async task. Returns false if the venv python is missing.
function OakServer.start()
    local root = rootDir()
    local pythonw = LrPathUtils.child(
        LrPathUtils.child(LrPathUtils.child(root, ".venv"), "Scripts"),
        "pythonw.exe")
    local serviceDir = LrPathUtils.child(root, "service")
    local script = LrPathUtils.child(serviceDir, "oak_service.py")
    local logfile = LrPathUtils.child(serviceDir, "oak_service.log")
    local port = OakServer.url():match(":(%d+)") or "8420"

    if not LrFileUtils.exists(pythonw) or not LrFileUtils.exists(script) then
        return false
    end
    local cmd = string.format(
        'start "" /min "%s" "%s" --port %s --logfile "%s"',
        pythonw, script, port, logfile)
    LrTasks.execute(cmd)
    return true
end

--- Poll /health until the service responds or timeoutSeconds elapses.
--- Must be called from an async task.
function OakServer.waitUntilRunning(timeoutSeconds, onTick)
    local waited = 0
    while waited < timeoutSeconds do
        if OakServer.isRunning() then return true end
        if onTick then onTick(waited) end
        LrTasks.sleep(2)
        waited = waited + 2
    end
    return OakServer.isRunning()
end

--- Ask the service to shut down. Returns true if it acknowledged.
function OakServer.stop()
    local body = LrHttp.post(OakServer.url() .. "/shutdown", "",
        { { field = "Content-Type", value = "application/json" } }, "POST", 5)
    return body ~= nil
end

--- Path to the shared vocabulary file.
function OakServer.vocabPath()
    return LrPathUtils.child(LrPathUtils.child(rootDir(), "service"), "vocab.txt")
end

--- Read the vocabulary file. Returns text, or nil + error.
function OakServer.readVocab()
    local f = io.open(OakServer.vocabPath(), "rb")
    if not f then return nil, "cannot open " .. OakServer.vocabPath() end
    local text = f:read("*a")
    f:close()
    return text
end

--- Write the vocabulary file. Returns true, or nil + error.
function OakServer.writeVocab(text)
    local f = io.open(OakServer.vocabPath(), "wb")
    if not f then return nil, "cannot write " .. OakServer.vocabPath() end
    f:write(text)
    f:close()
    return true
end

--- Append new terms to the vocabulary file, skipping duplicates
--- (case-insensitive). Returns the number of terms added, or nil + error.
function OakServer.appendVocab(terms)
    local text = OakServer.readVocab() or ""
    local existing = {}
    for line in text:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            existing[trimmed:lower()] = true
        end
    end
    local toAdd = {}
    for _, term in ipairs(terms) do
        if not existing[term:lower()] then
            existing[term:lower()] = true
            toAdd[#toAdd + 1] = term
        end
    end
    if #toAdd == 0 then return 0 end
    if #text > 0 and not text:match("\n$") then text = text .. "\n" end
    if not text:find("added from review", 1, true) then
        text = text .. "\n# ============ added from review ============\n"
    end
    text = text .. table.concat(toAdd, "\n") .. "\n"
    local ok, err = OakServer.writeVocab(text)
    if not ok then return nil, err end
    return #toAdd
end

--- Ask a running service to re-embed the vocabulary file.
--- Returns keyword count, or nil + error.
function OakServer.reloadVocab()
    local body = LrHttp.post(OakServer.url() .. "/vocab/reload", "",
        { { field = "Content-Type", value = "application/json" } }, "POST", 120)
    if not body then return nil, "no response" end
    local parsed = OakJson.decode(body)
    if not parsed or parsed.status ~= "ok" then
        return nil, (parsed and parsed.detail) or "reload failed"
    end
    return parsed.keywords
end

return OakServer
