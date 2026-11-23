/*
 * JNI surface for Kotlin VpnBridge: explicit registration avoids package-coupled
 * Java_* symbol names. Every jstring is converted with GetStringUTFChars and released on all paths.
 */
#include "engine.h"
#include "esp_udp.h"
#include "gvisor_bridge.h"

#include <android/log.h>
#include <signal.h>
#include <stdlib.h>

#define LOG_TAG "tunnel_engine"
#define VPN_BRIDGE_CLASS "io/github/evokelektrique/tunnelforge/VpnBridge"
#define GVISOR_STATS_COUNT 17

static void throw_io_exception(JNIEnv *env, const char *message) {
  jclass clazz = (*env)->FindClass(env, "java/io/IOException");
  if (clazz != NULL) {
    (*env)->ThrowNew(env, clazz, message);
    (*env)->DeleteLocalRef(env, clazz);
  }
}

void tunnel_loop_stop(void);
int ikev1_run_audit_check(int item_id, char *err_buf, size_t err_cap);
int ppp_run_audit_check(int item_id, char *err_buf, size_t err_cap);
int packet_endpoint_run_audit_check(int item_id, char *err_buf, size_t err_cap);
int pptp_root_run_audit_check(int item_id, char *err_buf, size_t err_cap);

static jint native_negotiate(JNIEnv *env, jclass clazz, jstring jserver, jstring juser, jstring jpassword, jstring jpsk,
                             jint tun_mtu, jint protocol, jint ppp_auth, jint mppe_mode, jintArray jout_client_ipv4,
                             jintArray jout_primary_dns_ipv4, jintArray jout_secondary_dns_ipv4) {
  (void)clazz;
  jint out = (jint)TUNNEL_EXIT_BAD_ARGS;
  const char *server = (*env)->GetStringUTFChars(env, jserver, NULL);
  const char *user = (*env)->GetStringUTFChars(env, juser, NULL);
  const char *password = (*env)->GetStringUTFChars(env, jpassword, NULL);
  const char *psk = (*env)->GetStringUTFChars(env, jpsk, NULL);
  if (server == NULL || user == NULL || password == NULL || psk == NULL) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "nativeNegotiate: null string");
    goto cleanup;
  }
  out = (jint)tunnel_negotiate(server, user, password, psk, (int)tun_mtu, (int)protocol, (int)ppp_auth,
                               (int)mppe_mode);
  if (out == (jint)TUNNEL_EXIT_OK && jout_client_ipv4 != NULL) {
    jsize alen = (*env)->GetArrayLength(env, jout_client_ipv4);
    if (alen >= 4) {
      uint8_t b[4];
      jint tmp[4];
      tunnel_negotiated_client_ipv4(b);
      tmp[0] = (jint)b[0];
      tmp[1] = (jint)b[1];
      tmp[2] = (jint)b[2];
      tmp[3] = (jint)b[3];
      (*env)->SetIntArrayRegion(env, jout_client_ipv4, 0, 4, tmp);
    }
  }
  if (out == (jint)TUNNEL_EXIT_OK) {
    uint8_t primary_dns[4];
    uint8_t secondary_dns[4];
    jint tmp[4];
    tunnel_negotiated_dns_ipv4(primary_dns, secondary_dns);
    if (jout_primary_dns_ipv4 != NULL && (*env)->GetArrayLength(env, jout_primary_dns_ipv4) >= 4) {
      tmp[0] = (jint)primary_dns[0];
      tmp[1] = (jint)primary_dns[1];
      tmp[2] = (jint)primary_dns[2];
      tmp[3] = (jint)primary_dns[3];
      (*env)->SetIntArrayRegion(env, jout_primary_dns_ipv4, 0, 4, tmp);
    }
    if (jout_secondary_dns_ipv4 != NULL && (*env)->GetArrayLength(env, jout_secondary_dns_ipv4) >= 4) {
      tmp[0] = (jint)secondary_dns[0];
      tmp[1] = (jint)secondary_dns[1];
      tmp[2] = (jint)secondary_dns[2];
      tmp[3] = (jint)secondary_dns[3];
      (*env)->SetIntArrayRegion(env, jout_secondary_dns_ipv4, 0, 4, tmp);
    }
  }

cleanup:
  if (server != NULL)
    (*env)->ReleaseStringUTFChars(env, jserver, server);
  if (user != NULL)
    (*env)->ReleaseStringUTFChars(env, juser, user);
  if (password != NULL)
    (*env)->ReleaseStringUTFChars(env, jpassword, password);
  if (psk != NULL)
    (*env)->ReleaseStringUTFChars(env, jpsk, psk);
  return out;
}

static jintArray native_failure(JNIEnv *env, jclass clazz) {
  (void)clazz;
  int failure[3];
  tunnel_get_failure(failure);
  jint values[3] = {failure[0], failure[1], failure[2]};
  jintArray out = (*env)->NewIntArray(env, 3);
  if (out != NULL)
    (*env)->SetIntArrayRegion(env, out, 0, 3, values);
  return out;
}

static void native_set_socket_protection_enabled(JNIEnv *env, jclass clazz, jboolean enabled) {
  (void)env;
  (void)clazz;
  engine_set_socket_protection_enabled(enabled ? 1 : 0);
}

static void native_set_pptp_runtime_config(JNIEnv *env, jclass clazz, jstring jhelper_path, jstring jbind_iface) {
  (void)clazz;
  const char *helper_path = jhelper_path != NULL ? (*env)->GetStringUTFChars(env, jhelper_path, NULL) : NULL;
  const char *bind_iface = jbind_iface != NULL ? (*env)->GetStringUTFChars(env, jbind_iface, NULL) : NULL;
  engine_set_pptp_runtime_config(helper_path, bind_iface);
  if (helper_path != NULL)
    (*env)->ReleaseStringUTFChars(env, jhelper_path, helper_path);
  if (bind_iface != NULL)
    (*env)->ReleaseStringUTFChars(env, jbind_iface, bind_iface);
}

static jint native_start_loop(JNIEnv *env, jclass clazz, jint tun_fd) {
  (void)env;
  (void)clazz;
  return (jint)tunnel_run_loop(tun_fd);
}

static jint native_start_proxy_loop(JNIEnv *env, jclass clazz) {
  (void)env;
  (void)clazz;
  return (jint)tunnel_run_proxy_loop();
}

static jint native_gvisor_start(JNIEnv *env, jclass clazz, jintArray jclient_ipv4, jint mtu) {
  (void)clazz;
  if (jclient_ipv4 == NULL || (*env)->GetArrayLength(env, jclient_ipv4) < 4)
    return -1;
  jint tmp[4];
  (*env)->GetIntArrayRegion(env, jclient_ipv4, 0, 4, tmp);
  uint8_t client_ipv4[4];
  for (int i = 0; i < 4; i++) {
    if (tmp[i] < 0 || tmp[i] > 255)
      return -1;
    client_ipv4[i] = (uint8_t)tmp[i];
  }
  return (jint)gvisor_bridge_start(client_ipv4, (int)mtu);
}

static void native_gvisor_stop(JNIEnv *env, jclass clazz) {
  (void)env;
  (void)clazz;
  gvisor_bridge_stop();
}

static jint native_gvisor_inject_inbound(JNIEnv *env, jclass clazz, jbyteArray jpacket) {
  (void)clazz;
  if (jpacket == NULL)
    return -1;
  jsize len = (*env)->GetArrayLength(env, jpacket);
  if (len <= 0)
    return -1;
  jbyte *bytes = (*env)->GetByteArrayElements(env, jpacket, NULL);
  if (bytes == NULL)
    return -1;
  int rc = gvisor_bridge_inject_inbound((const uint8_t *)bytes, (size_t)len);
  (*env)->ReleaseByteArrayElements(env, jpacket, bytes, JNI_ABORT);
  return (jint)rc;
}

static jbyteArray native_gvisor_read_outbound(JNIEnv *env, jclass clazz, jint max_len, jint timeout_ms) {
  (void)clazz;
  if (max_len <= 0)
    return NULL;
  uint8_t *buf = (uint8_t *)malloc((size_t)max_len);
  if (buf == NULL)
    return NULL;
  ssize_t n = gvisor_bridge_read_outbound(buf, (size_t)max_len, (int)timeout_ms);
  if (n <= 0) {
    free(buf);
    return NULL;
  }
  jbyteArray out = (*env)->NewByteArray(env, (jsize)n);
  if (out != NULL) {
    (*env)->SetByteArrayRegion(env, out, 0, (jsize)n, (const jbyte *)buf);
  }
  free(buf);
  return out;
}

static jint native_gvisor_tcp_open_cancelable(JNIEnv *env, jclass clazz, jint open_id, jintArray jremote_ipv4,
                                              jint port, jint timeout_ms) {
  (void)clazz;
  if (open_id <= 0 || jremote_ipv4 == NULL || (*env)->GetArrayLength(env, jremote_ipv4) < 4 || port <= 0 ||
      port > 65535)
    return -1;
  jint tmp[4];
  (*env)->GetIntArrayRegion(env, jremote_ipv4, 0, 4, tmp);
  uint8_t remote_ipv4[4];
  for (int i = 0; i < 4; i++) {
    if (tmp[i] < 0 || tmp[i] > 255)
      return -1;
    remote_ipv4[i] = (uint8_t)tmp[i];
  }
  return (jint)gvisor_bridge_tcp_open_cancelable((int)open_id, remote_ipv4, (uint16_t)port, (int)timeout_ms);
}

static jint native_gvisor_tcp_cancel_open(JNIEnv *env, jclass clazz, jint open_id) {
  (void)env;
  (void)clazz;
  return (jint)gvisor_bridge_tcp_cancel_open((int)open_id);
}

static jbyteArray native_gvisor_tcp_read(JNIEnv *env, jclass clazz, jint session_id, jint max_len, jint timeout_ms) {
  (void)clazz;
  if (session_id <= 0 || max_len <= 0)
    return NULL;
  uint8_t *buf = (uint8_t *)malloc((size_t)max_len);
  if (buf == NULL)
    return NULL;
  ssize_t n = gvisor_bridge_tcp_read((int)session_id, buf, (size_t)max_len, (int)timeout_ms);
  if (n <= 0) {
    free(buf);
    if (n == 0)
      return (*env)->NewByteArray(env, 0);
    if (n == -4)
      return NULL;
    if (n == -5) {
      throw_io_exception(env, "gVisor TCP read failed: connection reset.");
    } else if (n == -2) {
      throw_io_exception(env, "gVisor TCP read failed: session closed locally.");
    } else {
      throw_io_exception(env, "gVisor TCP read failed: internal gVisor error.");
    }
    return NULL;
  }
  jbyteArray out = (*env)->NewByteArray(env, (jsize)n);
  if (out != NULL) {
    (*env)->SetByteArrayRegion(env, out, 0, (jsize)n, (const jbyte *)buf);
  }
  free(buf);
  return out;
}

static jint native_gvisor_tcp_write(JNIEnv *env, jclass clazz, jint session_id, jbyteArray jbytes, jint timeout_ms) {
  (void)clazz;
  if (session_id <= 0 || jbytes == NULL)
    return -1;
  jsize len = (*env)->GetArrayLength(env, jbytes);
  if (len <= 0)
    return 0;
  jbyte *bytes = (*env)->GetByteArrayElements(env, jbytes, NULL);
  if (bytes == NULL)
    return -1;
  ssize_t n = gvisor_bridge_tcp_write((int)session_id, (const uint8_t *)bytes, (size_t)len, (int)timeout_ms);
  (*env)->ReleaseByteArrayElements(env, jbytes, bytes, JNI_ABORT);
  return (jint)n;
}

static void native_gvisor_tcp_close(JNIEnv *env, jclass clazz, jint session_id) {
  (void)env;
  (void)clazz;
  if (session_id > 0)
    gvisor_bridge_tcp_close((int)session_id);
}

static jintArray native_gvisor_stats(JNIEnv *env, jclass clazz) {
  (void)clazz;
  int stats[GVISOR_STATS_COUNT] = {0};
  gvisor_bridge_stats(stats, GVISOR_STATS_COUNT);
  jintArray out = (*env)->NewIntArray(env, GVISOR_STATS_COUNT);
  if (out == NULL)
    return NULL;
  (*env)->SetIntArrayRegion(env, out, 0, GVISOR_STATS_COUNT, stats);
  return out;
}

static jstring native_gvisor_open_diagnostics(JNIEnv *env, jclass clazz, jint open_id) {
  (void)clazz;
  char buf[512];
  int n = gvisor_bridge_open_diagnostics((int)open_id, buf, sizeof(buf));
  if (n <= 0)
    return (*env)->NewStringUTF(env, "");
  buf[sizeof(buf) - 1u] = '\0';
  return (*env)->NewStringUTF(env, buf);
}

static jboolean native_is_proxy_packet_bridge_active(JNIEnv *env, jclass clazz) {
  (void)env;
  (void)clazz;
  return tunnel_proxy_is_bridge_active() ? JNI_TRUE : JNI_FALSE;
}

static jint native_queue_proxy_outbound_packet(JNIEnv *env, jclass clazz, jbyteArray jpacket) {
  (void)clazz;
  if (jpacket == NULL)
    return (jint)TUNNEL_EXIT_BAD_ARGS;
  jsize len = (*env)->GetArrayLength(env, jpacket);
  if (len <= 0)
    return (jint)TUNNEL_EXIT_BAD_ARGS;
  jbyte *bytes = (*env)->GetByteArrayElements(env, jpacket, NULL);
  if (bytes == NULL)
    return (jint)TUNNEL_EXIT_BAD_ARGS;
  int rc = tunnel_proxy_enqueue_outbound_packet((const uint8_t *)bytes, (size_t)len);
  (*env)->ReleaseByteArrayElements(env, jpacket, bytes, JNI_ABORT);
  return (jint)rc;
}

static jbyteArray native_read_proxy_inbound_packet(JNIEnv *env, jclass clazz, jint max_len) {
  (void)clazz;
  if (max_len <= 0)
    return NULL;
  uint8_t *buf = (uint8_t *)malloc((size_t)max_len);
  if (buf == NULL)
    return NULL;
  ssize_t n = tunnel_proxy_dequeue_inbound_packet_wait(buf, (size_t)max_len, 50);
  if (n <= 0) {
    free(buf);
    return NULL;
  }
  jbyteArray out = (*env)->NewByteArray(env, (jsize)n);
  if (out != NULL) {
    (*env)->SetByteArrayRegion(env, out, 0, (jsize)n, (const jbyte *)buf);
  }
  free(buf);
  return out;
}

static jint native_set_vpn_dns_intercept_ipv4(JNIEnv *env, jclass clazz, jstring jipv4) {
  (void)clazz;
  if (jipv4 == NULL)
    return (jint)tunnel_vpn_dns_set_intercept_ipv4(NULL);
  const char *ipv4 = (*env)->GetStringUTFChars(env, jipv4, NULL);
  if (ipv4 == NULL)
    return (jint)TUNNEL_EXIT_BAD_ARGS;
  int rc = tunnel_vpn_dns_set_intercept_ipv4(ipv4);
  (*env)->ReleaseStringUTFChars(env, jipv4, ipv4);
  return (jint)rc;
}

static jbyteArray native_read_vpn_dns_query(JNIEnv *env, jclass clazz, jint max_len) {
  (void)clazz;
  if (max_len <= 0)
    return NULL;
  uint8_t *buf = (uint8_t *)malloc((size_t)max_len);
  if (buf == NULL)
    return NULL;
  ssize_t n = tunnel_vpn_dns_dequeue_query_wait(buf, (size_t)max_len, 50);
  if (n <= 0) {
    free(buf);
    return NULL;
  }
  jbyteArray out = (*env)->NewByteArray(env, (jsize)n);
  if (out != NULL) {
    (*env)->SetByteArrayRegion(env, out, 0, (jsize)n, (const jbyte *)buf);
  }
  free(buf);
  return out;
}

static jint native_queue_vpn_dns_response(JNIEnv *env, jclass clazz, jbyteArray jpacket) {
  (void)clazz;
  if (jpacket == NULL)
    return (jint)TUNNEL_EXIT_BAD_ARGS;
  jsize len = (*env)->GetArrayLength(env, jpacket);
  if (len <= 0)
    return (jint)TUNNEL_EXIT_BAD_ARGS;
  jbyte *bytes = (*env)->GetByteArrayElements(env, jpacket, NULL);
  if (bytes == NULL)
    return (jint)TUNNEL_EXIT_BAD_ARGS;
  int rc = tunnel_vpn_dns_write_response_packet((const uint8_t *)bytes, (size_t)len);
  (*env)->ReleaseByteArrayElements(env, jpacket, bytes, JNI_ABORT);
  return (jint)rc;
}

static void native_stop_tunnel(JNIEnv *env, jclass clazz) {
  (void)env;
  (void)clazz;
  tunnel_loop_stop();
}

static jstring native_run_audit_check(JNIEnv *env, jclass clazz, jint item_id) {
  (void)clazz;
  char err_buf[512] = {0};
  int rc = -1;
  switch ((int)item_id) {
  case 1:
  case 3:
    rc = ikev1_run_audit_check((int)item_id, err_buf, sizeof(err_buf));
    break;
  case 2:
  case 4:
    rc = ppp_run_audit_check((int)item_id, err_buf, sizeof(err_buf));
    break;
  case 5:
    rc = packet_endpoint_run_audit_check((int)item_id, err_buf, sizeof(err_buf));
    break;
  case 7:
    rc = pptp_root_run_audit_check((int)item_id, err_buf, sizeof(err_buf));
    break;
  case 16:
    rc = esp_run_audit_check((int)item_id, err_buf, sizeof(err_buf));
    break;
  default:
    snprintf(err_buf, sizeof(err_buf), "unknown native audit itemId=%d", (int)item_id);
    rc = -1;
    break;
  }
  if (rc == 0)
    return NULL;
  if (err_buf[0] == '\0')
    snprintf(err_buf, sizeof(err_buf), "native audit item %d failed rc=%d", (int)item_id, rc);
  return (*env)->NewStringUTF(env, err_buf);
}

static int register_vpn_bridge(JNIEnv *env) {
  static const JNINativeMethod methods[] = {
      {"nativeFailure", "()[I", (void *)native_failure},
      {"nativeNegotiate", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;IIII[I[I[I)I",
       (void *)native_negotiate},
      {"nativeSetSocketProtectionEnabled", "(Z)V", (void *)native_set_socket_protection_enabled},
      {"nativeSetPptpRuntimeConfig", "(Ljava/lang/String;Ljava/lang/String;)V", (void *)native_set_pptp_runtime_config},
      {"nativeStartLoop", "(I)I", (void *)native_start_loop},
      {"nativeStartProxyLoop", "()I", (void *)native_start_proxy_loop},
      {"nativeGvisorStart", "([II)I", (void *)native_gvisor_start},
      {"nativeGvisorStop", "()V", (void *)native_gvisor_stop},
      {"nativeGvisorInjectInbound", "([B)I", (void *)native_gvisor_inject_inbound},
      {"nativeGvisorReadOutbound", "(II)[B", (void *)native_gvisor_read_outbound},
      {"nativeGvisorTcpOpenCancelable", "(I[III)I", (void *)native_gvisor_tcp_open_cancelable},
      {"nativeGvisorTcpCancelOpen", "(I)I", (void *)native_gvisor_tcp_cancel_open},
      {"nativeGvisorTcpRead", "(III)[B", (void *)native_gvisor_tcp_read},
      {"nativeGvisorTcpWrite", "(I[BI)I", (void *)native_gvisor_tcp_write},
      {"nativeGvisorTcpClose", "(I)V", (void *)native_gvisor_tcp_close},
      {"nativeGvisorStats", "()[I", (void *)native_gvisor_stats},
      {"nativeGvisorOpenDiagnostics", "(I)Ljava/lang/String;", (void *)native_gvisor_open_diagnostics},
      {"nativeIsProxyPacketBridgeActive", "()Z", (void *)native_is_proxy_packet_bridge_active},
      {"nativeQueueProxyOutboundPacket", "([B)I", (void *)native_queue_proxy_outbound_packet},
      {"nativeReadProxyInboundPacket", "(I)[B", (void *)native_read_proxy_inbound_packet},
      {"nativeSetVpnDnsInterceptIpv4", "(Ljava/lang/String;)I", (void *)native_set_vpn_dns_intercept_ipv4},
      {"nativeReadVpnDnsQuery", "(I)[B", (void *)native_read_vpn_dns_query},
      {"nativeQueueVpnDnsResponse", "([B)I", (void *)native_queue_vpn_dns_response},
      {"nativeStopTunnel", "()V", (void *)native_stop_tunnel},
      {"nativeRunAuditCheck", "(I)Ljava/lang/String;", (void *)native_run_audit_check},
  };
  jclass bridge_class = (*env)->FindClass(env, VPN_BRIDGE_CLASS);
  if (bridge_class == NULL) {
    (*env)->ExceptionClear(env);
    __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "JNI_OnLoad: could not find %s", VPN_BRIDGE_CLASS);
    return -1;
  }
  if ((*env)->RegisterNatives(env, bridge_class, methods, (jint)(sizeof(methods) / sizeof(methods[0]))) != JNI_OK) {
    (*env)->ExceptionClear(env);
    (*env)->DeleteLocalRef(env, bridge_class);
    __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "JNI_OnLoad: RegisterNatives failed for %s", VPN_BRIDGE_CLASS);
    return -1;
  }
  (*env)->DeleteLocalRef(env, bridge_class);
  return 0;
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
  (void)reserved;
  signal(SIGPIPE, SIG_IGN);
  JNIEnv *env = NULL;
  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK || env == NULL) {
    __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "JNI_OnLoad: GetEnv failed");
    return JNI_ERR;
  }
  engine_set_java_vm(vm);
  if (engine_jni_init(env) != 0) {
    __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "JNI_OnLoad: engine_jni_init failed");
    return JNI_ERR;
  }
  if (register_vpn_bridge(env) != 0) {
    engine_jni_cleanup(env);
    return JNI_ERR;
  }
  return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL JNI_OnUnload(JavaVM *vm, void *reserved) {
  (void)reserved;
  JNIEnv *env = NULL;
  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK && env != NULL) {
    engine_jni_cleanup(env);
  }
  engine_set_java_vm(NULL);
}
