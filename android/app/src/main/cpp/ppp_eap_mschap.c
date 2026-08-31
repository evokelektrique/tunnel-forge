#include "ppp_eap_mschap.h"

#include <string.h>

static uint16_t eap_read_be16(const uint8_t *p) { return (uint16_t)(((uint16_t)p[0] << 8) | p[1]); }

static void eap_write_be16(uint8_t *p, uint16_t value) {
  p[0] = (uint8_t)(value >> 8);
  p[1] = (uint8_t)(value & 0xffu);
}

static int eap_packet_length(const uint8_t *eap, size_t len, uint16_t *packet_len_out) {
  if (eap == NULL || packet_len_out == NULL || len < 4u)
    return -1;
  uint16_t packet_len = eap_read_be16(eap + 2u);
  if (packet_len < 4u || (size_t)packet_len > len)
    return -1;
  *packet_len_out = packet_len;
  return 0;
}

int ppp_eap_parse_identity_request(const uint8_t *eap, size_t len, uint8_t *identifier_out) {
  uint16_t packet_len = 0u;
  if (identifier_out == NULL || eap_packet_length(eap, len, &packet_len) != 0 || packet_len < 5u)
    return -1;
  if (eap[0] != PPP_EAP_CODE_REQUEST || eap[4] != PPP_EAP_TYPE_IDENTITY)
    return -1;
  *identifier_out = eap[1];
  return 0;
}

int ppp_eap_build_identity_response(uint8_t *out, size_t cap, uint8_t identifier, const char *username) {
  if (out == NULL || username == NULL)
    return -1;
  size_t username_len = strlen(username);
  size_t packet_len = 5u + username_len;
  if (packet_len > cap || packet_len > UINT16_MAX)
    return -1;
  out[0] = PPP_EAP_CODE_RESPONSE;
  out[1] = identifier;
  eap_write_be16(out + 2u, (uint16_t)packet_len);
  out[4] = PPP_EAP_TYPE_IDENTITY;
  memcpy(out + 5u, username, username_len);
  return (int)packet_len;
}

int ppp_eap_mschapv2_parse_challenge(const uint8_t *eap, size_t len, ppp_eap_mschapv2_challenge_t *out) {
  uint16_t packet_len = 0u;
  if (out == NULL || eap_packet_length(eap, len, &packet_len) != 0 || packet_len < 26u)
    return -1;
  if (eap[0] != PPP_EAP_CODE_REQUEST || eap[4] != PPP_EAP_TYPE_MSCHAPV2 || eap[5] != PPP_EAP_MSCHAPV2_OP_CHALLENGE)
    return -1;
  uint16_t ms_len = eap_read_be16(eap + 7u);
  if (ms_len != (uint16_t)(packet_len - 5u) || eap[9] != 16u)
    return -1;
  out->eap_identifier = eap[1];
  out->mschapv2_identifier = eap[6];
  out->challenge = eap + 10u;
  return 0;
}

int ppp_eap_mschapv2_build_response(uint8_t *out, size_t cap, uint8_t eap_identifier, uint8_t mschapv2_identifier,
                                    const uint8_t value49[49], const char *username) {
  if (out == NULL || value49 == NULL || username == NULL)
    return -1;
  size_t username_len = strlen(username);
  size_t packet_len = 10u + 49u + username_len;
  if (packet_len > cap || packet_len > UINT16_MAX)
    return -1;
  out[0] = PPP_EAP_CODE_RESPONSE;
  out[1] = eap_identifier;
  eap_write_be16(out + 2u, (uint16_t)packet_len);
  out[4] = PPP_EAP_TYPE_MSCHAPV2;
  out[5] = PPP_EAP_MSCHAPV2_OP_RESPONSE;
  out[6] = mschapv2_identifier;
  eap_write_be16(out + 7u, (uint16_t)(packet_len - 5u));
  out[9] = 49u;
  memcpy(out + 10u, value49, 49u);
  memcpy(out + 59u, username, username_len);
  return (int)packet_len;
}

int ppp_eap_mschapv2_parse_result(const uint8_t *eap, size_t len, ppp_eap_mschapv2_result_t *out) {
  uint16_t packet_len = 0u;
  if (out == NULL || eap_packet_length(eap, len, &packet_len) != 0 || packet_len < 9u)
    return -1;
  if (eap[0] != PPP_EAP_CODE_REQUEST || eap[4] != PPP_EAP_TYPE_MSCHAPV2 ||
      (eap[5] != PPP_EAP_MSCHAPV2_OP_SUCCESS && eap[5] != PPP_EAP_MSCHAPV2_OP_FAILURE))
    return -1;
  if (eap_read_be16(eap + 7u) != (uint16_t)(packet_len - 5u))
    return -1;
  out->eap_identifier = eap[1];
  out->opcode = eap[5];
  out->message = eap + 9u;
  out->message_len = (size_t)packet_len - 9u;
  return 0;
}

static int eap_hex_value(uint8_t c) {
  if (c >= (uint8_t)'0' && c <= (uint8_t)'9')
    return (int)(c - (uint8_t)'0');
  if (c >= (uint8_t)'A' && c <= (uint8_t)'F')
    return 10 + (int)(c - (uint8_t)'A');
  return -1;
}

int ppp_eap_mschapv2_verify_authenticator_response(const uint8_t *message, size_t message_len,
                                                   const uint8_t expected_digest[20]) {
  if (message == NULL || expected_digest == NULL || message_len < 42u || message[0] != (uint8_t)'S' ||
      message[1] != (uint8_t)'=')
    return -1;
  unsigned int difference = 0u;
  for (size_t i = 0; i < 20u; i++) {
    int high = eap_hex_value(message[2u + (i * 2u)]);
    int low = eap_hex_value(message[3u + (i * 2u)]);
    if (high < 0 || low < 0)
      return -1;
    difference |= (unsigned int)(((high << 4) | low) ^ expected_digest[i]);
  }
  return difference == 0u ? 0 : -1;
}

int ppp_eap_mschapv2_build_result_response(uint8_t out[6], uint8_t eap_identifier, uint8_t opcode) {
  if (out == NULL || (opcode != PPP_EAP_MSCHAPV2_OP_SUCCESS && opcode != PPP_EAP_MSCHAPV2_OP_FAILURE))
    return -1;
  out[0] = PPP_EAP_CODE_RESPONSE;
  out[1] = eap_identifier;
  eap_write_be16(out + 2u, 6u);
  out[4] = PPP_EAP_TYPE_MSCHAPV2;
  out[5] = opcode;
  return 6;
}

int ppp_eap_parse_terminal(const uint8_t *eap, size_t len, uint8_t *code_out, uint8_t *identifier_out) {
  uint16_t packet_len = 0u;
  if (code_out == NULL || identifier_out == NULL || eap_packet_length(eap, len, &packet_len) != 0 || packet_len != 4u)
    return -1;
  if (eap[0] != PPP_EAP_CODE_SUCCESS && eap[0] != PPP_EAP_CODE_FAILURE)
    return -1;
  *code_out = eap[0];
  *identifier_out = eap[1];
  return 0;
}
