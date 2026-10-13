target_sources(dosboxcommon PRIVATE
  clipboard.cpp
  mapper.cpp
  sdl_gui.cpp
  titlebar.cpp
  window_geometry.cpp

  render/auto_image_adjustments.cpp
  render/auto_shader_switcher.cpp
  render/deinterlacer.cpp
  render/opengl_renderer.cpp
  render/render.cpp
  render/scaler/scalers.cpp
  render/sdl_renderer.cpp
  render/shader.cpp
  render/shader_manager.cpp
  render/shader_pipeline.cpp
  render/shader_pragma_parser.cpp
)

if(APPLE AND NOT DOSBOX_PLATFORM_IOS)
target_sources(dosboxcommon PRIVATE
  macos_window.mm
  render/macos_colorspace.mm
)
endif()

if (DOSBOX_PLATFORM_IOS)
  target_sources(dosboxcommon PRIVATE ios/touch_overlay.mm ios/library.mm ios/game_import.mm ios/game_settings.mm)
  # TARGET_DIRECTORY: the target is defined in another directory, where
  # source properties set here would otherwise not apply
  set_source_files_properties(ios/touch_overlay.mm ios/library.mm ios/game_import.mm ios/game_settings.mm
    TARGET_DIRECTORY dosboxcommon PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  target_link_libraries(dosboxcommon PRIVATE "-framework UIKit"
    "-framework UniformTypeIdentifiers")
endif()

if (OPT_DEBUGGER)
  target_link_libraries(dosboxcommon PRIVATE imgui::imgui)
endif()

target_link_libraries(dosboxcommon PRIVATE simpleini)

if (TARGET OpenGL::GL)
  target_link_libraries(dosboxcommon PRIVATE OpenGL::GL)
endif()

# The shader pipeline includes glad headers even when the OpenGL backend is
# disabled; glad resolves GL functions at runtime, so linking it is harmless
target_link_libraries(dosboxcommon PRIVATE glad)