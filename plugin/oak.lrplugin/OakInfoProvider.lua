--[[ OAK settings section shown in the Plug-in Manager. ]]

local LrTasks = import "LrTasks"
local LrView = import "LrView"

local OakServer = require "OakServer"
local OakSettings = require "OakSettings"

return {
    sectionsForTopOfDialog = function(f, propertyTable)
        local prefs = OakSettings.prefs()
        local bind = LrView.bind

        propertyTable.oakStatus = "Checking..."
        propertyTable.oakVocab = OakServer.readVocab() or ""
        propertyTable.oakVocabStatus = ""
        local function refreshStatus()
            LrTasks.startAsyncTask(function()
                propertyTable.oakStatus =
                    OakServer.isRunning() and "Running" or "Stopped"
            end)
        end
        refreshStatus()

        return {
            {
                title = "OAK Settings",
                bind_to_object = prefs,

                f:row {
                    spacing = f:label_spacing(),
                    f:static_text { title = "Service:", width = 160,
                                    alignment = "right" },
                    f:static_text {
                        title = bind { key = "oakStatus",
                                       bind_to_object = propertyTable },
                        width_in_chars = 12,
                    },
                    f:push_button {
                        title = "Start",
                        action = function()
                            LrTasks.startAsyncTask(function()
                                if OakServer.isRunning() then
                                    propertyTable.oakStatus = "Running"
                                    return
                                end
                                propertyTable.oakStatus = "Starting..."
                                if not OakServer.start() then
                                    propertyTable.oakStatus = "Install missing"
                                    return
                                end
                                propertyTable.oakStatus =
                                    OakServer.waitUntilRunning(120)
                                    and "Running" or "Failed (see log)"
                            end)
                        end,
                    },
                    f:push_button {
                        title = "Stop",
                        action = function()
                            LrTasks.startAsyncTask(function()
                                propertyTable.oakStatus = "Stopping..."
                                OakServer.stop()
                                LrTasks.sleep(2)
                                propertyTable.oakStatus =
                                    OakServer.isRunning() and "Running" or "Stopped"
                            end)
                        end,
                    },
                    f:push_button { title = "Refresh", action = refreshStatus },
                },
                f:row {
                    f:static_text { title = "", width = 160 },
                    f:static_text {
                        title = "The service also starts automatically when " ..
                                "you run OAK from the Library menu.\nLogs: " ..
                                "service\\oak_service.log",
                        font = "<system/small>",
                    },
                },

                f:row {
                    spacing = f:label_spacing(),
                    f:static_text { title = "Service URL:", width = 160,
                                    alignment = "right" },
                    f:edit_field { value = bind("serviceUrl"),
                                   width_in_chars = 30, immediate = true },
                },
                f:row {
                    spacing = f:label_spacing(),
                    f:static_text { title = "Max keywords per photo:", width = 160,
                                    alignment = "right" },
                    f:edit_field { value = bind("maxKeywords"), width_in_chars = 4,
                                    min = 1, max = 25, precision = 0,
                                    immediate = true },
                },
                f:row {
                    spacing = f:label_spacing(),
                    f:static_text { title = "Vocabulary:", width = 160,
                                    alignment = "right" },
                    f:column {
                        spacing = f:label_spacing(),
                        f:edit_field {
                            value = bind { key = "oakVocab",
                                           bind_to_object = propertyTable },
                            width_in_chars = 45, height_in_lines = 14,
                            allows_newlines = true,
                            immediate = true,
                        },
                        f:row {
                            f:push_button {
                                title = "Save Vocabulary",
                                action = function()
                                    LrTasks.startAsyncTask(function()
                                        local ok, err = OakServer.writeVocab(
                                            propertyTable.oakVocab or "")
                                        if not ok then
                                            propertyTable.oakVocabStatus =
                                                "Save failed: " .. tostring(err)
                                            return
                                        end
                                        if OakServer.isRunning() then
                                            propertyTable.oakVocabStatus =
                                                "Saved. Reloading model vocabulary..."
                                            local n, rerr = OakServer.reloadVocab()
                                            propertyTable.oakVocabStatus = n
                                                and string.format(
                                                    "Saved — %d keywords active.", n)
                                                or ("Saved, but reload failed: " ..
                                                    tostring(rerr))
                                        else
                                            propertyTable.oakVocabStatus =
                                                "Saved. Takes effect when the " ..
                                                "service starts."
                                        end
                                    end)
                                end,
                            },
                            f:push_button {
                                title = "Revert",
                                action = function()
                                    propertyTable.oakVocab =
                                        OakServer.readVocab() or ""
                                    propertyTable.oakVocabStatus = "Reverted."
                                end,
                            },
                            f:static_text {
                                title = bind { key = "oakVocabStatus",
                                               bind_to_object = propertyTable },
                                width_in_chars = 30,
                            },
                        },
                        f:static_text {
                            title = "One keyword per line; lines starting with # " ..
                                    "are comments. Phrases work well\n" ..
                                    "(e.g. \"golden retriever\", \"long exposure\"). " ..
                                    "Specific terms beat generic ones.",
                            font = "<system/small>",
                        },
                    },
                },
            },
        }
    end,
}
