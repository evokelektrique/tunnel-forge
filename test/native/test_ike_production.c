#include "../../android/app/src/main/cpp/ikev1.c"
#include <assert.h>
void l2tp_root_init(l2tp_root_t *r) {
  if (r != NULL)
    memset(r, 0, sizeof(*r));
}
int l2tp_root_start(l2tp_root_t *r, const char *helper_path, int protect_vpn, const char *bind_iface) {
  (void)r;
  (void)helper_path;
  (void)protect_vpn;
  (void)bind_iface;
  return TUNNEL_EXIT_ROOT_UNAVAILABLE;
}
void l2tp_root_stop(l2tp_root_t *r) { (void)r; }
void esp_keys_cleanup(esp_keys_t *k) { (void)k; }
int l2tp_root_open_udp(l2tp_root_t *r, const uint8_t peer_ipv4[4], uint16_t remote_port, uint16_t bind_local_port,
                       int allow_ephemeral_fallback, uint8_t local_ipv4_out[4], uint16_t *local_port_be_out,
                       int *out_errno) {
  (void)r;
  (void)peer_ipv4;
  (void)remote_port;
  (void)bind_local_port;
  (void)allow_ephemeral_fallback;
  (void)local_ipv4_out;
  (void)local_port_be_out;
  if (out_errno != NULL)
    *out_errno = ENOSYS;
  return -1;
}
int l2tp_root_connect_udp(l2tp_root_t *r, const uint8_t peer_ipv4[4], uint16_t remote_port, uint8_t local_ipv4_out[4],
                          uint16_t *local_port_be_out, int *out_errno) {
  (void)r;
  (void)peer_ipv4;
  (void)remote_port;
  (void)local_ipv4_out;
  (void)local_port_be_out;
  if (out_errno != NULL)
    *out_errno = ENOSYS;
  return -1;
}
int l2tp_root_udp_send(l2tp_root_t *r, const uint8_t *data, size_t len, int *out_errno) {
  (void)r;
  (void)data;
  (void)len;
  if (out_errno != NULL)
    *out_errno = ENOSYS;
  return -1;
}
int l2tp_root_udp_recv(l2tp_root_t *r, uint8_t *buf, size_t cap, int timeout_ms, int peek, int *out_errno) {
  (void)r;
  (void)buf;
  (void)cap;
  (void)timeout_ms;
  (void)peek;
  if (out_errno != NULL)
    *out_errno = ENOSYS;
  return -1;
}
int l2tp_root_set_encap(l2tp_root_t *r, int encap_type, int *out_errno) {
  (void)r;
  (void)encap_type;
  if (out_errno != NULL)
    *out_errno = ENOSYS;
  return -1;
}
int l2tp_root_xfrm_install(l2tp_root_t *r, const tf_l2tp_xfrm_spec_t *spec, int *out_errno) {
  (void)r;
  (void)spec;
  if (out_errno != NULL)
    *out_errno = ENOSYS;
  return -1;
}
int l2tp_root_open_raw_esp(l2tp_root_t *r, const uint8_t peer_ipv4[4], int *out_errno) {
  (void)r;
  (void)peer_ipv4;
  if (out_errno != NULL)
    *out_errno = ENOSYS;
  return -1;
}
int l2tp_root_start_stream(l2tp_root_t *r, int mode, int *out_errno) {
  (void)r;
  (void)mode;
  if (out_errno != NULL)
    *out_errno = ENOSYS;
  return -1;
}
int l2tp_root_ike_send_async(l2tp_root_t *r, const uint8_t *data, size_t len, int nat_t) {
  (void)r;
  (void)data;
  (void)len;
  (void)nat_t;
  return -1;
}
int l2tp_root_stream_send(void *ctx, const uint8_t *data, size_t len) {
  (void)ctx;
  (void)data;
  (void)len;
  return -1;
}
int l2tp_root_stream_recv_wait(void *ctx, uint8_t *buf, size_t cap, int timeout_ms) {
  (void)ctx;
  (void)buf;
  (void)cap;
  (void)timeout_ms;
  return -1;
}
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
  size_t n = build_p1_sa(sa, sizeof(sa), 0);
  assert(n == 120u && sa[15] == 4);
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

  uint8_t sa_compat[256];
  size_t n_compat = build_p1_sa(sa_compat, sizeof(sa_compat), 1);
  assert(n_compat == 168u && sa_compat[15] == 4);
  off = 16u;
  for (unsigned i = 0; i < 4; i++) {
    size_t len = util_read_be16(sa_compat + off + 2);
    assert(len >= 20u && off + len <= n_compat);
    assert(sa_compat[off] == (i == 3 ? IKE_PT_NONE : IKE_PT_T));
    assert(util_read_be16(sa_compat + off + len - 12u) == 0x800bu);
    assert(util_read_be16(sa_compat + off + len - 10u) == 0x0001u);
    assert(util_read_be16(sa_compat + off + len - 8u) == 0x000cu);
    assert(util_read_be32(sa_compat + off + len - 4u) == 28800u);
    assert(util_read_be16(sa_compat + off + len - 14u) == groups[i]);
    off += len;
  }
  assert(off == n_compat);

  uint8_t icookie[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  uint8_t mm1_pkt[512];
  size_t mm1_primary_len = ike_build_mm1_packet(mm1_pkt, sizeof(mm1_pkt), icookie, sa, n, IKE_MM1_PRIMARY);
  assert(mm1_primary_len == 172u);
  assert(util_read_be32(mm1_pkt + 24) == 172u);
  size_t mm1_compat_len = ike_build_mm1_packet(mm1_pkt, sizeof(mm1_pkt), icookie, sa_compat, n_compat, IKE_MM1_COMPAT);
  assert(mm1_compat_len == 300u);
  assert(util_read_be32(mm1_pkt + 24) == 300u);
  size_t walk = 28u;
  uint8_t np = mm1_pkt[16];
  int vid_count = 0;
  while (walk + 4u <= mm1_compat_len && np != IKE_PT_NONE) {
    uint16_t pl = util_read_be16(mm1_pkt + walk + 2u);
    assert(pl >= 4u && walk + pl <= mm1_compat_len);
    if (np == IKE_PT_VID)
      vid_count++;
    np = mm1_pkt[walk];
    walk += pl;
  }
  assert(walk == mm1_compat_len && np == IKE_PT_NONE && vid_count == 5);
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

  struct sockaddr_storage resolved_list[4];
  socklen_t resolved_lens[4] = {0};
  size_t resolved_count = 0u;
  assert(resolve_udp_candidates("127.0.0.1", IKE_PORT, resolved_list, resolved_lens, 4u, &resolved_count) == 0);
  assert(resolved_count == 1u);

  int open_err = 0;
  int fd_open = ike_open_udp_socket(&resolved, resolved_len, 0u, 1, "test-loopback", &open_err);
  assert(fd_open >= 0 && open_err == 0);
  int so_err = -1;
  socklen_t so_len = (socklen_t)sizeof(so_err);
  assert(getsockopt(fd_open, SOL_SOCKET, SO_ERROR, &so_err, &so_len) == 0);
  assert(so_err == 0);
  close(fd_open);

  /* Oversized ciphertext must fail without writing past output capacity. */
  uint8_t oversized_ct[272] = {0};
  uint8_t dec_buf[1024];
  size_t dec_out_len = 0;
  uint8_t dec_iv_out[16];
  memset(dec_buf, 0xA5, sizeof(dec_buf));
  assert(isakmp_aes128_decrypt(key, iv, oversized_ct, sizeof(oversized_ct), dec_buf, 256u, &dec_out_len, dec_iv_out) !=
         0);
  assert(dec_buf[256] == 0xA5);
  memset(dec_buf, 0xA5, sizeof(dec_buf));
  assert(isakmp_3des_decrypt(key, iv, oversized_ct, 264u, dec_buf, 256u, &dec_out_len, dec_iv_out) != 0);
  assert(dec_buf[256] == 0xA5);

  /* ESP keymat derivation must succeed with debug keymat logging disabled by default. */
  esp_keys_t esp_out;
  memset(&esp_out, 0, sizeof(esp_out));
  uint8_t skd[20] = {1, 2, 3, 4};
  uint8_t ni[16] = {5}, nr[16] = {6};
  uint8_t ip_us[4] = {192, 0, 2, 1}, ip_peer[4] = {192, 0, 2, 2};
  assert(ike_install_esp_keymat(&esp_out, skd, sizeof(skd), 0x11223344u, 0x55667788u, ni, sizeof(ni), nr, sizeof(nr),
                                ESP_CIPHER_AES_CBC, 16u, ip_us, ip_peer) == 0);
#if defined(TUNNEL_FORGE_DEBUG_ESP_KEYMAT) && TUNNEL_FORGE_DEBUG_ESP_KEYMAT
#error "TUNNEL_FORGE_DEBUG_ESP_KEYMAT must stay disabled in default builds"
#endif

  /* Encrypted ISAKMP Delete emits NAT-T prefix + AES-CBC HASH|DELETE(ESP)|DELETE(ISAKMP), and safe no-ops work. */
  {
    ike_session_t ike_empty;
    memset(&ike_empty, 0, sizeof(ike_empty));
    ike_empty.esp_fd = -1;
    ikev1_send_delete(&ike_empty, NULL);

    int fd_tx = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    int fd_rx = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    assert(fd_tx >= 0 && fd_rx >= 0);

    struct sockaddr_in bind_addr;
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind_addr.sin_port = htons(0);
    assert(bind(fd_tx, (const struct sockaddr *)&bind_addr, (socklen_t)sizeof(bind_addr)) == 0);
    assert(bind(fd_rx, (const struct sockaddr *)&bind_addr, (socklen_t)sizeof(bind_addr)) == 0);

    struct sockaddr_storage tx_addr;
    socklen_t tx_len = (socklen_t)sizeof(tx_addr);
    assert(getsockname(fd_tx, (struct sockaddr *)&tx_addr, &tx_len) == 0);

    struct sockaddr_storage peer_addr;
    socklen_t peer_len = (socklen_t)sizeof(peer_addr);
    assert(getsockname(fd_rx, (struct sockaddr *)&peer_addr, &peer_len) == 0);

    ike_session_t ike;
    memset(&ike, 0, sizeof(ike));
    for (size_t i = 0; i < 8u; i++) {
      ike.icookie[i] = (uint8_t)(0x10u + i);
      ike.rcookie[i] = (uint8_t)(0x20u + i);
    }
    memset(ike.skeyid_a, 0x33u, 20u);
    ike.skeyid_a_len = 20u;
    memset(ike.skeyid_e, 0x44u, 20u);
    ike.skeyid_e_len = 20u;
    memset(ike.iv_phase1, 0x55u, sizeof(ike.iv_phase1));
    ike.nat_t = 1;
    ike.p1_aes = 1;
    ike.esp_fd = fd_tx;
    memcpy(&ike.peer, &peer_addr, peer_len);
    ike.peer_len = peer_len;

    esp_keys_t esp_del;
    memset(&esp_del, 0, sizeof(esp_del));
    esp_del.spi_r = 0xdeadbeefu;

    ikev1_send_delete(&ike, &esp_del);

    struct pollfd rx_pfd = {.fd = fd_rx, .events = POLLIN};
    assert(poll(&rx_pfd, 1, 1000) == 1);
    uint8_t wire[512];
    ssize_t n = recv(fd_rx, wire, sizeof(wire), 0);
    assert(n > 4 + 28);
    assert(util_read_be32(wire) == 0u);
    const uint8_t *hdr = wire + 4;
    size_t hdr_len = (size_t)n - 4u;
    assert(hdr[16] == IKE_PT_HASH && hdr[18] == IKE_EXCH_INFO && (hdr[19] & IKE_FLAG_ENC) != 0u);
    assert(util_read_be32(hdr + 24) == hdr_len);
    uint32_t mid = util_read_be32(hdr + 20);
    assert(mid != 0u);

    uint8_t aeskey[16];
    uint8_t iv[16];
    uint8_t iv_out[16];
    derive_aes128_key(ike.skeyid_e, aeskey);
    qm_first_iv_aes(ike.iv_phase1, mid, iv);
    uint8_t plain[256];
    size_t plain_len = 0u;
    assert(isakmp_aes128_decrypt(aeskey, iv, hdr + 28, hdr_len - 28u, plain, sizeof(plain), &plain_len, iv_out) == 0);
    assert(plain_len >= 24u + 16u + 28u);
    assert(plain[0] == IKE_PT_DELETE && util_read_be16(plain + 2) == 24u);
    assert(plain[24] == IKE_PT_DELETE && util_read_be16(plain + 26) == 16u && plain[32] == 3u &&
           util_read_be32(plain + 36) == esp_del.spi_r);
    assert(plain[40] == IKE_PT_NONE && util_read_be16(plain + 42) == 28u && plain[48] == 1u &&
           memcmp(plain + 52, ike.icookie, 8u) == 0 && memcmp(plain + 60, ike.rcookie, 8u) == 0);

    uint8_t hash_in[4 + 44];
    util_write_be32(hash_in, mid);
    memcpy(hash_in + 4, plain + 24, 44u);
    uint8_t expected_hash[20];
    assert(prf_hmac_sha1(ike.skeyid_a, 20u, hash_in, sizeof(hash_in), expected_hash) == 0);
    assert(memcmp(plain + 4, expected_hash, 20u) == 0);

    /* Early NAT-T ESP packet (non-zero SPI) stops ike_qm3_finish_recv_loop without consuming the ESP packet. */
    const uint8_t fake_esp[16] = {0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1};
    assert(sendto(fd_rx, fake_esp, sizeof(fake_esp), 0, (const struct sockaddr *)&tx_addr, tx_len) ==
           (ssize_t)sizeof(fake_esp));
    const uint8_t qm3_dummy[32] = {0};
    assert(ike_qm3_finish_recv_loop(fd_tx, NULL, (struct sockaddr *)&peer_addr, peer_len, qm3_dummy, sizeof(qm3_dummy),
                                    wire, sizeof(wire), 1, 1u, 1, aeskey, NULL, ike.iv_phase1) == 0);
    uint8_t rx_after[64];
    ssize_t rn = recv(fd_tx, rx_after, sizeof(rx_after), MSG_DONTWAIT);
    assert(rn == (ssize_t)sizeof(fake_esp) && memcmp(rx_after, fake_esp, sizeof(fake_esp)) == 0);

    close(fd_tx);
    close(fd_rx);
  }
  return 0;
}
