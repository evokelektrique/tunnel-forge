#ifndef TUNNEL_FORGE_PPP_EAP_MSCHAP_H
#define TUNNEL_FORGE_PPP_EAP_MSCHAP_H

#include <stddef.h>
#include <stdint.h>

#define PPP_EAP_CODE_REQUEST 1u
#define PPP_EAP_CODE_RESPONSE 2u
#define PPP_EAP_CODE_SUCCESS 3u
#define PPP_EAP_CODE_FAILURE 4u
#define PPP_EAP_TYPE_IDENTITY 1u
#define PPP_EAP_TYPE_MSCHAPV2 26u
#define PPP_EAP_MSCHAPV2_OP_CHALLENGE 1u
#define PPP_EAP_MSCHAPV2_OP_RESPONSE 2u
#define PPP_EAP_MSCHAPV2_OP_SUCCESS 3u
#define PPP_EAP_MSCHAPV2_OP_FAILURE 4u

typedef struct {
  uint8_t eap_identifier;
  uint8_t mschapv2_identifier;
  const uint8_t *challenge;
} ppp_eap_mschapv2_challenge_t;

typedef struct {
  uint8_t eap_identifier;
  uint8_t opcode;
  const uint8_t *message;
  size_t message_len;
} ppp_eap_mschapv2_result_t;

/** Parse an EAP-Request/Identity and return the identifier to echo in the response. */
int ppp_eap_parse_identity_request(const uint8_t *eap, size_t len, uint8_t *identifier_out);

/** Build an EAP-Response/Identity containing the PPP username. */
int ppp_eap_build_identity_response(uint8_t *out, size_t cap, uint8_t identifier, const char *username);

/** Parse an EAP-Request/MS-CHAPv2 Challenge. The input starts at the EAP Code field. */
int ppp_eap_mschapv2_parse_challenge(const uint8_t *eap, size_t len, ppp_eap_mschapv2_challenge_t *out);

/** Build an EAP-Response/MS-CHAPv2 Response around the RFC 2759 49-byte response value. */
int ppp_eap_mschapv2_build_response(uint8_t *out, size_t cap, uint8_t eap_identifier, uint8_t mschapv2_identifier,
                                    const uint8_t value49[49], const char *username);

/** Parse an EAP-Request/MS-CHAPv2 Success or Failure packet. */
int ppp_eap_mschapv2_parse_result(const uint8_t *eap, size_t len, ppp_eap_mschapv2_result_t *out);

/** Verify the RFC 2759 `S=` value at the start of an MS-CHAPv2 Success message. */
int ppp_eap_mschapv2_verify_authenticator_response(const uint8_t *message, size_t message_len,
                                                   const uint8_t expected_digest[20]);

/** Build the six-byte EAP-Response/MS-CHAPv2 Success or Failure acknowledgement. */
int ppp_eap_mschapv2_build_result_response(uint8_t out[6], uint8_t eap_identifier, uint8_t opcode);

/** Parse a four-byte terminal EAP-Success or EAP-Failure packet. */
int ppp_eap_parse_terminal(const uint8_t *eap, size_t len, uint8_t *code_out, uint8_t *identifier_out);

#endif
