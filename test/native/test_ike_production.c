#include "../../android/app/src/main/cpp/ikev1.c"
#include <assert.h>
int main(void) {
  uint8_t sa[256];
  size_t n = build_p1_sa(sa, sizeof(sa));
  assert(n > 0 && sa[15] == 4);
  size_t off = 16;
  const unsigned groups[] = {14, 14, 2, 2};
  for (unsigned i = 0; i < 4; i++) {
    size_t len = util_read_be16(sa + off + 2);
    assert(len >= 8 && off + len <= n);
    assert(util_read_be16(sa + off + len - 2) == groups[i]);
    assert(sa[off] == (i == 3 ? IKE_PT_NONE : IKE_PT_T));
    off += len;
  }
  assert(off == n);
  uint8_t dh[256] = {1};
  size_t size = 1;
  assert(normalize_dh_value(dh, &size, sizeof(dh), 128) == 0);
  assert(size == 128 && dh[127] == 1);
  /* A real HASH may end in zero. Decryption must not trim it with the padding. */
  uint8_t key[24] = {1}, iv[16] = {0}, plain[36] = {1}, encrypted[64], decoded[64], tail[16];
  plain[34] = 0x5e;
  size_t encrypted_len, decoded_len;
  assert(isakmp_aes128_encrypt(key, iv, plain, sizeof(plain), encrypted, &encrypted_len) == 0);
  memset(iv, 0, sizeof(iv));
  assert(isakmp_aes128_decrypt(key, iv, encrypted, encrypted_len, decoded, &decoded_len, tail) == 0);
  assert(decoded_len >= sizeof(plain) && memcmp(decoded, plain, sizeof(plain)) == 0);
  memset(iv, 0, sizeof(iv));
  assert(isakmp_3des_encrypt(key, iv, plain, sizeof(plain), encrypted, &encrypted_len) == 0);
  memset(iv, 0, sizeof(iv));
  assert(isakmp_3des_decrypt(key, iv, encrypted, encrypted_len, decoded, &decoded_len, tail) == 0);
  assert(decoded_len >= sizeof(plain) && memcmp(decoded, plain, sizeof(plain)) == 0);
  return 0;
}
