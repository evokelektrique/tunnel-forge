/*
 * RFC 3078 / RFC 3079 MPPE-128 key derivation and RC4 encryption/decryption.
 */
#include "ppp_mppe.h"

#include "util_endian.h"

#include <mbedtls/platform_util.h>
#include <mbedtls/sha1.h>
#include <string.h>

#define MPPE_CCOUNT_MASK 0x0fffu
#define MPPE_STATELESS_MAX_SKIP 256u

static const char k_mppe_magic1[] = "This is the MPPE Master Key";
static const char k_mppe_magic2[] =
    "On the client side, this is the send key; on the server side, it is the receive key.";
static const char k_mppe_magic3[] =
    "On the client side, this is the receive key; on the server side, it is the send key.";

void ppp_mppe_zero(ppp_mppe_state_t *s) {
  if (s == NULL)
    return;
  mbedtls_arc4_free(&s->tx_rc4);
  mbedtls_arc4_free(&s->rx_rc4);
  mbedtls_platform_zeroize(s, sizeof(*s));
}

int ppp_mppe_get_master_key(const uint8_t password_hash_hash[16], const uint8_t nt_response[24],
                            uint8_t master_key_out[16]) {
  if (password_hash_hash == NULL || nt_response == NULL || master_key_out == NULL)
    return -1;
  uint8_t digest[20];
  mbedtls_sha1_context sha;
  mbedtls_sha1_init(&sha);
  int rc = -1;
  if (mbedtls_sha1_starts_ret(&sha) == 0 && mbedtls_sha1_update_ret(&sha, password_hash_hash, 16u) == 0 &&
      mbedtls_sha1_update_ret(&sha, nt_response, 24u) == 0 &&
      mbedtls_sha1_update_ret(&sha, (const uint8_t *)k_mppe_magic1, sizeof(k_mppe_magic1) - 1u) == 0 &&
      mbedtls_sha1_finish_ret(&sha, digest) == 0) {
    memcpy(master_key_out, digest, 16u);
    rc = 0;
  }
  mbedtls_sha1_free(&sha);
  mbedtls_platform_zeroize(digest, sizeof(digest));
  return rc;
}

int ppp_mppe_get_asymmetric_start_key(const uint8_t master_key[16], int is_send, int is_server,
                                      uint8_t start_key_out[16]) {
  if (master_key == NULL || start_key_out == NULL)
    return -1;
  uint8_t pad1[40];
  uint8_t pad2[40];
  memset(pad1, 0x00, sizeof(pad1));
  memset(pad2, 0xf2, sizeof(pad2));
  const char *magic = ((is_send && !is_server) || (!is_send && is_server)) ? k_mppe_magic2 : k_mppe_magic3;

  uint8_t digest[20];
  mbedtls_sha1_context sha;
  mbedtls_sha1_init(&sha);
  int rc = -1;
  if (mbedtls_sha1_starts_ret(&sha) == 0 && mbedtls_sha1_update_ret(&sha, master_key, 16u) == 0 &&
      mbedtls_sha1_update_ret(&sha, pad1, sizeof(pad1)) == 0 &&
      mbedtls_sha1_update_ret(&sha, (const uint8_t *)magic, sizeof(k_mppe_magic2) - 1u) == 0 &&
      mbedtls_sha1_update_ret(&sha, pad2, sizeof(pad2)) == 0 && mbedtls_sha1_finish_ret(&sha, digest) == 0) {
    memcpy(start_key_out, digest, 16u);
    rc = 0;
  }
  mbedtls_sha1_free(&sha);
  mbedtls_platform_zeroize(digest, sizeof(digest));
  return rc;
}

int ppp_mppe_get_new_key_from_sha(const uint8_t start_key[16], const uint8_t session_key[16], uint8_t new_key_out[16]) {
  if (start_key == NULL || session_key == NULL || new_key_out == NULL)
    return -1;
  uint8_t pad1[40];
  uint8_t pad2[40];
  memset(pad1, 0x00, sizeof(pad1));
  memset(pad2, 0xf2, sizeof(pad2));

  uint8_t digest[20];
  mbedtls_sha1_context sha;
  mbedtls_sha1_init(&sha);
  int rc = -1;
  if (mbedtls_sha1_starts_ret(&sha) == 0 && mbedtls_sha1_update_ret(&sha, start_key, 16u) == 0 &&
      mbedtls_sha1_update_ret(&sha, pad1, sizeof(pad1)) == 0 && mbedtls_sha1_update_ret(&sha, session_key, 16u) == 0 &&
      mbedtls_sha1_update_ret(&sha, pad2, sizeof(pad2)) == 0 && mbedtls_sha1_finish_ret(&sha, digest) == 0) {
    memcpy(new_key_out, digest, 16u);
    rc = 0;
  }
  mbedtls_sha1_free(&sha);
  mbedtls_platform_zeroize(digest, sizeof(digest));
  return rc;
}

static int mppe_rekey_dir(const uint8_t start_key[16], uint8_t session_key[16], mbedtls_arc4_context *rc4,
                          int initial_key) {
  uint8_t interim[16];
  if (ppp_mppe_get_new_key_from_sha(start_key, session_key, interim) != 0)
    return -1;
  if (initial_key) {
    memcpy(session_key, interim, 16u);
  } else {
    mbedtls_arc4_setup(rc4, interim, 16u);
    if (mbedtls_arc4_crypt(rc4, 16u, interim, session_key) != 0) {
      mbedtls_platform_zeroize(interim, sizeof(interim));
      return -1;
    }
  }
  mbedtls_arc4_setup(rc4, session_key, 16u);
  mbedtls_platform_zeroize(interim, sizeof(interim));
  return 0;
}

int ppp_mppe_init_client(ppp_mppe_state_t *s, const uint8_t password_hash_hash[16], const uint8_t nt_response[24],
                         int stateful) {
  if (s == NULL || password_hash_hash == NULL || nt_response == NULL)
    return -1;
  ppp_mppe_zero(s);
  mbedtls_arc4_init(&s->tx_rc4);
  mbedtls_arc4_init(&s->rx_rc4);

  uint8_t master_key[16];
  if (ppp_mppe_get_master_key(password_hash_hash, nt_response, master_key) != 0 ||
      ppp_mppe_get_asymmetric_start_key(master_key, 1, 0, s->tx_start_key) != 0 ||
      ppp_mppe_get_asymmetric_start_key(master_key, 0, 0, s->rx_start_key) != 0) {
    mbedtls_platform_zeroize(master_key, sizeof(master_key));
    ppp_mppe_zero(s);
    return -1;
  }
  mbedtls_platform_zeroize(master_key, sizeof(master_key));

  memcpy(s->tx_session_key, s->tx_start_key, 16u);
  memcpy(s->rx_session_key, s->rx_start_key, 16u);
  if (mppe_rekey_dir(s->tx_start_key, s->tx_session_key, &s->tx_rc4, 1) != 0 ||
      mppe_rekey_dir(s->rx_start_key, s->rx_session_key, &s->rx_rc4, 1) != 0) {
    ppp_mppe_zero(s);
    return -1;
  }

  s->enabled = 1;
  s->stateful = stateful ? 1 : 0;
  s->tx_ccount = 0u;
  s->rx_ccount = 0u;
  s->tx_reset_pending = 0;
  s->rx_packets_seen = 0;
  s->ccp_reset_id = 1u;
  return 0;
}

void ppp_mppe_note_tx_reset(ppp_mppe_state_t *s) {
  if (s == NULL || !s->enabled)
    return;
  if (s->stateful)
    s->tx_reset_pending = 1;
}

int ppp_mppe_encrypt(ppp_mppe_state_t *s, const uint8_t *plain, size_t plain_len, uint8_t *out, size_t cap) {
  if (s == NULL || !s->enabled || plain == NULL || out == NULL || plain_len == 0u || 2u + plain_len > cap)
    return -1;

  uint16_t ccount = s->tx_ccount;
  uint8_t flags = MPPE_HDR_FLAG_ENCRYPTED;

  if (s->stateful) {
    if (s->tx_reset_pending || (ccount & 0xffu) == 0xffu) {
      if (mppe_rekey_dir(s->tx_start_key, s->tx_session_key, &s->tx_rc4, 0) != 0)
        return -1;
      flags = (uint8_t)(flags | MPPE_HDR_FLAG_FLUSHED);
      s->tx_reset_pending = 0;
    }
  } else {
    flags = (uint8_t)(flags | MPPE_HDR_FLAG_FLUSHED);
  }

  uint16_t hdr = (uint16_t)(((uint16_t)flags << 8) | (ccount & MPPE_CCOUNT_MASK));
  util_write_be16(out, hdr);
  if (mbedtls_arc4_crypt(&s->tx_rc4, plain_len, plain, out + 2u) != 0)
    return -1;

  s->tx_ccount = (uint16_t)((ccount + 1u) & MPPE_CCOUNT_MASK);
  if (!s->stateful) {
    if (mppe_rekey_dir(s->tx_start_key, s->tx_session_key, &s->tx_rc4, 0) != 0)
      return -1;
  }
  return (int)(2u + plain_len);
}

int ppp_mppe_decrypt(ppp_mppe_state_t *s, const uint8_t *in, size_t in_len, uint8_t *out, size_t cap, size_t *out_len) {
  if (s == NULL || !s->enabled || in == NULL || out == NULL || out_len == NULL || in_len < 3u)
    return PPP_MPPE_DECRYPT_ERR;
  size_t payload_len = in_len - 2u;
  if (payload_len > cap)
    return PPP_MPPE_DECRYPT_ERR;

  uint16_t hdr = util_read_be16(in);
  uint8_t flags = (uint8_t)(hdr >> 8);
  uint16_t pkt_ccount = (uint16_t)(hdr & MPPE_CCOUNT_MASK);
  int flushed = (flags & MPPE_HDR_FLAG_FLUSHED) != 0u;
  int encrypted = (flags & MPPE_HDR_FLAG_ENCRYPTED) != 0u;

  if (!encrypted)
    return PPP_MPPE_DECRYPT_ERR;

  if (!s->stateful) {
    if (!flushed)
      return PPP_MPPE_DECRYPT_ERR;
    uint16_t delta = (uint16_t)((pkt_ccount - s->rx_ccount) & MPPE_CCOUNT_MASK);
    if (delta > MPPE_STATELESS_MAX_SKIP)
      return PPP_MPPE_DECRYPT_ERR;
    while (s->rx_ccount != pkt_ccount) {
      if (mppe_rekey_dir(s->rx_start_key, s->rx_session_key, &s->rx_rc4, 0) != 0)
        return PPP_MPPE_DECRYPT_ERR;
      s->rx_ccount = (uint16_t)((s->rx_ccount + 1u) & MPPE_CCOUNT_MASK);
    }
    if (mbedtls_arc4_crypt(&s->rx_rc4, payload_len, in + 2u, out) != 0)
      return PPP_MPPE_DECRYPT_ERR;
    s->rx_ccount = (uint16_t)((pkt_ccount + 1u) & MPPE_CCOUNT_MASK);
    s->rx_packets_seen = 1;
    if (mppe_rekey_dir(s->rx_start_key, s->rx_session_key, &s->rx_rc4, 0) != 0)
      return PPP_MPPE_DECRYPT_ERR;
    *out_len = payload_len;
    return PPP_MPPE_DECRYPT_OK;
  }

  /* Stateful mode: any mismatch requires a CCP Reset-Request unless packet carries FLUSHED resync. */
  if (pkt_ccount != s->rx_ccount) {
    if (!flushed)
      return PPP_MPPE_DECRYPT_NEED_RESET;
    uint16_t delta = (uint16_t)((pkt_ccount - s->rx_ccount) & MPPE_CCOUNT_MASK);
    if (delta > MPPE_STATELESS_MAX_SKIP)
      return PPP_MPPE_DECRYPT_NEED_RESET;
    /* Advance across any 0xFF boundaries skipped during loss. */
    while (s->rx_ccount != pkt_ccount) {
      if ((s->rx_ccount & 0xffu) == 0xffu) {
        if (mppe_rekey_dir(s->rx_start_key, s->rx_session_key, &s->rx_rc4, 0) != 0)
          return PPP_MPPE_DECRYPT_ERR;
      }
      s->rx_ccount = (uint16_t)((s->rx_ccount + 1u) & MPPE_CCOUNT_MASK);
    }
  }

  /* Avoid double-rekeying packet 0 when Windows peers set FLUSHED on the initial packet. */
  if (flushed && (pkt_ccount != 0u || s->rx_packets_seen)) {
    if (mppe_rekey_dir(s->rx_start_key, s->rx_session_key, &s->rx_rc4, 0) != 0)
      return PPP_MPPE_DECRYPT_ERR;
  }

  if (mbedtls_arc4_crypt(&s->rx_rc4, payload_len, in + 2u, out) != 0)
    return PPP_MPPE_DECRYPT_ERR;

  s->rx_ccount = (uint16_t)((pkt_ccount + 1u) & MPPE_CCOUNT_MASK);
  s->rx_packets_seen = 1;
  *out_len = payload_len;
  return PPP_MPPE_DECRYPT_OK;
}
