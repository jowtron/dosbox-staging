set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)

set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_ARCHITECTURES arm64)
set(VCPKG_OSX_DEPLOYMENT_TARGET 16.0)
set(VCPKG_OSX_SYSROOT iphoneos)

# CMake wraps every iOS executable in an app bundle by default, which breaks
# the install step of ports that also build command-line tools (fluidsynth)
list(APPEND VCPKG_CMAKE_CONFIGURE_OPTIONS -DCMAKE_MACOSX_BUNDLE=OFF)
