cmake_minimum_required(VERSION 3.22.1)
project(tunnel_engine C)

set(CMAKE_C_STANDARD 99)

# Keep clang-tidy opt-in because it is slower than a normal native build and can
# surface analyzer findings unrelated to the code a developer is currently touching.
option(TUNNEL_FORGE_CLANG_TIDY "Run clang-tidy for tunnel_engine C sources" OFF)
if(TUNNEL_FORGE_CLANG_TIDY)
  if(NOT CLANG_TIDY_COMMAND)
    find_program(CLANG_TIDY_COMMAND NAMES clang-tidy REQUIRED)
  endif()
  set(TUNNEL_FORGE_CLANG_TIDY_COMMAND
      "${CLANG_TIDY_COMMAND};--config-file=${CMAKE_CURRENT_LIST_DIR}/../../../../../.clang-tidy")
endif()

include(mbedtls.cmake)

add_library(
  tunnel_engine
  SHARED
  vpn_jni.c
  tunnel_loop.c
  packet_endpoint.c
  gvisor_bridge.c
  ipv4_dataplane.c
  nat_t_keepalive.c
  tunnel_liveness.c
  util.c
  util_endian.c
  modp2048_data.c
  ikev1.c
  esp_udp.c
  l2tp_avps.c
  l2tp_xfrm.c
  l2tp_root.c
  l2tp.c
  pptp_gre.c
  pptp_root.c
  pptp_wire.c
  pptp.c
  root_detect.c
  ppp_mschap.c
  ppp_mppe.c
  ppp_wire.c
  ppp.c
)

add_executable(pptp_gre_helper pptp_gre_helper.c)
set_target_properties(
  pptp_gre_helper
  PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}"
    PREFIX "lib"
    OUTPUT_NAME "pptp_gre_helper"
    SUFFIX ".so"
)

add_executable(l2tp_root_helper l2tp_root_helper.c l2tp_xfrm.c util_endian.c)
set_target_properties(
  l2tp_root_helper
  PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}"
    PREFIX "lib"
    OUTPUT_NAME "l2tp_root_helper"
    SUFFIX ".so"
)

if(TUNNEL_FORGE_CLANG_TIDY)
  set_property(TARGET tunnel_engine PROPERTY C_CLANG_TIDY "${TUNNEL_FORGE_CLANG_TIDY_COMMAND}")
  set_property(TARGET pptp_gre_helper PROPERTY C_CLANG_TIDY "${TUNNEL_FORGE_CLANG_TIDY_COMMAND}")
  set_property(TARGET l2tp_root_helper PROPERTY C_CLANG_TIDY "${TUNNEL_FORGE_CLANG_TIDY_COMMAND}")
endif()

target_include_directories(
  tunnel_engine
  PRIVATE
    ${mbedtls_SOURCE_DIR}/include
)

target_link_libraries(
  tunnel_engine
  PRIVATE mbedcrypto log dl
)

# Inner L2TP-in-UDP checksum: RFC 768 allows 0 = unused. Some kernels drop wrong computed checksums after ESP decap.
# A/B: set OFF (or pass -DTUNNEL_FORGE_ESP_INNER_UDP_NO_CHECKSUM=0 from Gradle) to compute checksums.
option(TUNNEL_FORGE_ESP_INNER_UDP_NO_CHECKSUM "Use inner UDP checksum 0 (interop)" ON)
if(TUNNEL_FORGE_ESP_INNER_UDP_NO_CHECKSUM)
  target_compile_definitions(tunnel_engine PRIVATE TUNNEL_FORGE_ESP_INNER_UDP_NO_CHECKSUM=1)
endif()

# Logs keymat_i/keymat_r once after Quick Mode; compare to `ip xfrm state` on the VPN gateway (secrets in logcat).
option(TUNNEL_FORGE_DEBUG_ESP_KEYMAT "Log ESP KEYMAT after IKE QM (debug only)" OFF)
if(TUNNEL_FORGE_DEBUG_ESP_KEYMAT)
  target_compile_definitions(tunnel_engine PRIVATE TUNNEL_FORGE_DEBUG_ESP_KEYMAT=1)
endif()

# KEYMAT variant selector for controlled interop trials:
# 1=A (per-SA), 2=B (single-stream Ni|Nr split), 3=C (single-stream Nr|Ni split)
set(TUNNEL_FORGE_KEYMAT_VARIANT "1" CACHE STRING "Active KEYMAT variant (1=A,2=B,3=C)")
set_property(CACHE TUNNEL_FORGE_KEYMAT_VARIANT PROPERTY STRINGS 1 2 3)
target_compile_definitions(tunnel_engine PRIVATE TUNNEL_FORGE_KEYMAT_VARIANT=${TUNNEL_FORGE_KEYMAT_VARIANT})
