
if (C_MANYMOUSE)

  add_library(manymouse STATIC)
  target_include_directories(manymouse SYSTEM PUBLIC ..)
  target_link_libraries(manymouse PRIVATE project_headers)
  target_sources(manymouse PRIVATE
    linux_evdev.c
    macosx_hidmanager.c
    macosx_hidutilities.c
    manymouse.c
    windows_wminput.c
    x11_xinput2.c
  )


  disable_warnings(manymouse)
endif()
