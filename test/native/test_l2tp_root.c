#include "../../android/app/src/main/cpp/l2tp_xfrm.h"
#include "../../android/app/src/main/cpp/util_endian.h"

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

#ifdef TF_TEST_L2TP_ROOT
#include "../../android/app/src/main/cpp/engine.h"
#include "../../android/app/src/main/cpp/l2tp_root.h"
#include "../../android/app/src/main/cpp/root_detect.h"
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static int g_test_should_stop;
int tunnel_should_stop(void) { return g_test_should_stop; }
void tunnel_engine_log(int prio, const char *tag, const char *fmt, ...) {
  (void)prio;
  (void)tag;
  (void)fmt;
}
#endif

static uint16_t host_htons_bytes(uint16_t v) {
  uint16_t out = 0u;
  util_write_be16((uint8_t *)&out, v);
  return out;
}

static void test_xfrm_spec_and_netlink_messages(void) {
  tf_l2tp_xfrm_spec_t spec;
  memset(&spec, 0, sizeof(spec));
  spec.local_ipv4[0] = 10u;
  spec.local_ipv4[1] = 0u;
  spec.local_ipv4[2] = 2u;
  spec.local_ipv4[3] = 15u;
  spec.peer_ipv4[0] = 198u;
  spec.peer_ipv4[1] = 51u;
  spec.peer_ipv4[2] = 100u;
  spec.peer_ipv4[3] = 2u;
  spec.l2tp_local_port_be = host_htons_bytes(42123u);
  spec.ike_local_port_be = host_htons_bytes(500u);
  util_write_be32((uint8_t *)&spec.spi_out_be, 0x11223344u);
  util_write_be32((uint8_t *)&spec.spi_in_be, 0x55667788u);
  spec.reqid = 0x10203040u;
  spec.cipher = TF_L2TP_XFRM_CIPHER_AES;
  spec.enc_key_len = 16u;
  spec.auth_key_len = 20u;
  spec.use4500 = 1u;
  for (uint8_t i = 0u; i < 16u; i++) {
    spec.enc_key_out[i] = (uint8_t)(0xa0u + i);
    spec.enc_key_in[i] = (uint8_t)(0xb0u + i);
  }
  for (uint8_t i = 0u; i < 20u; i++) {
    spec.auth_key_out[i] = (uint8_t)(0xc0u + i);
    spec.auth_key_in[i] = (uint8_t)(0xd0u + i);
  }

  uint8_t wire[TF_L2TP_XFRM_WIRE_LEN];
  assert(tf_l2tp_xfrm_spec_pack(&spec, wire, sizeof(wire)) == 0);
  tf_l2tp_xfrm_spec_t unpacked;
  assert(tf_l2tp_xfrm_spec_unpack(wire, sizeof(wire), &unpacked) == 0);
  assert(memcmp(&spec, &unpacked, sizeof(spec)) == 0);

  /* Invalid cipher/key lengths must be rejected. */
  uint8_t bad_wire[TF_L2TP_XFRM_WIRE_LEN];
  memcpy(bad_wire, wire, sizeof(wire));
  bad_wire[25] = 15u; /* wrong enc_key_len for AES */
  assert(tf_l2tp_xfrm_spec_unpack(bad_wire, sizeof(bad_wire), &unpacked) == -1);
  assert(tf_l2tp_xfrm_spec_unpack(wire, sizeof(wire) - 1u, &unpacked) == -1);

  /* 3DES pack/unpack check. */
  spec.cipher = TF_L2TP_XFRM_CIPHER_3DES;
  spec.enc_key_len = 24u;
  spec.use4500 = 0u;
  assert(tf_l2tp_xfrm_spec_pack(&spec, wire, sizeof(wire)) == 0);
  assert(tf_l2tp_xfrm_spec_unpack(wire, sizeof(wire), &unpacked) == 0);

  /* Netlink XFRM message building: NEWSA (with & without UDP encap), DELSA, NEWPOLICY, DELPOLICY. */
  uint8_t msg_noencap[1024];
  size_t len_noencap = tf_xfrm_nl_build_newsa(msg_noencap, sizeof(msg_noencap), 1u, &spec, 0);
  assert(len_noencap > 234u);
  uint32_t nl_len = 0u;
  uint16_t nl_type = 0u;
  memcpy(&nl_len, msg_noencap, 4u);
  memcpy(&nl_type, msg_noencap + 4u, 2u);
  assert(nl_len == len_noencap && nl_type == 0x10u);
  /* Verify XFRM_STATE_NOPMTUDISC (4) is set in struct xfrm_usersa_info.flags (nlmsghdr 16 + offset 216). */
  assert((msg_noencap[16u + 216u] & 4u) == 4u);

  spec.cipher = TF_L2TP_XFRM_CIPHER_AES;
  spec.enc_key_len = 16u;
  spec.use4500 = 1u;
  uint8_t msg_encap[1024];
  size_t len_encap = tf_xfrm_nl_build_newsa(msg_encap, sizeof(msg_encap), 2u, &spec, 1);
  assert(len_encap > len_noencap); /* includes XFRMA_ENCAP */

  assert(tf_xfrm_nl_build_newsa(msg_encap, 32u, 2u, &spec, 1) == 0u); /* small buffer guard */

  uint8_t del_sa[256];
  size_t del_sa_len = tf_xfrm_nl_build_delsa(del_sa, sizeof(del_sa), 3u, spec.local_ipv4, spec.spi_in_be);
  assert(del_sa_len >= 40u);
  memcpy(&nl_type, del_sa + 4u, 2u);
  assert(nl_type == 0x11u);

  uint8_t pol_out[512], pol_in[512], del_pol[256];
  size_t po_len = tf_xfrm_nl_build_newpolicy(pol_out, sizeof(pol_out), 4u, &spec, TF_XFRM_DIR_OUT);
  size_t pi_len = tf_xfrm_nl_build_newpolicy(pol_in, sizeof(pol_in), 5u, &spec, TF_XFRM_DIR_IN);
  size_t dp_len = tf_xfrm_nl_build_delpolicy(del_pol, sizeof(del_pol), 6u, &spec, TF_XFRM_DIR_OUT);
  assert(po_len > 100u && pi_len == po_len && dp_len >= 72u);

  /* ACK parser: success (err=0), failure (err=-ENOENT), seq mismatch, malformed. */
  uint8_t ack[36];
  memset(ack, 0, sizeof(ack));
  uint32_t ack_len = sizeof(ack);
  uint16_t ack_type = 2u; /* NLMSG_ERROR */
  uint32_t ack_seq = 7u;
  int32_t ack_err = 0;
  memcpy(ack + 0u, &ack_len, 4u);
  memcpy(ack + 4u, &ack_type, 2u);
  memcpy(ack + 8u, &ack_seq, 4u);
  memcpy(ack + 16u, &ack_err, 4u);
  int parsed_err = -1;
  assert(tf_xfrm_nl_parse_ack(ack, sizeof(ack), 7u, &parsed_err) == 1 && parsed_err == 0);
  assert(tf_xfrm_nl_parse_ack(ack, sizeof(ack), 99u, &parsed_err) == 0);

  ack_err = -ENOENT;
  memcpy(ack + 16u, &ack_err, 4u);
  assert(tf_xfrm_nl_parse_ack(ack, sizeof(ack), 7u, &parsed_err) == 1 && parsed_err == ENOENT);
  assert(tf_xfrm_nl_parse_ack(ack, 8u, 7u, &parsed_err) == -1);
}

#ifdef TF_TEST_L2TP_ROOT
static int run_mock_helper(void) {
  uint8_t hdr[TF_L2TP_FRAME_HDR_LEN];
  uint8_t buf[TF_L2TP_MAX_FRAME];
  if (read(STDIN_FILENO, hdr, sizeof(hdr)) != (ssize_t)sizeof(hdr) || hdr[0] != TF_L2TP_CMD_INIT)
    return 2;
  uint16_t ilen = util_read_be16(hdr + 2u);
  if (ilen != TF_L2TP_INIT_PAYLOAD_LEN || read(STDIN_FILENO, buf, ilen) != (ssize_t)ilen)
    return 2;
  uint8_t rep_ok[8] = {TF_L2TP_MSG_REPLY, 0u, 0u, 4u, 0u, 0u, 0u, 0u};
  if (write(STDOUT_FILENO, rep_ok, sizeof(rep_ok)) != (ssize_t)sizeof(rep_ok))
    return 3;

  while (read(STDIN_FILENO, hdr, sizeof(hdr)) == (ssize_t)sizeof(hdr)) {
    uint16_t plen = util_read_be16(hdr + 2u);
    if (plen > sizeof(buf))
      return 4;
    if (plen > 0u && read(STDIN_FILENO, buf, plen) != (ssize_t)plen)
      return 4;
    if (hdr[0] == TF_L2TP_CMD_OPEN_UDP) {
      uint8_t rep[16] = {TF_L2TP_MSG_REPLY, 0u, 0u, 12u, 0u, 0u, 0u, 0u, 10u, 0u, 2u, 15u, 0x01u, 0xf4u, 0u, 0u};
      if (write(STDOUT_FILENO, rep, sizeof(rep)) != (ssize_t)sizeof(rep))
        return 5;
    } else if (hdr[0] == TF_L2TP_CMD_XFRM_INSTALL) {
      /* Simulate ENOPROTOOPT so caller tests fallback to Tier 2 stream. */
      uint8_t rep[8] = {TF_L2TP_MSG_REPLY, 1u, 0u, 4u, 0u, 0u, 0u, (uint8_t)ENOPROTOOPT};
      if (write(STDOUT_FILENO, rep, sizeof(rep)) != (ssize_t)sizeof(rep))
        return 5;
    } else if (hdr[0] == TF_L2TP_CMD_START_STREAM) {
      if (write(STDOUT_FILENO, rep_ok, sizeof(rep_ok)) != (ssize_t)sizeof(rep_ok))
        return 5;
      while (read(STDIN_FILENO, hdr, sizeof(hdr)) == (ssize_t)sizeof(hdr)) {
        plen = util_read_be16(hdr + 2u);
        if (plen > 0u && read(STDIN_FILENO, buf, plen) != (ssize_t)plen)
          break;
        if (hdr[0] == TF_L2TP_CMD_STOP)
          return 0;
        if (hdr[0] == TF_L2TP_MSG_DATA) {
          uint8_t out[TF_L2TP_FRAME_HDR_LEN + 64];
          if (plen <= 64u) {
            out[0] = TF_L2TP_MSG_DATA;
            out[1] = 0u;
            util_write_be16(out + 2u, plen);
            memcpy(out + TF_L2TP_FRAME_HDR_LEN, buf, plen);
            (void)write(STDOUT_FILENO, out, TF_L2TP_FRAME_HDR_LEN + plen);
          }
        }
      }
      return 0;
    } else if (hdr[0] == TF_L2TP_CMD_STOP) {
      (void)write(STDOUT_FILENO, rep_ok, sizeof(rep_ok));
      return 0;
    } else {
      if (write(STDOUT_FILENO, rep_ok, sizeof(rep_ok)) != (ssize_t)sizeof(rep_ok))
        return 5;
    }
  }
  return 0;
}

static void test_l2tp_root_ipc_and_su_probe(const char *self_path) {
  assert(tf_is_safe_helper_path("/data/app/~~abc==/pkg/lib/arm64/libl2tp_root_helper.so") == 1);
  assert(tf_is_safe_helper_path("/tmp/bad;sh/libl2tp_root_helper.so") == 0);

  char dir[] = "/tmp/tf_l2tp_root_XXXXXX";
  assert(mkdtemp(dir) != NULL);

  char su_root[256];
  snprintf(su_root, sizeof(su_root), "%s/su_root.sh", dir);
  FILE *f = fopen(su_root, "w");
  assert(f != NULL);
  fprintf(f, "#!/bin/sh\nif [ \"$2\" = \"id\" ]; then\n  echo \"uid=0(root) gid=0(root)\"\n  exit 0\nfi\nexport TF_MOCK_L2TP_HELPER=1\nexec '%s'\n",
          self_path);
  fclose(f);
  assert(chmod(su_root, 0700) == 0);

  char helper_stub[256];
  snprintf(helper_stub, sizeof(helper_stub), "%s/libl2tp_root_helper.so", dir);
  f = fopen(helper_stub, "w");
  assert(f != NULL);
  fprintf(f, "#!/bin/sh\nexit 0\n");
  fclose(f);
  assert(chmod(helper_stub, 0700) == 0);

  assert(tf_probe_root_with_su(su_root, 2000) == 1);

  char su_nonroot[256];
  snprintf(su_nonroot, sizeof(su_nonroot), "%s/su_nonroot.sh", dir);
  f = fopen(su_nonroot, "w");
  assert(f != NULL);
  fprintf(f, "#!/bin/sh\necho \"uid=2000(shell) gid=2000(shell)\"\nexit 0\n");
  fclose(f);
  assert(chmod(su_nonroot, 0700) == 0);
  assert(tf_probe_root_with_su(su_nonroot, 2000) == 0);

  setenv("TF_TEST_L2TP_SU", su_root, 1);
  l2tp_root_t root;
  l2tp_root_init(&root);
  assert(l2tp_root_start(&root, helper_stub, 1, "wlan0") == TUNNEL_EXIT_OK);

  const uint8_t peer_ip[4] = {198u, 51u, 100u, 2u};
  uint8_t local_ip[4] = {0};
  uint16_t local_port_be = 0u;
  int err = 0;
  assert(l2tp_root_open_udp(&root, peer_ip, 500u, 500u, 1, local_ip, &local_port_be, &err) == 0);
  assert(local_ip[0] == 10u && local_ip[3] == 15u);
  assert(local_port_be == host_htons_bytes(500u));

  tf_l2tp_xfrm_spec_t spec;
  memset(&spec, 0, sizeof(spec));
  memcpy(spec.local_ipv4, local_ip, 4u);
  memcpy(spec.peer_ipv4, peer_ip, 4u);
  spec.l2tp_local_port_be = host_htons_bytes(40000u);
  spec.ike_local_port_be = local_port_be;
  util_write_be32((uint8_t *)&spec.spi_out_be, 0x11223344u);
  util_write_be32((uint8_t *)&spec.spi_in_be, 0x55667788u);
  spec.reqid = 1u;
  spec.cipher = TF_L2TP_XFRM_CIPHER_AES;
  spec.enc_key_len = 16u;
  spec.auth_key_len = 20u;
  assert(l2tp_root_xfrm_install(&root, &spec, &err) == -1 && err == ENOPROTOOPT);

  assert(l2tp_root_start_stream(&root, TF_L2TP_STREAM_RAW_ESP, &err) == 0);
  const uint8_t ping[5] = {1u, 2u, 3u, 4u, 5u};
  assert(l2tp_root_stream_send(&root, ping, sizeof(ping)) == (int)sizeof(ping));
  uint8_t pong[16] = {0};
  assert(l2tp_root_stream_recv_wait(&root, pong, sizeof(pong), 2000) == (int)sizeof(ping));
  assert(memcmp(ping, pong, sizeof(ping)) == 0);

  l2tp_root_stop(&root);

  /* Teardown IKE Delete + XFRM delete must still complete after g_stop=1. */
  l2tp_root_t root_td;
  l2tp_root_init(&root_td);
  assert(l2tp_root_start(&root_td, helper_stub, 1, "wlan0") == TUNNEL_EXIT_OK);
  assert(l2tp_root_open_udp(&root_td, peer_ip, 500u, 500u, 1, local_ip, &local_port_be, &err) == 0);
  g_test_should_stop = 1;
  const uint8_t ike_del[8] = {1u, 2u, 3u, 4u, 5u, 6u, 7u, 8u};
  assert(l2tp_root_ike_send_async(&root_td, ike_del, sizeof(ike_del), 1) == 0);
  root_td.xfrm_installed = 1;
  l2tp_root_xfrm_delete(&root_td);
  assert(root_td.xfrm_installed == 0);
  l2tp_root_stop(&root_td);
  g_test_should_stop = 0;

  unsetenv("TF_TEST_L2TP_SU");
  unlink(su_root);
  unlink(su_nonroot);
  unlink(helper_stub);
  rmdir(dir);
}
#endif

int main(int argc, char **argv) {
  (void)argc;
#ifdef TF_TEST_L2TP_ROOT
  if (getenv("TF_MOCK_L2TP_HELPER") != NULL)
    return run_mock_helper();
  test_l2tp_root_ipc_and_su_probe(argv[0]);
#else
  (void)argv;
#endif
  test_xfrm_spec_and_netlink_messages();
  puts("test_l2tp_root: ok");
  return 0;
}
