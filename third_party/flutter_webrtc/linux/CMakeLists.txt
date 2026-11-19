cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "flutter_webrtc")
project(${PROJECT_NAME} LANGUAGES C CXX)

if (CMAKE_VERSION VERSION_GREATER_EQUAL "3.24.0")
  cmake_policy(SET CMP0135 NEW)
endif()

# Add the libwebrtc dependency
include("${CMAKE_CURRENT_SOURCE_DIR}/../third_party/CMakeLists.txt")

set(PLUGIN_NAME "${PROJECT_NAME}_plugin")
set (CMAKE_EXPORT_COMPILE_COMMANDS ON )
set(CMAKE_CXX_STANDARD 17)

add_definitions(-DRTC_DESKTOP_DEVICE)

add_library(${PLUGIN_NAME} SHARED
  "../common/cpp/src/flutter_data_channel.cc"
  "../common/cpp/src/flutter_data_packet_cryptor.cc"
  "../common/cpp/src/flutter_frame_cryptor.cc"
  "../common/cpp/src/flutter_media_stream.cc"
  "../common/cpp/src/flutter_utf8_sanitize.cc"
  "../common/cpp/src/flutter_peerconnection.cc"
  "../common/cpp/src/flutter_frame_capturer.cc"
  "../common/cpp/src/flutter_video_renderer.cc"
  "../common/cpp/src/flutter_screen_capture.cc"
  "../common/cpp/src/flutter_webrtc.cc"
  "../common/cpp/src/flutter_webrtc_base.cc"
  "../common/cpp/src/flutter_common.cc"
  "loopback_capturer_factory.cc"
  "pulse_loopback_capturer.cc"
  "flutter_webrtc_plugin.cc"
  "flutter/core_implementations.cc"
  "flutter/standard_codec.cc"
  "flutter/plugin_registrar.cc"
  "task_runner_linux.cc"
  "portal_screencast.cc"
  "selfie_segmenter.cc"
  "background_blur.cc"
  "noise_suppressor.cc"
)

include_directories(
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/flutter/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/svpng"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/include"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

# Tala: screen capture through the portal and PipeWire (portal_screencast.cc).
# Needs libpipewire-0.3-dev to build.
find_package(PkgConfig REQUIRED)
pkg_check_modules(TALA_PIPEWIRE REQUIRED IMPORTED_TARGET libpipewire-0.3)
pkg_check_modules(TALA_GIO_UNIX REQUIRED IMPORTED_TARGET gio-unix-2.0)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  PkgConfig::TALA_PIPEWIRE PkgConfig::TALA_GIO_UNIX)
# SPA's headers trip these with -Werror.
set_source_files_properties(portal_screencast.cc PROPERTIES
  COMPILE_OPTIONS "-Wno-missing-field-initializers;-Wno-unused-parameter")

# Tala: noise cancellation (noise_suppressor.cc) runs Xiph's RNNoise 0.2,
# kept in third_party/rnnoise. Built on its own, without Flutter's -Werror,
# and with its symbols hidden inside the plugin.
set(TALA_RNNOISE "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/rnnoise")
add_library(tala_rnnoise STATIC
  "${TALA_RNNOISE}/src/denoise.c"
  "${TALA_RNNOISE}/src/rnn.c"
  "${TALA_RNNOISE}/src/pitch.c"
  "${TALA_RNNOISE}/src/kiss_fft.c"
  "${TALA_RNNOISE}/src/celt_lpc.c"
  "${TALA_RNNOISE}/src/nnet.c"
  "${TALA_RNNOISE}/src/nnet_default.c"
  "${TALA_RNNOISE}/src/parse_lpcnet_weights.c"
  "${TALA_RNNOISE}/src/rnnoise_data.c"
  "${TALA_RNNOISE}/src/rnnoise_tables.c"
)
set_target_properties(tala_rnnoise PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  C_VISIBILITY_PRESET hidden)
target_include_directories(tala_rnnoise
  PUBLIC "${TALA_RNNOISE}/include"
  PRIVATE "${TALA_RNNOISE}/src")
target_compile_definitions(tala_rnnoise PUBLIC "RNNOISE_EXPORT=")
# Its note that only SSE2 is in use is expected: the build targets any x86-64.
target_compile_options(tala_rnnoise PRIVATE -O2 -Wno-cpp)
target_link_libraries(tala_rnnoise PRIVATE m)
target_link_libraries(${PLUGIN_NAME} PRIVATE tala_rnnoise)

# Tala: background_blur.cc splits its passes across a few threads.
find_package(Threads REQUIRED)
target_link_libraries(${PLUGIN_NAME} PRIVATE Threads::Threads)

# GCC 14+ (and notably GCC 16) tightened transitive header inclusion, so the
# bundled libwebrtc headers (e.g. third_party/libwebrtc/include/rtc_types.h)
# now fail to compile because they use fixed-width integer types such as
# uint32_t without including <cstdint>. Force-include <cstdint> for every
# translation unit of this target so those headers build under strict
# toolchains, instead of editing the downloaded third-party headers in place.
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
  target_compile_options(${PLUGIN_NAME} PRIVATE -include cstdint)
endif()

# ---------------------------------------------------------------------------
# System-audio (loopback) capture: PulseAudio simple API.
# Guarded so a host without libpulse dev headers still builds the plugin; in
# that case pulse_loopback_capturer.cc compiles to nothing and the factory
# returns nullptr (getDisplayMedia audio degrades to no track), matching the
# previous Linux stub behaviour rather than breaking the whole plugin build.
# PipeWire ships a PulseAudio compat layer, so libpulse covers both stacks.
# On Manjaro/.41 the dev headers come from the base `libpulse` package.
# ---------------------------------------------------------------------------
find_package(PkgConfig)
if(PkgConfig_FOUND)
  pkg_check_modules(PULSE IMPORTED_TARGET libpulse libpulse-simple)
endif()
if(TARGET PkgConfig::PULSE)
  message(STATUS "flutter_webrtc: libpulse found -- enabling Linux system-audio loopback capture.")
  target_compile_definitions(${PLUGIN_NAME} PRIVATE HAVE_LIBPULSE)
  target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::PULSE)
else()
  message(WARNING "flutter_webrtc: libpulse NOT found -- Linux system-audio loopback capture disabled (getDisplayMedia({audio:true}) yields no audio track). Install the libpulse dev package to enable it.")
endif()


target_link_libraries(${PLUGIN_NAME} PRIVATE 
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/lib/libwebrtc.so"
)

# List of absolute paths to libraries that should be bundled with the plugin
set(flutter_webrtc_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/lib/libwebrtc.so"
  PARENT_SCOPE
)

# Add $ORIGIN to RPATH so that lib/libflutter_webrtc_plugin.so can find lib/libwebrtc.so at runtime
set_property(
    TARGET ${PLUGIN_NAME}
    PROPERTY BUILD_RPATH
    "\$ORIGIN"
)
