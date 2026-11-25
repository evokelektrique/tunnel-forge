cmake_minimum_required(VERSION 3.22)
project(tunnel_forge_native_test C)

set(CMAKE_C_STANDARD 99)
option(TUNNEL_FORGE_NATIVE_PROTOCOL_TESTS "Build host tests for IKE, ESP, L2TP, PPP and MPPE" ON)

enable_testing()

add_library(tf_native_common STATIC
  ../../android/app/src/main/cpp/util_endian.c
  ../../android/app/src/main/cpp/ipv4_dataplane.c
  ../../android/app/src/main/cpp/nat_t_keepalive.c
  ../../android/app/src/main/cpp/ppp_wire.c
  ../../android/app/src/main/cpp/l2tp_avps.c
)
target_include_directories(tf_native_common PUBLIC ../../android/app/src/main/cpp)

add_executable(test_l2tp_avps test_l2tp_avps.c)
target_link_libraries(test_l2tp_avps PRIVATE tf_native_common)
add_test(NAME l2tp_avps COMMAND test_l2tp_avps)

add_executable(test_ppp_lcp test_ppp_lcp.c)
target_link_libraries(test_ppp_lcp PRIVATE tf_native_common)
add_test(NAME ppp_lcp COMMAND test_ppp_lcp)

add_executable(test_ppp_ipcp test_ppp_ipcp.c)
target_link_libraries(test_ppp_ipcp PRIVATE tf_native_common)
add_test(NAME ppp_ipcp COMMAND test_ppp_ipcp)

add_executable(test_ppp_frame test_ppp_frame.c)
target_link_libraries(test_ppp_frame PRIVATE tf_native_common)
add_test(NAME ppp_frame COMMAND test_ppp_frame)

add_executable(test_nat_t_keepalive test_nat_t_keepalive.c)
target_link_libraries(test_nat_t_keepalive PRIVATE tf_native_common)
add_test(NAME nat_t_keepalive COMMAND test_nat_t_keepalive)

add_executable(test_tunnel_liveness test_tunnel_liveness.c ../../android/app/src/main/cpp/tunnel_liveness.c)
target_include_directories(test_tunnel_liveness PRIVATE ../../android/app/src/main/cpp)
add_test(NAME tunnel_liveness COMMAND test_tunnel_liveness)

add_executable(test_packet_endpoint test_packet_endpoint.c ../../android/app/src/main/cpp/packet_endpoint.c)
target_include_directories(test_packet_endpoint PRIVATE ../../android/app/src/main/cpp)
find_package(Threads REQUIRED)
target_link_libraries(test_packet_endpoint PRIVATE Threads::Threads)
add_test(NAME packet_endpoint COMMAND test_packet_endpoint)

add_executable(test_ipv4_dataplane test_ipv4_dataplane.c)
target_link_libraries(test_ipv4_dataplane PRIVATE tf_native_common)
add_test(NAME ipv4_dataplane COMMAND test_ipv4_dataplane)

add_executable(test_pptp_gre test_pptp_gre.c ../../android/app/src/main/cpp/pptp_gre.c)
target_link_libraries(test_pptp_gre PRIVATE tf_native_common)
add_test(NAME pptp_gre COMMAND test_pptp_gre)

add_executable(test_pptp_control test_pptp_control.c ../../android/app/src/main/cpp/pptp_wire.c)
target_link_libraries(test_pptp_control PRIVATE tf_native_common)
if(NOT WIN32)
  target_sources(test_pptp_control PRIVATE ../../android/app/src/main/cpp/pptp_root.c)
  target_include_directories(test_pptp_control PRIVATE stubs)
  target_compile_definitions(test_pptp_control PRIVATE TF_TEST_PPTP_ROOT=1 _DEFAULT_SOURCE _GNU_SOURCE)
endif()
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
  add_library(tf_native_ppp_crypto STATIC
    ../../android/app/src/main/cpp/ppp_mschap.c
    ../../android/app/src/main/cpp/ppp_mppe.c
  )
  target_include_directories(tf_native_ppp_crypto PUBLIC ../../android/app/src/main/cpp ${mbedtls_SOURCE_DIR}/include)
  target_link_libraries(tf_native_ppp_crypto PUBLIC mbedcrypto tf_native_common)

  foreach(protocol ppp ike l2tp)
    add_executable(test_${protocol}_production test_${protocol}_production.c)
    target_include_directories(test_${protocol}_production PRIVATE stubs ${mbedtls_SOURCE_DIR}/include)
    target_compile_definitions(test_${protocol}_production PRIVATE _DEFAULT_SOURCE)
    target_link_libraries(test_${protocol}_production PRIVATE tf_native_common)
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
  target_link_libraries(test_ppp_production PRIVATE tf_native_ppp_crypto mbedcrypto)

  add_executable(test_esp_udp test_esp_udp.c ../../android/app/src/main/cpp/esp_udp.c)
  target_include_directories(test_esp_udp PRIVATE stubs ../../android/app/src/main/cpp)
  target_link_libraries(test_esp_udp PRIVATE tf_native_common mbedcrypto)
  if(WIN32)
    target_link_libraries(test_esp_udp PRIVATE tf_win32_compat)
  endif()
  add_test(NAME esp_udp COMMAND test_esp_udp)

  add_executable(test_ppp_mppe test_ppp_mppe.c)
  target_link_libraries(test_ppp_mppe PRIVATE tf_native_ppp_crypto mbedcrypto)
  add_test(NAME ppp_mppe COMMAND test_ppp_mppe)
endif()
