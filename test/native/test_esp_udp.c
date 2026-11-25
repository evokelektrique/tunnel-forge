#include "esp_udp.h"

#include <assert.h>
#include <string.h>
#include <unistd.h>

void tunnel_engine_log(int priority, const char *tag, const char *format, ...) {
  (void)priority;
  (void)tag;
  (void)format;
}

static void test_esp_round_trip(uint8_t cipher, size_t key_len) {
  esp_keys_t sender = {
      .cipher = cipher,
      .enc_key_len = key_len,
      .auth_key_len = 20,
      .spi_i = 123,
      .seq_i = 1,
      .udp_encap = 1,
      .ip_src = {192, 0, 2, 1},
      .ip_dst = {192, 0, 2, 2},
  };
  esp_keys_t receiver = {
      .cipher = cipher,
      .enc_key_len = key_len,
      .auth_key_len = 20,
      .spi_r = sender.spi_i,
      .udp_encap = 1,
  };
  memset(sender.enc_key, 0x31, key_len);
  memset(sender.auth_key, 0x42, sender.auth_key_len);
  memcpy(receiver.enc_key + key_len, sender.enc_key, key_len);
  memcpy(receiver.auth_key + receiver.auth_key_len, sender.auth_key, receiver.auth_key_len);

  int sockets[2];
  assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets) == 0);
  const uint8_t payload[] = {0x40, 0x02, 0, 10, 0, 1, 0, 1, 0xff, 0x03};
  int sent = esp_encrypt_send(sockets[0], &sender, NULL, 0, payload, sizeof(payload));
  assert(sent > 0);
  uint8_t datagram[128];
  assert(recv(sockets[1], datagram, sizeof(datagram), MSG_DONTWAIT) == sent);
  close(sockets[0]);
  close(sockets[1]);

  uint8_t plaintext[128];
  size_t plaintext_len = sizeof(plaintext);
  assert(esp_try_decrypt(&receiver, datagram, (size_t)sent, plaintext, &plaintext_len) == 0);
  assert(plaintext_len == sizeof(payload) && memcmp(plaintext, payload, plaintext_len) == 0);
  plaintext_len = sizeof(plaintext);
  assert(esp_try_decrypt(&receiver, datagram, (size_t)sent, plaintext, &plaintext_len) == -1);
  assert(sender.cache.tx_cipher_ready && sender.cache.tx_md_ready);
  assert(receiver.cache.rx_cipher_ready && receiver.cache.rx_md_ready);
  esp_keys_cleanup(&sender);
  esp_keys_cleanup(&receiver);
  assert(!sender.cache.tx_cipher_ready && !sender.cache.tx_md_ready);
  assert(!receiver.cache.rx_cipher_ready && !receiver.cache.rx_md_ready);
  assert(sender.enc_key[0] == 0 && receiver.enc_key[key_len] == 0);
}

int main(void) {
  test_esp_round_trip(ESP_CIPHER_AES_CBC, 16);
  test_esp_round_trip(ESP_CIPHER_3DES_CBC, 24);
  return 0;
}
