cmake_minimum_required(VERSION 3.22.1)
project(localspot_panorama_stream LANGUAGES C CXX)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(ENABLE_SHARED OFF CACHE BOOL "" FORCE)
set(ENABLE_STATIC ON CACHE BOOL "" FORCE)
set(WITH_TURBOJPEG OFF CACHE BOOL "" FORCE)
set(WITH_TOOLS OFF CACHE BOOL "" FORCE)
set(WITH_TESTS OFF CACHE BOOL "" FORCE)
set(WITH_JAVA OFF CACHE BOOL "" FORCE)
set(WITH_SIMD ON CACHE BOOL "" FORCE)
set(LOCALSPOT_EMBEDDED_BUILD ON)

add_subdirectory(third_party/libjpeg-turbo-3.2.1 libjpeg-turbo)

add_library(pano_stream SHARED pano_stream_jni.c)
target_compile_features(pano_stream PRIVATE c_std_11)
target_include_directories(pano_stream PRIVATE
    third_party/libjpeg-turbo-3.2.1/src
    ${CMAKE_CURRENT_BINARY_DIR}/libjpeg-turbo)
target_link_libraries(pano_stream PRIVATE jpeg-static log)
