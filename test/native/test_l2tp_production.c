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
  assert(recv_ctrl_update_nr(sockets[1], &esp, NULL, incoming, sizeof(incoming), 100, &session, &mt, NULL) == 12);
  assert(mt == 0 && session.recv_nr_expected == 0); /* ZLB consumes no sequence number. */
  assert(send(sockets[0], ack, sizeof(ack), 0) == sizeof(ack));
  size_t length;
  off = 0;
  assert(l2tp_avp_append_u16(avps, sizeof(avps), &off, L2TP_AVP_MSG_TYPE, L2TP_MSG_SCCRP) == 0);
  assert(l2tp_ctrl_build(incoming, sizeof(incoming), 0, 0, 0, 1, avps, off, &length) == 0);
  assert(send(sockets[0], incoming, length, 0) == (ssize_t)length);
  assert(recv_until_mt(sockets[1], &esp, NULL, 0, incoming, sizeof(incoming), &session, L2TP_MSG_SCCRP) == (int)length);
  assert(session.recv_nr_expected == 1);
  off = 0;
  assert(l2tp_avp_append_u16(avps, sizeof(avps), &off, L2TP_AVP_MSG_TYPE, 4) == 0);
  assert(l2tp_avp_append_result(avps, sizeof(avps), &off, 2, 8) == 0);
  assert(l2tp_ctrl_build(incoming, sizeof(incoming), 0, 0, 1, 1, avps, off, &length) == 0);
  assert(send(sockets[0], incoming, length, 0) == (ssize_t)length);
  assert(recv_ctrl_update_nr(sockets[1], &esp, NULL, incoming, sizeof(incoming), 100, &session, &mt, NULL) == -1);
  assert(failure[0] == 2 && failure[1] == 2 && failure[2] == 8);
  close(sockets[0]);
  close(sockets[1]);
  return 0;
}
