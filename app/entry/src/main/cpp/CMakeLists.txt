# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(tailnet_bridge)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(tailnet_bridge SHARED tailnet_bridge.cpp)

# 预构建库（官方模式：模块 libs 目录 + IMPORTED 引入，见 build-with-ndk-prebuilts.md）
add_library(tailscale_go SHARED IMPORTED)
set_target_properties(tailscale_go PROPERTIES
    IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libtailscale_go.so)

target_link_libraries(tailnet_bridge PUBLIC libace_napi.z.so libhilog_ndk.z.so tailscale_go)
