#include "../../android/app/src/main/cpp/ikev1.c"
#include <assert.h>
int tunnel_should_stop(void) { return 0; }
int util_protect_fd(int fd) {
  (void)fd;
  return 0;
}
void tunnel_log(const char *fmt, ...) { (void)fmt; }
void tunnel_engine_log(int prio, const char *tag, const char *fmt, ...) {
  (void)prio;
  (void)tag;
  (void)fmt;
}
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
  assert(isakmp_aes128_decrypt(key, iv, encrypted, encrypted_len, decoded, sizeof(decoded), &decoded_len, tail) == 0);
  assert(decoded_len >= sizeof(plain) && memcmp(decoded, plain, sizeof(plain)) == 0);
  memset(iv, 0, sizeof(iv));
  assert(isakmp_3des_encrypt(key, iv, plain, sizeof(plain), encrypted, &encrypted_len) == 0);
  memset(iv, 0, sizeof(iv));
  assert(isakmp_3des_decrypt(key, iv, encrypted, encrypted_len, decoded, sizeof(decoded), &decoded_len, tail) == 0);
  assert(decoded_len >= sizeof(plain) && memcmp(decoded, plain, sizeof(plain)) == 0);

  /* Yamaha RTX1220 MM2 leaves Next Payload = Transform (3) on its single selected Transform. */
  const uint8_t yamaha_mm2[96] = {0x5f, 0xf1, 0x75, 0xc0, 0xdf, 0x9c, 0xeb, 0x36, 0x7c, 0x1e, 0x46, 0xe2, 0x8e, 0x73,
                                  0x84, 0x2c, 0x01, 0x10, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x60,
                                  0x0d, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
                                  0x00, 0x24, 0x01, 0x01, 0x00, 0x01, 0x03, 0x00, 0x00, 0x1c, 0x01, 0x01, 0x00, 0x00,
                                  0x80, 0x01, 0x00, 0x07, 0x80, 0x0e, 0x00, 0x80, 0x80, 0x02, 0x00, 0x02, 0x80, 0x03,
                                  0x00, 0x01, 0x80, 0x04, 0x00, 0x0e, 0x00, 0x00, 0x00, 0x14, 0x4a, 0x13, 0x1c, 0x81,
                                  0x07, 0x03, 0x58, 0x45, 0x5c, 0x57, 0x28, 0xf2, 0x0e, 0x95, 0x45, 0x2f};
  uint8_t sa2[256];
  size_t sa2_len = 0;
  int p1_aes = 0;
  unsigned dh_group = 0;
  assert(extract_mm2_p1_selection(yamaha_mm2, sizeof(yamaha_mm2), sa2, sizeof(sa2), &sa2_len, &p1_aes, &dh_group) == 0);
  assert(sa2_len == 44 && p1_aes == 1 && dh_group == 14);

  uint8_t std_mm2[72] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                         0x18, 0x01, 0x10, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00,
                         0x00, 0x2c, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x20, 0x01,
                         0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x18, 0x04, 0x01, 0x00, 0x00, 0x80, 0x01, 0x00, 0x05,
                         0x80, 0x02, 0x00, 0x02, 0x80, 0x03, 0x00, 0x01, 0x80, 0x04, 0x00, 0x02};
  assert(extract_mm2_p1_selection(std_mm2, sizeof(std_mm2), sa2, sizeof(sa2), &sa2_len, &p1_aes, &dh_group) == 0);
  assert(sa2_len == 40 && p1_aes == 0 && dh_group == 2);

  std_mm2[48] = 0x99;
  assert(extract_mm2_p1_selection(std_mm2, sizeof(std_mm2), sa2, sizeof(sa2), &sa2_len, &p1_aes, &dh_group) == -1);

  int fd1 = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  assert(fd1 >= 0);
  ike_disable_ipv4_pmtud(fd1);
  ike_try_bind_local_port(fd1, 0);

  struct sockaddr_storage lss;
  socklen_t lsl = sizeof(lss);
  assert(getsockname(fd1, (struct sockaddr *)&lss, &lsl) == 0);
  assert(lss.ss_family == AF_INET);
  uint16_t bound_port = ntohs(((struct sockaddr_in *)&lss)->sin_port);
  assert(bound_port != 0);

  int fd2 = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  assert(fd2 >= 0);
  ike_try_bind_local_port(fd2, bound_port);
  close(fd2);
  close(fd1);

  struct sockaddr_storage resolved;
  socklen_t resolved_len = sizeof(resolved);
  assert(resolve_udp("127.0.0.1", IKE_PORT, &resolved, &resolved_len) == 0);
  assert(resolved.ss_family == AF_INET);
  assert(ntohs(((struct sockaddr_in *)&resolved)->sin_port) == IKE_PORT);
  return 0;
}
