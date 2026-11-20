include(FetchContent)
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
# mbedTLS 2.28.9 declares cmake_minimum_required < 3.5, which CMake 4.0+ rejects otherwise.
if(NOT DEFINED CMAKE_POLICY_VERSION_MINIMUM)
  set(CMAKE_POLICY_VERSION_MINIMUM 3.10)
endif()
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()

set(TUNNEL_FORGE_MBEDTLS_SOURCE_DIR "" CACHE PATH "Use an existing mbedTLS source tree instead of downloading it")
if(TUNNEL_FORGE_MBEDTLS_SOURCE_DIR)
  add_subdirectory("${TUNNEL_FORGE_MBEDTLS_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/mbedtls" EXCLUDE_FROM_ALL)
  set(mbedtls_SOURCE_DIR "${TUNNEL_FORGE_MBEDTLS_SOURCE_DIR}")
else()
  FetchContent_Declare(
    mbedtls
    URL https://github.com/Mbed-TLS/mbedtls/archive/refs/tags/v2.28.9.tar.gz
  )
  FetchContent_MakeAvailable(mbedtls)
endif()
target_compile_definitions(mbedcrypto PRIVATE MBEDTLS_MD4_C)
