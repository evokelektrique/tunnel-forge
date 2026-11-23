/*
 * MS-CHAPv2 crypto primitives (RFC 2759): NT hash, challenge/response, 49-byte CHAP Value field.
 * Public entry point is declared in ppp_mschap.h.
 */
#include "ppp_mschap.h"

#include <mbedtls/des.h>
#include <mbedtls/md4.h>
#include <mbedtls/platform_util.h>
#include <mbedtls/sha1.h>
#include <string.h>

static void mschap_expand_des_key(const uint8_t key7[7], uint8_t key8[8]) {
  uint8_t next = 0;
  for (int i = 0; i < 7; i++) {
    uint8_t tmp = key7[i];
    key8[i] = (uint8_t)((tmp >> i) | next | 1);
    next = (uint8_t)(tmp << (7 - i));
  }
  key8[7] = (uint8_t)(next | 1);
}

static int mschap_des_encrypt_block(const uint8_t clear[8], const uint8_t key7[7], uint8_t cypher[8]) {
  uint8_t key8[8];
  mschap_expand_des_key(key7, key8);
  mbedtls_des_context ctx;
  mbedtls_des_init(&ctx);
  if (mbedtls_des_setkey_enc(&ctx, key8) != 0) {
    mbedtls_des_free(&ctx);
    return -1;
  }
  if (mbedtls_des_crypt_ecb(&ctx, clear, cypher) != 0) {
    mbedtls_des_free(&ctx);
    return -1;
  }
  mbedtls_des_free(&ctx);
  return 0;
}

static int challenge_response(const uint8_t challenge[8], const uint8_t password_hash[16], uint8_t response[24]) {
  uint8_t z[21];
  memset(z, 0, sizeof(z));
  memcpy(z, password_hash, 16);
  int rc = -1;
  if (mschap_des_encrypt_block(challenge, z + 0, response + 0) == 0 &&
      mschap_des_encrypt_block(challenge, z + 7, response + 8) == 0 &&
      mschap_des_encrypt_block(challenge, z + 14, response + 16) == 0) {
    rc = 0;
  }
  mbedtls_platform_zeroize(z, sizeof(z));
  return rc;
}

static int password_to_unicode_le(const char *pass, uint8_t *out, size_t *out_len, size_t out_cap) {
  if (pass == NULL || out == NULL || out_len == NULL)
    return -1;
  size_t n = 0;
  const unsigned char *p = (const unsigned char *)pass;
  /* RFC 2759 section 8.1: 0..256 UTF-16LE code units (<= 512 bytes); fail rather than truncating. */
  while (*p != '\0') {
    uint32_t cp = 0;
    unsigned char b0 = *p++;
    if (b0 < 0x80u) {
      cp = b0;
    } else if ((b0 & 0xE0u) == 0xC0u) {
      unsigned char b1 = *p++;
      if ((b1 & 0xC0u) != 0x80u)
        return -1;
      cp = ((uint32_t)(b0 & 0x1Fu) << 6) | (uint32_t)(b1 & 0x3Fu);
      if (cp < 0x80u)
        return -1;
    } else if ((b0 & 0xF0u) == 0xE0u) {
      unsigned char b1 = *p++;
      if ((b1 & 0xC0u) != 0x80u)
        return -1;
      unsigned char b2 = *p++;
      if ((b2 & 0xC0u) != 0x80u)
        return -1;
      cp = ((uint32_t)(b0 & 0x0Fu) << 12) | ((uint32_t)(b1 & 0x3Fu) << 6) | (uint32_t)(b2 & 0x3Fu);
      if (cp < 0x800u || (cp >= 0xD800u && cp <= 0xDFFFu))
        return -1;
    } else if ((b0 & 0xF8u) == 0xF0u) {
      unsigned char b1 = *p++;
      if ((b1 & 0xC0u) != 0x80u)
        return -1;
      unsigned char b2 = *p++;
      if ((b2 & 0xC0u) != 0x80u)
        return -1;
      unsigned char b3 = *p++;
      if ((b3 & 0xC0u) != 0x80u)
        return -1;
      cp = ((uint32_t)(b0 & 0x07u) << 18) | ((uint32_t)(b1 & 0x3Fu) << 12) | ((uint32_t)(b2 & 0x3Fu) << 6) |
           (uint32_t)(b3 & 0x3Fu);
      if (cp < 0x10000u || cp > 0x10FFFFu)
        return -1;
    } else {
      return -1;
    }

    if (cp <= 0xFFFFu) {
      if (n + 2u > out_cap)
        return -1;
      out[n++] = (uint8_t)(cp & 0xFFu);
      out[n++] = (uint8_t)((cp >> 8) & 0xFFu);
    } else {
      if (n + 4u > out_cap)
        return -1;
      uint32_t v = cp - 0x10000u;
      uint16_t hi = (uint16_t)(0xD800u + (v >> 10));
      uint16_t lo = (uint16_t)(0xDC00u + (v & 0x3FFu));
      out[n++] = (uint8_t)(hi & 0xFFu);
      out[n++] = (uint8_t)((hi >> 8) & 0xFFu);
      out[n++] = (uint8_t)(lo & 0xFFu);
      out[n++] = (uint8_t)((lo >> 8) & 0xFFu);
    }
  }
  *out_len = n;
  return 0;
}

static int nt_password_hash(const char *password, uint8_t hash[16]) {
  uint8_t unicode[512];
  size_t ulen = 0;
  int rc = -1;
  if (password_to_unicode_le(password, unicode, &ulen, sizeof(unicode)) != 0 || ulen == 0u) {
    mbedtls_platform_zeroize(unicode, sizeof(unicode));
    return -1;
  }
  mbedtls_md4_context ctx;
  mbedtls_md4_init(&ctx);
  if (mbedtls_md4_starts_ret(&ctx) == 0 && mbedtls_md4_update_ret(&ctx, unicode, ulen) == 0 &&
      mbedtls_md4_finish_ret(&ctx, hash) == 0) {
    rc = 0;
  }
  mbedtls_md4_free(&ctx);
  mbedtls_platform_zeroize(unicode, sizeof(unicode));
  return rc;
}

static int challenge_hash(const uint8_t peer_chal[16], const uint8_t auth_chal[16], const char *username,
                          uint8_t chal8[8]) {
  const char *user = username;
  const char *bs = strrchr(username, '\\');
  if (bs != NULL)
    user = bs + 1;

  mbedtls_sha1_context sha;
  mbedtls_sha1_init(&sha);
  if (mbedtls_sha1_starts_ret(&sha) != 0)
    goto fail;
  if (mbedtls_sha1_update_ret(&sha, peer_chal, 16) != 0)
    goto fail;
  if (mbedtls_sha1_update_ret(&sha, auth_chal, 16) != 0)
    goto fail;
  if (mbedtls_sha1_update_ret(&sha, (const uint8_t *)user, strlen(user)) != 0)
    goto fail;
  uint8_t d[20];
  if (mbedtls_sha1_finish_ret(&sha, d) != 0)
    goto fail;
  mbedtls_sha1_free(&sha);
  memcpy(chal8, d, 8);
  return 0;
fail:
  mbedtls_sha1_free(&sha);
  return -1;
}

static int generate_nt_response(const uint8_t auth_chal[16], const uint8_t peer_chal[16], const char *username,
                                const char *password, uint8_t nt_resp[24]) {
  uint8_t chal8[8];
  uint8_t phash[16];
  if (challenge_hash(peer_chal, auth_chal, username, chal8) != 0)
    return -1;
  if (nt_password_hash(password, phash) != 0)
    return -1;
  int rc = challenge_response(chal8, phash, nt_resp);
  mbedtls_platform_zeroize(phash, sizeof(phash));
  return rc;
}

int ppp_mschapv2_response_value(const char *username, const char *password, const uint8_t auth_challenge[16],
                                uint8_t peer_challenge[16], uint8_t value49_out[49]) {
  uint8_t nt[24];
  if (generate_nt_response(auth_challenge, peer_challenge, username, password, nt) != 0)
    return -1;
  memcpy(value49_out, peer_challenge, 16);
  memset(value49_out + 16, 0, 8);
  memcpy(value49_out + 24, nt, 24);
  value49_out[48] = 0;
  return 0;
}

int ppp_mschapv2_nt_password_hash_hash(const char *password, uint8_t hash_hash_out[16]) {
  if (password == NULL || hash_hash_out == NULL)
    return -1;
  uint8_t phash[16];
  if (nt_password_hash(password, phash) != 0)
    return -1;
  mbedtls_md4_context ctx;
  mbedtls_md4_init(&ctx);
  int rc = -1;
  if (mbedtls_md4_starts_ret(&ctx) == 0 && mbedtls_md4_update_ret(&ctx, phash, sizeof(phash)) == 0 &&
      mbedtls_md4_finish_ret(&ctx, hash_hash_out) == 0) {
    rc = 0;
  }
  mbedtls_md4_free(&ctx);
  memset(phash, 0, sizeof(phash));
  return rc;
}
