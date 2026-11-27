set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin/$<CONFIG>)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${PROJECT_SOURCE_DIR}/CMakeModules)

# Object library for libretro code (can be linked into both shared lib and tests)
add_library(citra_libretro_common OBJECT
        emu_window/libretro_window.cpp
        emu_window/libretro_window.h
        input/input_factory.cpp
        input/input_factory.h
        input/mouse_tracker.cpp
        input/mouse_tracker.h
        $<$<BOOL:${ENABLE_VULKAN}>: libretro_vk.cpp libretro_vk.h>
        environment.cpp
        environment.h
        core_settings.cpp
        core_settings.h)

target_compile_definitions(citra_libretro_common PRIVATE HAVE_LIBRETRO)
target_link_libraries(citra_libretro_common PRIVATE citra_common citra_core video_core libretro tsl::robin_map)
if(ENABLE_OPENGL)
    target_link_libraries(citra_libretro_common PRIVATE glad)
endif()
if(ENABLE_VULKAN)
    target_link_libraries(citra_libretro_common PRIVATE sirit vulkan-headers vma)
endif()

add_library(citra_libretro SHARED
        citra_libretro.cpp
        citra_libretro.h
        $<TARGET_OBJECTS:citra_libretro_common>)

set_target_properties(citra_libretro PROPERTIES OUTPUT_NAME "azahar_libretro")

create_target_directory_groups(citra_libretro)

if (BSD STREQUAL "NetBSD")
    include(DisablePaxMprotect)
    disable_pax_mprotect(citra_libretro)
endif()

target_link_libraries(citra_common PRIVATE libretro)
target_link_libraries(citra_core PRIVATE libretro)
target_link_libraries(video_core PRIVATE libretro)
target_link_libraries(audio_core PRIVATE libretro)
target_link_libraries(input_common PRIVATE libretro)
target_compile_definitions(citra_common PRIVATE HAVE_LIBRETRO)
target_compile_definitions(citra_core PRIVATE HAVE_LIBRETRO)
target_compile_definitions(video_core PRIVATE HAVE_LIBRETRO)
target_compile_definitions(audio_core PRIVATE HAVE_LIBRETRO)
target_compile_definitions(input_common PRIVATE HAVE_LIBRETRO)

target_link_libraries(citra_libretro PRIVATE citra_common citra_core)
target_link_libraries(citra_libretro PRIVATE Boost::boost dds-ktx libretro tsl::robin_map)
if(ENABLE_VULKAN)
  target_link_libraries(citra_libretro PRIVATE sirit vulkan-headers vma)
endif()
if(ENABLE_OPENGL)
  target_link_libraries(citra_libretro PRIVATE glad)
endif()
target_link_libraries(citra_libretro PRIVATE ${PLATFORM_LIBRARIES} Threads::Threads)
if(DEFINED LIBRETRO_STATIC)
  target_link_libraries(citra_libretro PRIVATE -static-libstdc++)
endif()

set_target_properties(citra_libretro PROPERTIES PREFIX "")
target_compile_definitions(citra_libretro PRIVATE HAVE_LIBRETRO)

if(ANDROID)
  target_compile_definitions(citra_common PRIVATE HAVE_LIBRETRO_VFS)
  target_compile_definitions(citra_core PRIVATE HAVE_LIBRETRO_VFS)
  target_compile_definitions(video_core PRIVATE HAVE_LIBRETRO_VFS)
  target_compile_definitions(citra_libretro_common PRIVATE USING_GLES HAVE_LIBRETRO_VFS)
  target_compile_definitions(citra_libretro PRIVATE USING_GLES HAVE_LIBRETRO_VFS)
  target_link_libraries(citra_common PRIVATE libretro_common)
  target_link_libraries(citra_core PRIVATE libretro_common)
  target_link_libraries(video_core PRIVATE libretro_common)
  target_link_libraries(citra_libretro_common PRIVATE libretro_common)
  target_link_libraries(citra_libretro PRIVATE libretro_common)
  # Link Android log library for __android_log_print
  target_link_libraries(citra_libretro PRIVATE log)
endif()

if(MINGW)
  target_link_libraries(citra_libretro PRIVATE crypt32)
endif()

if(AZAHAR_IOS_MOLTENVK_BRIDGE)
  # Offscreen Vulkan/MoltenVK bridge: core owns its device and returns a
  # host-visible output frame to the existing iOS UIImage frontend.
  target_compile_definitions(citra_libretro PRIVATE AZAHAR_IOS_MOLTENVK_BRIDGE)
  target_compile_definitions(citra_libretro_common PRIVATE AZAHAR_IOS_MOLTENVK_BRIDGE)
  target_sources(citra_libretro PRIVATE ios_moltenvk_bridge.cpp ios_moltenvk_bridge.h)
endif()

if(IOS)
  target_compile_definitions(citra_libretro_common PRIVATE IOS)
  target_compile_definitions(citra_libretro PRIVATE IOS)
  # The experimental software rasterizer exposes Oaknut types through its headers.
  if("arm64" IN_LIST ARCHITECTURE)
    target_link_libraries(citra_libretro PRIVATE oaknut)
  endif()
  target_link_libraries(citra_libretro PRIVATE "-framework CoreFoundation" "-framework Foundation")
endif()

if (CMAKE_SYSTEM_NAME STREQUAL "Darwin" OR
    CMAKE_SYSTEM_NAME STREQUAL "iOS" OR
    CMAKE_SYSTEM_NAME STREQUAL "tvOS")
  # Export the optional JIT halt bridge on iOS; leave macOS exports unchanged.
  set(LIBRETRO_EXPORTS_FILE "${CMAKE_CURRENT_SOURCE_DIR}/libretro.osx.def")
  if(IOS)
    set(LIBRETRO_EXPORTS_FILE "${CMAKE_CURRENT_BINARY_DIR}/libretro.ios.def")
    configure_file("${CMAKE_CURRENT_SOURCE_DIR}/libretro.osx.def"
                   "${LIBRETRO_EXPORTS_FILE}" COPYONLY)
    file(APPEND "${LIBRETRO_EXPORTS_FILE}" "_azahar_jit_request_halt\n")
    if(AZAHAR_IOS_MOLTENVK_BRIDGE)
      file(APPEND "${LIBRETRO_EXPORTS_FILE}"
          "_azahar_ios_vk_start\n_azahar_ios_vk_get_interface\n"
          "_azahar_ios_vk_readback\n_azahar_ios_vk_readback_frame\n_azahar_ios_vk_readback_failed\n"
          "_azahar_ios_vk_drain_readback\n_azahar_ios_vk_shutdown\n"
          "_azahar_ios_vk_game_loaded\n_azahar_ios_vk_set_metal_layer\n"
          "_azahar_ios_vk_present_frame\n_azahar_ios_vk_present_extent\n_azahar_ios_vk_present_stage\n")
    endif()
  endif()
  target_link_libraries(citra_libretro PRIVATE "-Wl,-exported_symbols_list,${LIBRETRO_EXPORTS_FILE}")
else()
  target_link_libraries(citra_libretro PRIVATE "-Wl,-Bsymbolic")
endif()

add_custom_target(azahar_libretro DEPENDS citra_libretro)
