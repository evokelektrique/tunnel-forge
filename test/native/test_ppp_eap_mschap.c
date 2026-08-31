#include "ppp_eap_mschap.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int test_identity_exchange(void) {
  const uint8_t request[] = {PPP_EAP_CODE_REQUEST, 3u, 0u, 9u, PPP_EAP_TYPE_IDENTITY, 'N', 'a', 'm', 'e'};
  uint8_t identifier = 0u;
  if (ppp_eap_parse_identity_request(request, sizeof(request), &identifier) != 0 || identifier != 3u)
    return 1;
  uint8_t response[32];
  int n = ppp_eap_build_identity_response(response, sizeof(response), identifier, "alice");
  const uint8_t expected[] = {PPP_EAP_CODE_RESPONSE, 3u, 0u, 10u, PPP_EAP_TYPE_IDENTITY, 'a', 'l', 'i', 'c', 'e'};
  if (n != (int)sizeof(expected) || memcmp(response, expected, sizeof(expected)) != 0)
    return 2;
  if (ppp_eap_build_identity_response(response, 9u, identifier, "alice") >= 0)
    return 3;
  uint8_t malformed[sizeof(request)];
  memcpy(malformed, request, sizeof(request));
  malformed[3] = 10u;
  if (ppp_eap_parse_identity_request(malformed, sizeof(malformed), &identifier) == 0)
    return 4;
  malformed[3] = (uint8_t)sizeof(malformed);
  malformed[4] = PPP_EAP_TYPE_MSCHAPV2;
  if (ppp_eap_parse_identity_request(malformed, sizeof(malformed), &identifier) == 0)
    return 5;
  return 0;
}

static int test_parse_challenge(void) {
  uint8_t eap[42] = {PPP_EAP_CODE_REQUEST,          7, 0, 42, PPP_EAP_TYPE_MSCHAPV2,
                     PPP_EAP_MSCHAPV2_OP_CHALLENGE, 9, 0, 37, 16};
  for (size_t i = 0; i < 16u; i++)
    eap[10u + i] = (uint8_t)(0xa0u + i);
  memcpy(eap + 26u, "auth.example.test", 16u);
  ppp_eap_mschapv2_challenge_t parsed;
  if (ppp_eap_mschapv2_parse_challenge(eap, sizeof(eap), &parsed) != 0)
    return 1;
  if (parsed.eap_identifier != 7u || parsed.mschapv2_identifier != 9u)
    return 2;
  if (memcmp(parsed.challenge, eap + 10u, 16u) != 0)
    return 3;
  eap[9] = 15u;
  if (ppp_eap_mschapv2_parse_challenge(eap, sizeof(eap), &parsed) == 0)
    return 4;
  eap[9] = 16u;
  eap[8]--;
  if (ppp_eap_mschapv2_parse_challenge(eap, sizeof(eap), &parsed) == 0)
    return 5;
  return 0;
}

static int test_build_response(void) {
  uint8_t value49[49];
  for (size_t i = 0; i < sizeof(value49); i++)
    value49[i] = (uint8_t)i;
  uint8_t out[128];
  int n = ppp_eap_mschapv2_build_response(out, sizeof(out), 7u, 9u, value49, "alice");
  if (n != 64)
    return 1;
  if (out[0] != PPP_EAP_CODE_RESPONSE || out[1] != 7u || out[2] != 0u || out[3] != 64u)
    return 2;
  if (out[4] != PPP_EAP_TYPE_MSCHAPV2 || out[5] != PPP_EAP_MSCHAPV2_OP_RESPONSE || out[6] != 9u)
    return 3;
  if (out[7] != 0u || out[8] != 59u || out[9] != 49u)
    return 4;
  if (memcmp(out + 10u, value49, sizeof(value49)) != 0 || memcmp(out + 59u, "alice", 5u) != 0)
    return 5;
  return 0;
}

static int test_result_exchange(void) {
  static const uint8_t message[] = "S=000102030405060708090A0B0C0D0E0F10111213";
  uint8_t request[9u + sizeof(message) - 1u];
  size_t request_len = sizeof(request);
  request[0] = PPP_EAP_CODE_REQUEST;
  request[1] = 8u;
  request[2] = (uint8_t)(request_len >> 8);
  request[3] = (uint8_t)request_len;
  request[4] = PPP_EAP_TYPE_MSCHAPV2;
  request[5] = PPP_EAP_MSCHAPV2_OP_SUCCESS;
  request[6] = 9u;
  request[7] = (uint8_t)((request_len - 5u) >> 8);
  request[8] = (uint8_t)(request_len - 5u);
  memcpy(request + 9u, message, sizeof(message) - 1u);
  ppp_eap_mschapv2_result_t parsed;
  if (ppp_eap_mschapv2_parse_result(request, request_len, &parsed) != 0)
    return 1;
  if (parsed.eap_identifier != 8u || parsed.opcode != PPP_EAP_MSCHAPV2_OP_SUCCESS ||
      parsed.message_len != sizeof(message) - 1u)
    return 2;
  uint8_t response[6];
  if (ppp_eap_mschapv2_build_result_response(response, 8u, parsed.opcode) != 6)
    return 3;
  const uint8_t expected[6] = {2u, 8u, 0u, 6u, 26u, 3u};
  if (memcmp(response, expected, sizeof(expected)) != 0)
    return 4;
  const uint8_t expected_digest[20] = {0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
                                       0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13};
  if (ppp_eap_mschapv2_verify_authenticator_response(parsed.message, parsed.message_len, expected_digest) != 0)
    return 5;
  request[11] = (uint8_t)'F';
  if (ppp_eap_mschapv2_verify_authenticator_response(parsed.message, parsed.message_len, expected_digest) == 0)
    return 6;
  request[11] = (uint8_t)'4';
  request[8]--;
  if (ppp_eap_mschapv2_parse_result(request, request_len, &parsed) == 0)
    return 7;
  return 0;
}

static int test_terminal(void) {
  uint8_t terminal[4] = {PPP_EAP_CODE_SUCCESS, 8u, 0u, 4u};
  uint8_t code = 0u;
  uint8_t identifier = 0u;
  if (ppp_eap_parse_terminal(terminal, sizeof(terminal), &code, &identifier) != 0)
    return 1;
  if (code != PPP_EAP_CODE_SUCCESS || identifier != 8u)
    return 2;
  terminal[3] = 5u;
  if (ppp_eap_parse_terminal(terminal, sizeof(terminal), &code, &identifier) == 0)
    return 3;
  return 0;
}

int main(void) {
  int rc = test_identity_exchange();
  if (rc != 0) {
    fprintf(stderr, "test_identity_exchange failed: %d\n", rc);
    return rc;
  }
  rc = test_parse_challenge();
  if (rc != 0) {
    fprintf(stderr, "test_parse_challenge failed: %d\n", rc);
    return 10 + rc;
  }
  rc = test_build_response();
  if (rc != 0) {
    fprintf(stderr, "test_build_response failed: %d\n", rc);
    return 20 + rc;
  }
  rc = test_result_exchange();
  if (rc != 0) {
    fprintf(stderr, "test_result_exchange failed: %d\n", rc);
    return 30 + rc;
  }
  rc = test_terminal();
  if (rc != 0) {
    fprintf(stderr, "test_terminal failed: %d\n", rc);
    return 40 + rc;
  }
  return 0;
}
