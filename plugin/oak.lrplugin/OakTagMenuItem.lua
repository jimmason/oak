--[[ OAK: Suggest Keywords for Selected Photos.

Exports a small JPEG preview of each selected photo, sends it to the local
OAK inference service, then shows a review dialog where suggested keywords
can be accepted or rejected per photo. Accepted keywords are applied under
an "OAK" parent keyword so AI-added keywords stay auditable.
]]

local LrApplication = import "LrApplication"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrExportSession = import "LrExportSession"
local LrFileUtils = import "LrFileUtils"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp = import "LrHttp"
local LrPathUtils = import "LrPathUtils"
local LrProgressScope = import "LrProgressScope"
local LrTasks = import "LrTasks"
local LrView = import "LrView"

local OakJson = require "OakJson"
local OakServer = require "OakServer"
local OakSettings = require "OakSettings"

-- Populated from persistent settings when the task runs
local SERVICE_URL = "http://127.0.0.1:8420"
local MAX_KEYWORDS = 8
local THRESHOLD = 0.0005  -- absolute floor; service also applies relative cutoff
local PARENT_KEYWORD = "OAK"
local THUMB_SIZE = 448

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function tagImage(jpegData)
    local url = string.format("%s/tag?top=%d&threshold=%s",
        SERVICE_URL, MAX_KEYWORDS, tostring(THRESHOLD))
    local body, headers = LrHttp.post(url, jpegData,
        { { field = "Content-Type", value = "image/jpeg" } }, "POST", 60)
    if not body then
        return nil, "no response from OAK service"
    end
    if headers and headers.status and headers.status ~= 200 then
        return nil, "OAK service returned HTTP " .. tostring(headers.status)
    end
    local parsed, err = OakJson.decode(body)
    if not parsed then
        return nil, "bad JSON from service: " .. tostring(err)
    end
    return parsed.keywords or {}
end

local function exportThumbnails(photos, tempDir)
    local session = LrExportSession({
        photosToExport = photos,
        exportSettings = {
            LR_format = "JPEG",
            LR_jpeg_quality = 0.8,
            LR_size_doConstrain = true,
            LR_size_resizeType = "longEdge",
            LR_size_maxWidth = THUMB_SIZE,
            LR_size_maxHeight = THUMB_SIZE,
            LR_size_units = "pixels",
            LR_export_destinationType = "specificFolder",
            LR_export_destinationPathPrefix = tempDir,
            LR_export_useSubfolder = false,
            LR_collisionHandling = "rename",
            LR_minimizeEmbeddedMetadata = true,
            LR_removeLocationMetadata = true,
            LR_export_colorSpace = "sRGB",
            LR_includeVideoFiles = false,
        },
    })
    -- Map each rendered thumbnail path back to its photo
    local jobs = {}
    for _, rendition in session:renditions() do
        local success, pathOrMessage = rendition:waitForRender()
        if success then
            jobs[#jobs + 1] = { photo = rendition.photo, path = pathOrMessage }
        end
    end
    return jobs
end

local function applyKeywords(catalog, results)
    -- results: { { photo = ..., keywords = { {keyword=..., confidence=...}, ... } }, ... }
    catalog:withWriteAccessDo("OAK keywords", function()
        local parent = catalog:createKeyword(PARENT_KEYWORD, {}, false, nil, true)
        -- createKeyword asserts if asked to return a keyword created earlier in
        -- the same write session, so cache LrKeyword objects per run.
        local cache = {}
        for _, r in ipairs(results) do
            for _, kw in ipairs(r.keywords) do
                local lrKeyword = cache[kw.keyword]
                if not lrKeyword then
                    lrKeyword = catalog:createKeyword(
                        kw.keyword, {}, true, parent, true)
                    cache[kw.keyword] = lrKeyword
                end
                r.photo:addKeyword(lrKeyword)
            end
        end
    end)
end

--[[ Modal review dialog: one row per photo (thumbnail + keyword checkboxes,
checked by default). Returns the approved subset of results, or nil if the
user cancelled. ]]
local function showReviewDialog(results)
    local approved = nil
    LrFunctionContext.callWithContext("oakReview", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        local allKeys = {}
        local photoRows = {}
        for pi, r in ipairs(results) do
            local checks = {}
            for ki, kw in ipairs(r.keywords) do
                local key = "p" .. pi .. "_k" .. ki
                props[key] = true
                allKeys[#allKeys + 1] = key
                checks[#checks + 1] = f:checkbox {
                    title = string.format("%s   (%.1f%%)",
                        kw.keyword, kw.confidence * 100),
                    value = LrView.bind(key),
                }
            end
            if pi > 1 then
                photoRows[#photoRows + 1] = f:separator { fill_horizontal = 1 }
            end
            photoRows[#photoRows + 1] = f:row {
                spacing = f:control_spacing(),
                f:catalog_photo {
                    photo = r.photo,
                    width = 140,
                    height = 140,
                    frame_width = 1,
                },
                f:column {
                    spacing = f:label_spacing(),
                    f:static_text {
                        title = r.photo:getFormattedMetadata("fileName") or "",
                        font = "<system/bold>",
                    },
                    unpack(checks),
                },
            }
        end

        local setAll = function(value)
            return function()
                for _, k in ipairs(allKeys) do props[k] = value end
            end
        end

        local contents = f:column {
            bind_to_object = props,
            spacing = f:dialog_spacing(),
            f:row {
                f:static_text {
                    title = string.format(
                        "Review suggested keywords for %d photo%s. " ..
                        "Unticked keywords will not be applied.",
                        #results, #results == 1 and "" or "s"),
                    fill_horizontal = 1,
                },
                f:push_button { title = "Select All", action = setAll(true) },
                f:push_button { title = "Select None", action = setAll(false) },
            },
            f:scrolled_view {
                width = 560,
                height = math.min(500, 40 + #results * 160),
                f:column {
                    spacing = f:dialog_spacing(),
                    unpack(photoRows),
                },
            },
        }

        local result = LrDialogs.presentModalDialog({
            title = "OAK — Review Suggested Keywords",
            contents = contents,
            actionVerb = "Apply Keywords",
        })

        if result == "ok" then
            approved = {}
            for pi, r in ipairs(results) do
                local kept = {}
                for ki, kw in ipairs(r.keywords) do
                    if props["p" .. pi .. "_k" .. ki] then
                        kept[#kept + 1] = kw
                    end
                end
                if #kept > 0 then
                    approved[#approved + 1] = { photo = r.photo, keywords = kept }
                end
            end
        end
    end)
    return approved
end

LrTasks.startAsyncTask(function()
    local settings = OakSettings.get()
    SERVICE_URL = settings.serviceUrl
    MAX_KEYWORDS = settings.maxKeywords

    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()
    if #photos == 0 then
        LrDialogs.message("OAK", "No photos selected.", "info")
        return
    end

    local progress = LrProgressScope({ title = "OAK: suggesting keywords" })
    progress:setCancelable(true)

    if not OakServer.isRunning() then
        progress:setCaption("Starting OAK service (loading model)...")
        if not OakServer.start() or not OakServer.waitUntilRunning(120) then
            progress:done()
            LrDialogs.message("OAK service could not be started",
                "Tried to launch the service automatically but it did not " ..
                "respond at " .. SERVICE_URL .. "\n\n" ..
                "Check service\\oak_service.log, or start it manually:\n" ..
                "  cd oak\n  .\\.venv\\Scripts\\python.exe service\\oak_service.py",
                "critical")
            return
        end
    end

    local tempDir = LrPathUtils.child(
        LrPathUtils.getStandardFilePath("temp"), "oak_thumbs")
    LrFileUtils.createAllDirectories(tempDir)

    progress:setCaption("Exporting previews...")
    local jobs = exportThumbnails(photos, tempDir)

    local results, errors = {}, {}
    for i, job in ipairs(jobs) do
        if progress:isCanceled() then break end
        progress:setPortionComplete(i - 1, #jobs)
        progress:setCaption(string.format("Tagging %d of %d", i, #jobs))

        local data = readFile(job.path)
        if data then
            local keywords, err = tagImage(data)
            if keywords then
                if #keywords > 0 then
                    results[#results + 1] = { photo = job.photo, keywords = keywords }
                end
            else
                errors[#errors + 1] = err
            end
        end
        LrFileUtils.delete(job.path)
    end
    progress:done()

    if #errors > 0 then
        LrDialogs.message("OAK — some photos failed",
            string.format("%d of %d photos could not be tagged.\n\nFirst error: %s",
                #errors, #jobs, errors[1]),
            "warning")
    end

    if #results == 0 then
        if #errors == 0 then
            LrDialogs.message("OAK",
                "No keywords were suggested for the selected photos.\n\n" ..
                "Try adding relevant terms to vocab.txt, or lower the threshold.",
                "info")
        end
        return
    end

    local approved = showReviewDialog(results)
    if approved ~= nil and #approved > 0 then
        applyKeywords(catalog, approved)
    end
end)
