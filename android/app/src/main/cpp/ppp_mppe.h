#ifndef TUNNEL_FORGE_PPP_MPPE_H
#define TUNNEL_FORGE_PPP_MPPE_H

/* RFC 3078 / RFC 3079 MPPE-128 key derivation and stateless/stateful RC4 cipher state. */

#include <mbedtls/arc4.h>
#include <stddef.h>
#include <stdint.h>

#define PPP_PROTO_CCP 0x80fdu
#define PPP_PROTO_MPPE_DATA 0x00fdu

#define MPPE_CCP_OPT_TYPE 18u
#define MPPE_CCP_OPT_LEN 6u
#define MPPE_BIT_STATELESS 0x01000000u
#define MPPE_BIT_128 0x00000040u
#define MPPE_BIT_56 0x00000080u
#define MPPE_BIT_40 0x00000020u

#define MPPE_HDR_FLAG_FLUSHED 0x80u
#define MPPE_HDR_FLAG_ENCRYPTED 0x10u

#define PPP_MPPE_DECRYPT_OK 0
#define PPP_MPPE_DECRYPT_ERR (-1)
#define PPP_MPPE_DECRYPT_NEED_RESET (-2)

typedef struct {
  int enabled;
  int stateful;
  uint8_t tx_start_key[16];
  uint8_t rx_start_key[16];
  uint8_t tx_session_key[16];
  uint8_t rx_session_key[16];
  mbedtls_arc4_context tx_rc4;
  mbedtls_arc4_context rx_rc4;
  uint16_t tx_ccount;
  uint16_t rx_ccount;
  int tx_reset_pending;
  int rx_packets_seen;
  uint8_t ccp_reset_id;
} ppp_mppe_state_t;

void ppp_mppe_zero(ppp_mppe_state_t *s);

/** RFC 3079 section 3.3: MasterKey = SHA1(PasswordHashHash || NTResponse || Magic1)[0..15]. */
int ppp_mppe_get_master_key(const uint8_t password_hash_hash[16], const uint8_t nt_response[24],
                            uint8_t master_key_out[16]);

/** RFC 3079 section 3.3: Asymmetric start key for client (is_server=0) send or receive direction. */
int ppp_mppe_get_asymmetric_start_key(const uint8_t master_key[16], int is_send, int is_server,
                                      uint8_t start_key_out[16]);

/** RFC 3079 section 3.4: SHA1(StartKey || SHApad1 || SessionKey || SHApad2)[0..15]. */
int ppp_mppe_get_new_key_from_sha(const uint8_t start_key[16], const uint8_t session_key[16], uint8_t new_key_out[16]);

/** Initialize both TX and RX MPPE-128 cipher contexts for client mode. */
int ppp_mppe_init_client(ppp_mppe_state_t *s, const uint8_t password_hash_hash[16], const uint8_t nt_response[24],
                         int stateful);

/** Mark TX for stateful rekey on the next packet (called when peer sends CCP Reset-Request). */
void ppp_mppe_note_tx_reset(ppp_mppe_state_t *s);

/**
 * Encrypt @p plain (starting at 2-byte PPP protocol, e.g. 0x00 0x21 + IPv4) into MPPE payload
 * [2-byte MPPE header][RC4 ciphertext] written to @p out.
 * @return bytes written (2 + plain_len) on success, -1 on error.
 */
int ppp_mppe_encrypt(ppp_mppe_state_t *s, const uint8_t *plain, size_t plain_len, uint8_t *out, size_t cap);

/**
 * Decrypt MPPE payload @p in ([2-byte MPPE header][ciphertext]) into @p out.
 * @return PPP_MPPE_DECRYPT_OK (setting *out_len), PPP_MPPE_DECRYPT_NEED_RESET (stateful packet loss),
 *         or PPP_MPPE_DECRYPT_ERR on malformed input.
 */
int ppp_mppe_decrypt(ppp_mppe_state_t *s, const uint8_t *in, size_t in_len, uint8_t *out, size_t cap, size_t *out_len);

#endif
