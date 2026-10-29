# Reuse the iOS snapshot format, conflict handling and native iCloud query.
enable_language(Swift)
add_library(flowyr-cloud SHARED
    CloudSaveBridge.swift
    ../ios/Vita3K/App/Localization.swift
    ../ios/Vita3K/App/CloudSaveSync.swift
    ../ios/Vita3K/App/SaveSyncEngine.swift
)
set_target_properties(flowyr-cloud PROPERTIES
    # The parent directory's -Wformat/-Werror options are Clang-only.
    COMPILE_OPTIONS ""
    Swift_LANGUAGE_VERSION 6
    Swift_MODULE_NAME FlowyrCloud
    OUTPUT_NAME FlowyrCloud
    MACOSX_RPATH ON
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_NAME_DIR ON
)
target_compile_options(flowyr-cloud PRIVATE
    -target "${ARCHITECTURE}-apple-macos${CMAKE_OSX_DEPLOYMENT_TARGET}")
