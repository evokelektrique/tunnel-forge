cmake_minimum_required(VERSION 3.22)
project(tunnel_forge_native_test C)

set(CMAKE_C_STANDARD 99)

add_executable(test_endian test_endian.c ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_endian PRIVATE ../../android/app/src/main/cpp)

enable_testing()
add_test(NAME endian COMMAND test_endian)

add_executable(test_l2tp_avps test_l2tp_avps.c ../../android/app/src/main/cpp/l2tp_avps.c
 ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_l2tp_avps PRIVATE ../../android/app/src/main/cpp)
add_test(NAME l2tp_avps COMMAND test_l2tp_avps)

add_executable(test_ppp_lcp test_ppp_lcp.c ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_ppp_lcp PRIVATE ../../android/app/src/main/cpp)
add_test(NAME ppp_lcp COMMAND test_ppp_lcp)

add_executable(test_ppp_ipcp test_ppp_ipcp.c ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_ppp_ipcp PRIVATE ../../android/app/src/main/cpp)
add_test(NAME ppp_ipcp COMMAND test_ppp_ipcp)

add_executable(test_ppp_mschap_failure test_ppp_mschap_failure.c)
target_include_directories(test_ppp_mschap_failure PRIVATE ../../android/app/src/main/cpp)
add_test(NAME ppp_mschap_failure COMMAND test_ppp_mschap_failure)

add_executable(test_ppp_frame test_ppp_frame.c)
add_test(NAME ppp_frame COMMAND test_ppp_frame)

add_executable(test_nat_t_keepalive test_nat_t_keepalive.c ../../android/app/src/main/cpp/nat_t_keepalive.c)
target_include_directories(test_nat_t_keepalive PRIVATE ../../android/app/src/main/cpp)
add_test(NAME nat_t_keepalive COMMAND test_nat_t_keepalive)

add_executable(test_packet_endpoint test_packet_endpoint.c ../../android/app/src/main/cpp/packet_endpoint.c)
target_include_directories(test_packet_endpoint PRIVATE ../../android/app/src/main/cpp)
target_link_libraries(test_packet_endpoint PRIVATE pthread)
add_test(NAME packet_endpoint COMMAND test_packet_endpoint)

add_executable(test_ipv4_dataplane test_ipv4_dataplane.c
 ../../android/app/src/main/cpp/ipv4_dataplane.c
 ../../android/app/src/main/cpp/util_endian.c)
target_include_directories(test_ipv4_dataplane PRIVATE ../../android/app/src/main/cpp)
add_test(NAME ipv4_dataplane COMMAND test_ipv4_dataplane)

# Optional production-source checks use mbedTLS headers from an Android build.
if(TUNNEL_FORGE_MBEDTLS_INCLUDE_DIR)
  foreach(protocol ppp ike l2tp)
    add_executable(test_${protocol}_production test_${protocol}_production.c ../../android/app/src/main/cpp/util_endian.c)
    target_include_directories(test_${protocol}_production PRIVATE stubs ${TUNNEL_FORGE_MBEDTLS_INCLUDE_DIR})
    target_compile_definitions(test_${protocol}_production PRIVATE _DEFAULT_SOURCE)
    target_compile_options(test_${protocol}_production PRIVATE -ffunction-sections -fdata-sections)
    target_link_options(test_${protocol}_production PRIVATE -Wl,--gc-sections)
    add_test(NAME ${protocol}_production COMMAND test_${protocol}_production)
  endforeach()
  get_filename_component(mbedtls_test_source "${TUNNEL_FORGE_MBEDTLS_INCLUDE_DIR}" DIRECTORY)
  set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
  set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
  set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
  set(CMAKE_POLICY_VERSION_MINIMUM 3.5)
  add_subdirectory("${mbedtls_test_source}" "${CMAKE_CURRENT_BINARY_DIR}/mbedtls" EXCLUDE_FROM_ALL)
  target_link_libraries(test_ike_production PRIVATE mbedcrypto)
  target_link_libraries(test_ppp_production PRIVATE mbedcrypto)
  target_sources(test_ppp_production PRIVATE ../../android/app/src/main/cpp/nat_t_keepalive.c)
  target_sources(test_l2tp_production PRIVATE ../../android/app/src/main/cpp/l2tp_avps.c ../../android/app/src/main/cpp/nat_t_keepalive.c)
endif()
