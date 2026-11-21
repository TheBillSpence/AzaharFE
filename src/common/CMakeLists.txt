  target_sources(citra_common PUBLIC
    apple_authorization.h
    apple_authorization.cpp
    apple_utils.cpp
    apple_utils.h
  )
endif()

if (APPLE AND NOT IOS AND NOT ENABLE_LIBRETRO)
  target_sources(citra_common PUBLIC
    apple_utils.mm
  )
endif()
