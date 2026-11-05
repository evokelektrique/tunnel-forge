/* Run on Android against the Docker gateway with a UDP echo service on 192.168.42.1:41888.
 * Arguments: host username password PSK. Never print these arguments. */
#include "engine.h"
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
extern void tunnel_loop_stop(void);
static void *loop(void *unused) {
  (void)unused;
  return (void *)(long)tunnel_run_proxy_loop();
}
int main(int argc, char **argv) {
  if (argc != 5)
    return 99;
  engine_set_socket_protection_enabled(0);
  for (int round = 0; round < 2; round++) {
    int rc = tunnel_negotiate(argv[1], argv[2], argv[3], argv[4], 1400);
    printf("round=%d negotiation=%d\n", round, rc);
    fflush(stdout);
    if (rc)
      return rc;
    uint8_t ip[4];
    tunnel_negotiated_client_ipv4(ip);
    printf("IPCP=%u.%u.%u.%u\n", ip[0], ip[1], ip[2], ip[3]);
    pthread_t t;
    pthread_create(&t, NULL, loop, NULL);
    for (int i = 0; i < 100 && !tunnel_proxy_is_bridge_active(); i++)
      usleep(20000);
    const char payload[] = "TunnelForge gateway proof";
    uint8_t packet[28 + sizeof(payload)] = {0x45};
    util_write_be16(packet + 2, sizeof(packet));
    packet[8] = 64;
    packet[9] = 17;
    memcpy(packet + 12, ip, 4);
    uint8_t dest[] = {192, 168, 42, 1};
    memcpy(packet + 16, dest, 4);
    unsigned sum = 0;
    for (int i = 0; i < 20; i += 2)
      sum += util_read_be16(packet + i);
    while (sum >> 16)
      sum = (sum & 65535) + (sum >> 16);
    util_write_be16(packet + 10, (uint16_t)~sum);
    util_write_be16(packet + 20, 41887);
    util_write_be16(packet + 22, 41888);
    util_write_be16(packet + 24, 8 + sizeof(payload));
    memcpy(packet + 28, payload, sizeof(payload));
    int sent = tunnel_proxy_enqueue_outbound_packet(packet, sizeof(packet));
    uint8_t reply[4096];
    int echoed = 0;
    for (int i = 0; i < 10 && !echoed; i++) {
      ssize_t n = tunnel_proxy_dequeue_inbound_packet_wait(reply, sizeof(reply), 1000);
      echoed = n >= (ssize_t)sizeof(packet) && !memcmp(reply + n - sizeof(payload), payload, sizeof(payload));
    }
    printf("queued=%d UDP_echo=%d\n", sent, echoed);
    fflush(stdout);
    tunnel_loop_stop();
    pthread_join(t, NULL);
    if (!echoed)
      return 97;
  }
  return 0;
}
