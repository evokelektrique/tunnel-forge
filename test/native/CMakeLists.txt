cmake_minimum_required(VERSION 3.22)
project(tunnel_forge_native_test C)

set(CMAKE_C_STANDARD 99)
option(TUNNEL_FORGE_NATIVE_PROTOCOL_TESTS "Build host tests for IKE, ESP, L2TP, PPP and MPPE" ON)

add_executable(test_endian test_endian.c ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_endian PRIVATE ../../android/app/src/main/cpp)

enable_testing()
add_test(NAME endian COMMAND test_endian)

add_executable(test_l2tp_avps test_l2tp_avps.c ../../android/app/src/main/cpp/l2tp_avps.c
 ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_l2tp_avps PRIVATE ../../android/app/src/main/cpp)
add_test(NAME l2tp_avps COMMAND test_l2tp_avps)

add_executable(test_ppp_lcp test_ppp_lcp.c
 ../../android/app/src/main/cpp/ppp_wire.c
 ../../android/app/src/main/cpp/ipv4_dataplane.c
 ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_ppp_lcp PRIVATE ../../android/app/src/main/cpp)
add_test(NAME ppp_lcp COMMAND test_ppp_lcp)

add_executable(test_ppp_ipcp test_ppp_ipcp.c
 ../../android/app/src/main/cpp/ppp_wire.c
 ../../android/app/src/main/cpp/ipv4_dataplane.c
 ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_ppp_ipcp PRIVATE ../../android/app/src/main/cpp)
add_test(NAME ppp_ipcp COMMAND test_ppp_ipcp)

add_executable(test_ppp_mschap_failure test_ppp_mschap_failure.c)
target_include_directories(test_ppp_mschap_failure PRIVATE ../../android/app/src/main/cpp)
add_test(NAME ppp_mschap_failure COMMAND test_ppp_mschap_failure)

add_executable(test_ppp_frame test_ppp_frame.c
 ../../android/app/src/main/cpp/ppp_wire.c
 ../../android/app/src/main/cpp/ipv4_dataplane.c
 ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_ppp_frame PRIVATE ../../android/app/src/main/cpp)
add_test(NAME ppp_frame COMMAND test_ppp_frame)

add_executable(test_nat_t_keepalive test_nat_t_keepalive.c ../../android/app/src/main/cpp/nat_t_keepalive.c)
target_include_directories(test_nat_t_keepalive PRIVATE ../../android/app/src/main/cpp)
add_test(NAME nat_t_keepalive COMMAND test_nat_t_keepalive)

add_executable(test_tunnel_liveness test_tunnel_liveness.c ../../android/app/src/main/cpp/tunnel_liveness.c)
target_include_directories(test_tunnel_liveness PRIVATE ../../android/app/src/main/cpp)
add_test(NAME tunnel_liveness COMMAND test_tunnel_liveness)

add_executable(test_packet_endpoint test_packet_endpoint.c ../../android/app/src/main/cpp/packet_endpoint.c)
target_include_directories(test_packet_endpoint PRIVATE ../../android/app/src/main/cpp)
find_package(Threads REQUIRED)
target_link_libraries(test_packet_endpoint PRIVATE Threads::Threads)
add_test(NAME packet_endpoint COMMAND test_packet_endpoint)

add_executable(test_ipv4_dataplane test_ipv4_dataplane.c
 ../../android/app/src/main/cpp/ipv4_dataplane.c
 ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_ipv4_dataplane PRIVATE ../../android/app/src/main/cpp)
add_test(NAME ipv4_dataplane COMMAND test_ipv4_dataplane)

add_executable(test_pptp_gre test_pptp_gre.c
 ../../android/app/src/main/cpp/pptp_gre.c
 ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_pptp_gre PRIVATE ../../android/app/src/main/cpp)
add_test(NAME pptp_gre COMMAND test_pptp_gre)

add_executable(test_pptp_control test_pptp_control.c
 ../../android/app/src/main/cpp/pptp_wire.c
 ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_pptp_control PRIVATE ../../android/app/src/main/cpp)
add_test(NAME pptp_control COMMAND test_pptp_control)

# Optional production-source checks use mbedTLS headers from an Android build.
if(TUNNEL_FORGE_MBEDTLS_INCLUDE_DIR)
  get_filename_component(TUNNEL_FORGE_MBEDTLS_SOURCE_DIR "${TUNNEL_FORGE_MBEDTLS_INCLUDE_DIR}" DIRECTORY)
endif()
if(TUNNEL_FORGE_NATIVE_PROTOCOL_TESTS OR TUNNEL_FORGE_MBEDTLS_INCLUDE_DIR)
  include(../../android/app/src/main/cpp/mbedtls.cmake)
  if(WIN32)
    add_library(tf_win32_compat STATIC stubs/win32/win32_compat.c)
    target_include_directories(tf_win32_compat PUBLIC stubs/win32)
    target_link_libraries(tf_win32_compat PUBLIC ws2_32 bcrypt)
  endif()
  foreach(protocol ppp ike l2tp)
    add_executable(test_${protocol}_production test_${protocol}_production.c ../../android/app/src/main/cpp/util_endian.c)
    target_include_directories(test_${protocol}_production PRIVATE stubs ${mbedtls_SOURCE_DIR}/include)
    target_compile_definitions(test_${protocol}_production PRIVATE _DEFAULT_SOURCE)
    if(MSVC)
      target_compile_options(test_${protocol}_production PRIVATE /Gy)
      target_link_options(test_${protocol}_production PRIVATE /OPT:REF)
    elseif(APPLE)
      target_compile_options(test_${protocol}_production PRIVATE -ffunction-sections -fdata-sections)
      target_link_options(test_${protocol}_production PRIVATE -Wl,-dead_strip)
    else()
      target_compile_options(test_${protocol}_production PRIVATE -ffunction-sections -fdata-sections)
      target_link_options(test_${protocol}_production PRIVATE -Wl,--gc-sections)
    endif()
    if(WIN32)
      target_link_libraries(test_${protocol}_production PRIVATE tf_win32_compat)
    endif()
    add_test(NAME ${protocol}_production COMMAND test_${protocol}_production)
  endforeach()
  target_link_libraries(test_ike_production PRIVATE mbedcrypto)
  if(WIN32)
    target_sources(test_ike_production PRIVATE ../../android/app/src/main/cpp/modp2048_data.c)
  endif()
  target_link_libraries(test_ppp_production PRIVATE mbedcrypto)
  target_sources(test_ppp_production PRIVATE
    ../../android/app/src/main/cpp/nat_t_keepalive.c
    ../../android/app/src/main/cpp/ipv4_dataplane.c
    ../../android/app/src/main/cpp/ppp_wire.c
    ../../android/app/src/main/cpp/ppp_mschap.c
    ../../android/app/src/main/cpp/ppp_mppe.c)
  target_sources(test_l2tp_production PRIVATE ../../android/app/src/main/cpp/l2tp_avps.c ../../android/app/src/main/cpp/nat_t_keepalive.c)

  add_executable(test_esp_udp test_esp_udp.c
    ../../android/app/src/main/cpp/esp_udp.c
    ../../android/app/src/main/cpp/nat_t_keepalive.c
    ../../android/app/src/main/cpp/util_endian.c)
  target_include_directories(test_esp_udp PRIVATE stubs ../../android/app/src/main/cpp)
  target_link_libraries(test_esp_udp PRIVATE mbedcrypto)
  if(WIN32)
    target_link_libraries(test_esp_udp PRIVATE tf_win32_compat)
  endif()
  add_test(NAME esp_udp COMMAND test_esp_udp)

  add_executable(test_ppp_mppe test_ppp_mppe.c
    ../../android/app/src/main/cpp/ppp_mppe.c
    ../../android/app/src/main/cpp/ppp_mschap.c
    ../../android/app/src/main/cpp/util_endian.c)
  target_include_directories(test_ppp_mppe PRIVATE ../../android/app/src/main/cpp ${mbedtls_SOURCE_DIR}/include)
  target_link_libraries(test_ppp_mppe PRIVATE mbedcrypto)
  add_test(NAME ppp_mppe COMMAND test_ppp_mppe)
endif()
