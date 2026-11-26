#define ppp_dispatch_ppp_frame fixture_ppp_dispatch_ppp_frame
#include "../../android/app/src/main/cpp/l2tp.c"
#include <assert.h>
#include <sys/socket.h>
#include <unistd.h>
int tunnel_should_stop(void) { return 0; }
static int failure[3];
void tunnel_set_failure(int kind, int code, int general_error) {
  failure[0] = kind;
  failure[1] = code;
  failure[2] = general_error;
}
void tunnel_engine_log(int prio, const char *tag, const char *fmt, ...) {
  (void)prio;
  (void)tag;
  (void)fmt;
}
void esp_log_drop_counters(const char *ctx, int reset) {
  (void)ctx;
  (void)reset;
}
void esp_decrypt_last_fail_snprint(char *buf, size_t len) {
  if (len)
    buf[0] = 0;
}
#ifdef _WIN32
void tunnel_log(const char *fmt, ...) { (void)fmt; }
void esp_keys_reset_cache(esp_keys_t *k) { (void)k; }
void esp_reset_drop_counters(void) {}
void esp_keys_cleanup(esp_keys_t *k) { (void)k; }
#endif
int esp_try_decrypt(esp_keys_t *k, const uint8_t *in, size_t n, uint8_t *out, size_t *len) {
  (void)k;
  (void)in;
  (void)n;
  (void)out;
  (void)len;
  return -1;
}
int esp_encrypt_send(int fd, esp_keys_t *k, const struct sockaddr *p, socklen_t plen, const uint8_t *data, size_t n) {
  (void)fd;
  (void)k;
  (void)p;
  (void)plen;
  (void)data;
  return (int)n;
}

static const uint8_t expected_ppp[] = {0xff, 0x03, 0x00, 0x21};

int ppp_dispatch_ppp_frame(int fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t plen, l2tp_session_t *s,
                           ppp_session_t *ppp, const uint8_t *frame, size_t len, packet_endpoint_t *endpoint) {
  (void)fd;
  (void)esp;
  (void)peer;
  (void)plen;
  (void)endpoint;
  assert(s != NULL && ppp != NULL);
  assert(len == sizeof(expected_ppp) && memcmp(frame, expected_ppp, len) == 0);
  return 17;
}

int main(void) {
  uint16_t first, next;
  assert(new_tunnel_id(&first) == 0 && first != 0);
  int different = 0;
  for (int i = 0; i < 100; i++) {
    assert(new_tunnel_id(&next) == 0 && next != 0);
    different |= next != first;
  }
  assert(different);

  uint8_t avps[64];
  size_t off = 0;
  avp_u16(avps, &off, 6, 1);
  assert(util_read_be16(avps) == 8);
  avp_u16(avps, &off, L2TP_AVP_MSG_TYPE, L2TP_MSG_SCCRQ);
  assert(util_read_be16(avps + 8) == 0x8008);
  int sockets[2];
  assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets) == 0);
  uint8_t ack[12] = {0xc8, 2, 0, 12};
  assert(send(sockets[0], ack, sizeof(ack), 0) == sizeof(ack));
  esp_keys_t esp = {0};
  l2tp_session_t session = {0};
  uint8_t incoming[128];
  uint16_t mt;
  assert(recv_ctrl_update_nr(sockets[1], &esp, NULL, incoming, sizeof(incoming), 100, &session, &mt, NULL, NULL,
                             NULL) == 12);
  assert(mt == 0 && session.recv_nr_expected == 0); /* ZLB consumes no sequence number. */
  assert(send(sockets[0], ack, sizeof(ack), 0) == sizeof(ack));
  size_t length;
  off = 0;
  assert(l2tp_avp_append_u16(avps, sizeof(avps), &off, L2TP_AVP_MSG_TYPE, L2TP_MSG_SCCRP) == 0);
  assert(l2tp_ctrl_build(incoming, sizeof(incoming), 0, 0, 0, 1, avps, off, &length) == 0);
  assert(send(sockets[0], incoming, length, 0) == (ssize_t)length);
  assert(recv_until_mt(sockets[1], &esp, NULL, 0, incoming, sizeof(incoming), &session, L2TP_MSG_SCCRP) == (int)length);
  assert(session.recv_nr_expected == 1);

  assert(build_scccn_avps(avps, sizeof(avps), &off) == 0 && off == 8);
  assert(l2tp_ctrl_build(incoming, sizeof(incoming), 0x51ce, 0, 1, 1, avps, off, &length) == 0);
  assert(l2tp_ctrl_msg_type(incoming, length, &mt) == 0 && mt == L2TP_MSG_SCCCN);
  uint16_t unexpected_tid = 0;
  assert(l2tp_avp_first_u16(incoming, length, L2TP_AVP_ASSIGNED_TUNNEL, &unexpected_tid) == -1);

  uint8_t scccn_ack[12] = {0xc8, 2, 0, 12, 0x35, 0x19, 0, 0, 0, 1, 0, 2};
  assert(send(sockets[0], scccn_ack, sizeof(scccn_ack), 0) == sizeof(scccn_ack));
  assert(wait_ctrl_ack(sockets[1], &esp, NULL, 0, &session, 2, 100) == 0);
  assert(wait_ctrl_ack(sockets[1], &esp, NULL, 0, &session, 2, 20) == 1);

  off = 0;
  assert(l2tp_avp_append_u16(avps, sizeof(avps), &off, L2TP_AVP_MSG_TYPE, 4) == 0);
  assert(l2tp_avp_append_result(avps, sizeof(avps), &off, 2, 8) == 0);
  assert(l2tp_ctrl_build(incoming, sizeof(incoming), 0, 0, 1, 1, avps, off, &length) == 0);
  assert(send(sockets[0], incoming, length, 0) == (ssize_t)length);
  assert(recv_ctrl_update_nr(sockets[1], &esp, NULL, incoming, sizeof(incoming), 100, &session, &mt, NULL, NULL,
                             NULL) == -1);
  assert(failure[0] == 2 && failure[1] == 2 && failure[2] == 8);
  failure[0] = failure[1] = failure[2] = 0;
  assert(send(sockets[0], incoming, length, 0) == (ssize_t)length);
  assert(wait_ctrl_ack(sockets[1], &esp, NULL, 0, &session, 2, 100) == -1);
  assert(failure[0] == 2 && failure[1] == 2 && failure[2] == 8);
  failure[0] = failure[1] = failure[2] = 0;
  off = 0;
  assert(l2tp_avp_append_u16(avps, sizeof(avps), &off, L2TP_AVP_MSG_TYPE, L2TP_MSG_CDN) == 0);
  assert(l2tp_avp_append_result(avps, sizeof(avps), &off, 1, 0) == 0);
  assert(l2tp_ctrl_build(incoming, sizeof(incoming), 0, 0, 2, 1, avps, off, &length) == 0);
  assert(l2tp_dispatch_incoming(sockets[1], NULL, NULL, 0, &session, incoming, length, NULL, NULL) ==
         L2TP_DISPATCH_REMOTE_CLOSED);
  assert(failure[0] == 3 && failure[1] == 1 && failure[2] == 0);

  session.peer_tunnel_id = 0x12;
  session.peer_session_id = 0x34;
  const uint8_t data[] = {0x40, 0x02, 0, 12, 0, 0x12, 0, 0x34, 0xff, 0x03, 0, 0x21};
  ppp_session_t ppp = {0};
  packet_endpoint_t endpoint = {0};
  assert(l2tp_dispatch_incoming(sockets[1], NULL, NULL, 0, &session, data, sizeof(data), &endpoint, &ppp) == 17);

  /* Handshake control receiver must skip orphaned data packets (flags=0x0002) and wrong-TID control frames. */
  {
    l2tp_session_t hs = {0};
    hs.peer_tunnel_id = 12613u;
    const uint8_t stale_data[] = {0x00, 0x02, 0xd8, 0x0e, 0xa0, 0x71, 0xff, 0x03, 0xc0, 0x21, 0x01, 0x01};
    uint8_t wrong_tid_sccrp[64];
    uint8_t right_tid_sccrp[64];
    size_t wrong_len = 0, right_len = 0;
    off = 0;
    assert(l2tp_avp_append_u16(avps, sizeof(avps), &off, L2TP_AVP_MSG_TYPE, L2TP_MSG_SCCRP) == 0);
    assert(l2tp_avp_append_u16(avps, sizeof(avps), &off, L2TP_AVP_ASSIGNED_TUNNEL, 267u) == 0);
    assert(l2tp_ctrl_build(wrong_tid_sccrp, sizeof(wrong_tid_sccrp), 49162u, 0u, 0u, 1u, avps, off, &wrong_len) == 0);
    off = 0;
    assert(l2tp_avp_append_u16(avps, sizeof(avps), &off, L2TP_AVP_MSG_TYPE, L2TP_MSG_SCCRP) == 0);
    assert(l2tp_avp_append_u16(avps, sizeof(avps), &off, L2TP_AVP_ASSIGNED_TUNNEL, 271u) == 0);
    assert(l2tp_ctrl_build(right_tid_sccrp, sizeof(right_tid_sccrp), 12613u, 0u, 0u, 1u, avps, off, &right_len) == 0);

    assert(send(sockets[0], stale_data, sizeof(stale_data), 0) == (ssize_t)sizeof(stale_data));
    assert(send(sockets[0], wrong_tid_sccrp, wrong_len, 0) == (ssize_t)wrong_len);
    assert(send(sockets[0], right_tid_sccrp, right_len, 0) == (ssize_t)right_len);

    uint16_t got_mt = 0;
    assert(recv_ctrl_update_nr(sockets[1], &esp, NULL, incoming, sizeof(incoming), 200, &hs, &got_mt, NULL, NULL,
                               NULL) == (int)right_len);
    assert(got_mt == L2TP_MSG_SCCRP);
    uint16_t picked_remote_tid = 0;
    assert(l2tp_avp_first_u16(incoming, right_len, L2TP_AVP_ASSIGNED_TUNNEL, &picked_remote_tid) == 0);
    assert(picked_remote_tid == 271u);
    assert(hs.recv_nr_expected == 1u);
  }

  close(sockets[0]);
  close(sockets[1]);
  return 0;
}
