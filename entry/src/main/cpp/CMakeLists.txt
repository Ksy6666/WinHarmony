cmake_minimum_required(VERSION 3.5.0)
project(winremote_h264)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(NOT DEFINED OHOS_STL)
    set(OHOS_STL c++_shared)
endif()

add_library(h264decoder SHARED
    video_decoder_napi.cpp)

target_include_directories(h264decoder PRIVATE ${NATIVERENDER_ROOT_PATH})

target_link_libraries(h264decoder PUBLIC
    libace_napi.z.so
    libnative_media_vdec.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_window.so
    libhilog_ndk.z.so)
