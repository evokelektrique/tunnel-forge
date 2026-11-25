#include "../../android/app/src/main/cpp/pptp.h"
#include "../../android/app/src/main/cpp/util_endian.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>
#ifdef TF_TEST_PPTP_ROOT
#include "../../android/app/src/main/cpp/pptp_root.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

void tunnel_engine_log(int priority, const char *tag, const char *format, ...) {
  (void)priority;
  (void)tag;
  (void)format;
}

int tunnel_should_stop(void) { return 0; }

static int64_t test_monotonic_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    return 0;
  return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000LL);
}

static void test_pptp_root_pipe_bounds(void) {
  signal(SIGPIPE, SIG_IGN);

  int fds[2] = {-1, -1};
  assert(pipe(fds) == 0);
  int flags = fcntl(fds[1], F_GETFL, 0);
  assert(flags >= 0 && fcntl(fds[1], F_SETFL, flags | O_NONBLOCK) == 0);
  uint8_t fill[4096];
  memset(fill, 0x55, sizeof(fill));
  while (write(fds[1], fill, sizeof(fill)) > 0) {
  }
  pptp_root_t r;
  pptp_root_init(&r);
  r.to_helper_fd = fds[1];
  uint8_t gre[64] = {0x30, 0x01};
  int64_t t0 = test_monotonic_ms();
  int send_rc = pptp_root_send_gre(&r, gre, sizeof(gre));
  int send_err = errno;
  int64_t elapsed = test_monotonic_ms() - t0;
  close(fds[0]);
  close(fds[1]);
  assert(send_rc == -1 && send_err == ENOBUFS && elapsed <= 200);

  assert(pipe(fds) == 0);
  close(fds[0]);
  pptp_root_init(&r);
  r.to_helper_fd = fds[1];
  errno = 0;
  send_rc = pptp_root_send_gre(&r, gre, sizeof(gre));
  send_err = errno;
  close(fds[1]);
  assert(send_rc == -1 && send_err == EPIPE);
}
#endif

static void assert_valid_header(const uint8_t *buf, int built_len, uint16_t want_type) {
  assert(built_len >= 12);
  uint16_t msg_len = 0u;
  uint16_t ctrl_type = 0u;
  int rc = pptp_parse_control_header(buf, (size_t)built_len, &msg_len, &ctrl_type);
  assert(rc == (int)want_type);
  assert(msg_len == (uint16_t)built_len);
  assert(ctrl_type == want_type);
  assert(util_read_be16(buf + 2u) == PPTP_MSG_TYPE_CONTROL);
  assert(util_read_be32(buf + 4u) == PPTP_MAGIC_COOKIE);
}

int main(void) {
  uint8_t buf[256];

  int len = pptp_build_sccrq(buf, sizeof(buf));
  assert(len == 156);
  assert_valid_header(buf, len, PPTP_CTRL_SCCRQ);
  assert(util_read_be16(buf + 12u) == 0x0100u);
  assert(strcmp((const char *)(buf + 28u), "TunnelForge") == 0);
  assert(pptp_build_sccrq(buf, 100u) == -1);

  len = pptp_build_ocrq(buf, sizeof(buf), 0x1122u, 0x0007u);
  assert(len == 168);
  assert_valid_header(buf, len, PPTP_CTRL_OCRQ);
  assert(util_read_be16(buf + 12u) == 0x1122u);
  assert(util_read_be16(buf + 14u) == 0x0007u);
  assert(util_read_be16(buf + 32u) == 64u);

  len = pptp_build_sli(buf, sizeof(buf), 0x3344u, 0xffffffffu, 0x00000000u);
  assert(len == 24);
  assert_valid_header(buf, len, PPTP_CTRL_SLI);
  assert(util_read_be16(buf + 12u) == 0x3344u);
  assert(util_read_be32(buf + 16u) == 0xffffffffu);
  assert(util_read_be32(buf + 20u) == 0u);

  len = pptp_build_echo_request(buf, sizeof(buf), 0xdeadbeefu);
  assert(len == 16);
  assert_valid_header(buf, len, PPTP_CTRL_ECHORQ);
  assert(util_read_be32(buf + 12u) == 0xdeadbeefu);

  len = pptp_build_echo_reply(buf, sizeof(buf), 0xdeadbeefu);
  assert(len == 20);
  assert_valid_header(buf, len, PPTP_CTRL_ECHORP);
  assert(util_read_be32(buf + 12u) == 0xdeadbeefu);
  assert(buf[16] == 1u && buf[17] == 0u);

  len = pptp_build_ccrq(buf, sizeof(buf), 0x1122u);
  assert(len == 16);
  assert_valid_header(buf, len, PPTP_CTRL_CCRQ);
  assert(util_read_be16(buf + 12u) == 0x1122u);

  len = pptp_build_stopccrq(buf, sizeof(buf), 1u);
  assert(len == 16);
  assert_valid_header(buf, len, PPTP_CTRL_STOPCCRQ);
  assert(buf[12] == 1u);

  len = pptp_build_stopccrp(buf, sizeof(buf));
  assert(len == 16);
  assert_valid_header(buf, len, PPTP_CTRL_STOPCCRP);
  assert(buf[12] == 1u);

  /* Malformed headers must be rejected. */
  assert(pptp_parse_control_header(buf, 11u, NULL, NULL) == -1);
  buf[4] ^= 0xffu; /* corrupt magic cookie */
  assert(pptp_parse_control_header(buf, 16u, NULL, NULL) == -1);
  buf[4] ^= 0xffu;
  util_write_be16(buf + 0u, 8u); /* length < 12 */
  assert(pptp_parse_control_header(buf, 16u, NULL, NULL) == -1);
  util_write_be16(buf + 0u, 16u);
  util_write_be16(buf + 2u, 2u); /* wrong message type */
  assert(pptp_parse_control_header(buf, 16u, NULL, NULL) == -1);

  /* Helper path validation: accept Android 11+ randomized /data/app/~~...== paths, reject shell injection. */
  assert(pptp_is_safe_helper_path("/data/app/~~WpwcJXcOOPWmcHPT3O16HA==/"
                                  "io.github.evokelektrique.tunnelforge-niPg7CT8jSCIOJQl2CmFyw==/lib/arm64/"
                                  "libpptp_gre_helper.so") == 1);
  assert(pptp_is_safe_helper_path("/data/app/io.github.evokelektrique.tunnelforge-1/lib/arm64/libpptp_gre_helper.so") ==
         1);
  assert(pptp_is_safe_helper_path(NULL) == 0);
  assert(pptp_is_safe_helper_path("") == 0);
  assert(pptp_is_safe_helper_path("relative/libpptp_gre_helper.so") == 0);
  assert(pptp_is_safe_helper_path("/data/app/bad'quote/libpptp_gre_helper.so") == 0);
  assert(pptp_is_safe_helper_path("/data/app/bad;cmd/libpptp_gre_helper.so") == 0);
  assert(pptp_is_safe_helper_path("/data/app/bad space/libpptp_gre_helper.so") == 0);
  assert(pptp_is_safe_helper_path("/data/app/$(id)/libpptp_gre_helper.so") == 0);

#ifdef TF_TEST_PPTP_ROOT
  test_pptp_root_pipe_bounds();
#endif

  puts("test_pptp_control: ok");
  return 0;
}
