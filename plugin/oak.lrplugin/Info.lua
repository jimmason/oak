return {
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = "com.oak.autokeywording",
    LrPluginName = "OAK — Open Auto Keywording",
    LrPluginInfoProvider = "OakInfoProvider.lua",

    LrLibraryMenuItems = {
        {
            title = "OAK: Suggest Keywords for Selected Photos",
            file = "OakTagMenuItem.lua",
            enabledWhen = "photosSelected",
        },
    },

    LrExportMenuItems = {
        {
            title = "OAK: Suggest Keywords for Selected Photos",
            file = "OakTagMenuItem.lua",
            enabledWhen = "photosSelected",
        },
    },

    VERSION = { major = 0, minor = 1, revision = 0 },
}
