# iOS platform support (step 3+ of the iOS port, see ios-plan.md):
#   - jit_memory:  process-wide dual-map (RX/RW) JIT arena for iOS 26+ (TXM),
#                 prepared out-of-band by a StikDebug session.
#   - bridge:      C facade consumed by the Xcode app (version/self-test/JIT
#                 state).
#   - memory_test: step 5 — validates the Vita3K memory model (4 GiB
#                 reservation, 4K-on-16K guest pages, fault policy, pressure,
#                 dual-map JIT arena bootstrap) on the target.
#   - frame_host:  renderer::FrameHost implementation backed by the app's
#                 CAMetalLayer, plus the main-thread layer/size channel.
#   - vulkan_demo: step 6 — presents a Vulkan/MoltenVK scene on the app's
#                 CAMetalLayer through the production render path (screen
#                 renderer + screen filter shaders compiled by MoltenVK).
#   - session_ios: step 7 — C facade over AppSessionController (init/library/
#                 install/launch/stop/report), sandbox Root layout and the
#                 document-picker staging/install path.
set(SOURCE_LIST
 include/ios/jit_memory.h
 src/jit_memory_ios.mm
 include/ios/bridge.h
 src/bridge.mm
 src/memory_test.cpp
 src/jit_regression_test.cpp
 include/ios/jit_regression_test.h
 include/ios/frame_host.h
 src/frame_host_ios.mm
 src/vulkan_demo.cpp
 src/session_ios.cpp
 include/ios/import_archive.h
 src/import_archive.cpp
 include/ios/save_transfer.h
 src/save_transfer.cpp
 include/ios/ime.h
 src/ime.cpp
 include/ios/diagnostics.h
 src/diagnostics_ios.mm
)

add_library(
ios
STATIC
${SOURCE_LIST}
)

source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} FILES ${SOURCE_LIST})

target_include_directories(ios PUBLIC include)
# frame_host.h (renderer::FrameHost / DisplayHandle) is a renderer header;
# include-only dependency, no link cycle with the renderer target.
target_include_directories(ios PRIVATE ${CMAKE_SOURCE_DIR}/vita3k/renderer/include)
# vulkan_demo drives the production renderer + display/gxm/mem states;
# session_ios drives the app subsystem (AppSessionController, packages
# installers, compat DB) and miniz for the zip staging extraction.
# concurrentqueue is linked PRIVATE to renderer, so expose its include here.
target_link_libraries(ios PUBLIC util mem renderer display gxm config concurrentqueue app packages compat modules io miniz ctrl touch motion ime)
target_link_libraries(ios PRIVATE dynarmic merry::oaknut dialog)
