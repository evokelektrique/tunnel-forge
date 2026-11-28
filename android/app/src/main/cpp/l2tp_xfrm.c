/*
 * Netlink XFRM SA/SP serializer and Linux kernel XFRM installer for root L2TP/IPsec.
 */
#include "l2tp_xfrm.h"

#include "util_endian.h"

#include <errno.h>
#include <string.h>

#ifdef __linux__
#include <arpa/inet.h>
#include <linux/netlink.h>
#include <linux/udp.h>
#include <linux/xfrm.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#ifndef XFRM_STATE_NOPMTUDISC
#define XFRM_STATE_NOPMTUDISC 4u
#endif
#endif

#ifndef AF_INET
#define AF_INET 2
#endif
#ifndef IPPROTO_ESP
#define IPPROTO_ESP 50
#endif
#ifndef IPPROTO_UDP
#define IPPROTO_UDP 17
#endif

#define TF_NL_ALIGN(n) (((n) + 3u) & ~(size_t)3u)

#ifndef __linux__
/* Portable mirror definitions matching standard 64-bit/AAPCS Linux UAPI for Windows/macOS unit tests. */
#define NLM_F_REQUEST 1u
#define NLM_F_ACK 4u
#define NLMSG_ERROR 2u
#define XFRM_MODE_TRANSPORT 0u
#define XFRM_POLICY_IN 0u
#define XFRM_POLICY_OUT 1u
#define XFRM_POLICY_ALLOW 0u
#define XFRM_MSG_NEWSA 0x10u
#define XFRM_MSG_DELSA 0x11u
#define XFRM_MSG_NEWPOLICY 0x13u
#define XFRM_MSG_DELPOLICY 0x14u
#define XFRMA_ALG_CRYPT 2u
#define XFRMA_ENCAP 4u
#define XFRMA_TMPL 5u
#define XFRMA_ALG_AUTH_TRUNC 20u
#define UDP_ENCAP_ESPINUDP 2u
#define XFRM_STATE_NOPMTUDISC 4u
#define XFRM_INF (~(uint64_t)0)

struct nlmsghdr {
  uint32_t nlmsg_len;
  uint16_t nlmsg_type;
  uint16_t nlmsg_flags;
  uint32_t nlmsg_seq;
  uint32_t nlmsg_pid;
};

struct nlmsgerr {
  int32_t error;
  struct nlmsghdr msg;
};

struct nlattr {
  uint16_t nla_len;
  uint16_t nla_type;
};

typedef union {
  uint32_t a4;
  uint32_t a6[4];
} xfrm_address_t;

struct xfrm_id {
  xfrm_address_t daddr;
  uint32_t spi;
  uint8_t proto;
  uint8_t pad[3];
};

struct xfrm_selector {
  xfrm_address_t daddr;
  xfrm_address_t saddr;
  uint16_t dport;
  uint16_t dport_mask;
  uint16_t sport;
  uint16_t sport_mask;
  uint16_t family;
  uint8_t prefixlen_d;
  uint8_t prefixlen_s;
  uint8_t proto;
  uint8_t pad[3];
  int32_t ifindex;
  uint32_t user;
};

struct xfrm_lifetime_cfg {
  uint64_t soft_byte_limit;
  uint64_t hard_byte_limit;
  uint64_t soft_packet_limit;
  uint64_t hard_packet_limit;
  uint64_t soft_add_expires_seconds;
  uint64_t hard_add_expires_seconds;
  uint64_t soft_use_expires_seconds;
  uint64_t hard_use_expires_seconds;
};

struct xfrm_lifetime_cur {
  uint64_t bytes;
  uint64_t packets;
  uint64_t add_time;
  uint64_t use_time;
};

struct xfrm_stats {
  uint32_t replay_window;
  uint32_t replay;
  uint32_t integrity_failed;
};

struct xfrm_usersa_info {
  struct xfrm_selector sel;
  struct xfrm_id id;
  xfrm_address_t saddr;
  struct xfrm_lifetime_cfg lft;
  struct xfrm_lifetime_cur curlft;
  struct xfrm_stats stats;
  uint32_t seq;
  uint32_t reqid;
  uint16_t family;
  uint8_t mode;
  uint8_t replay_window;
  uint8_t flags;
  uint8_t pad[7];
};

struct xfrm_usersa_id {
  xfrm_address_t daddr;
  uint32_t spi;
  uint16_t family;
  uint8_t proto;
  uint8_t pad;
};

struct xfrm_userpolicy_info {
  struct xfrm_selector sel;
  struct xfrm_lifetime_cfg lft;
  struct xfrm_lifetime_cur curlft;
  uint32_t priority;
  uint32_t index;
  uint8_t dir;
  uint8_t action;
  uint8_t flags;
  uint8_t share;
};

struct xfrm_userpolicy_id {
  struct xfrm_selector sel;
  uint32_t index;
  uint8_t dir;
  uint8_t pad[3];
};

struct xfrm_algo {
  char alg_name[64];
  uint32_t alg_key_len;
};

struct xfrm_algo_auth {
  char alg_name[64];
  uint32_t alg_key_len;
  uint32_t alg_trunc_len;
};

struct xfrm_encap_tmpl {
  uint16_t encap_type;
  uint16_t encap_sport;
  uint16_t encap_dport;
  uint16_t pad;
  xfrm_address_t encap_oa;
};

struct xfrm_user_tmpl {
  struct xfrm_id id;
  uint16_t family;
  uint16_t pad;
  xfrm_address_t saddr;
  uint32_t reqid;
  uint8_t mode;
  uint8_t share;
  uint8_t optional;
  uint8_t pad2;
  uint32_t aalgos;
  uint32_t ealgos;
  uint32_t calgos;
};

static uint16_t tf_htons(uint16_t v) {
  uint16_t out;
  util_write_be16((uint8_t *)&out, v);
  return out;
}
#else
#define tf_htons htons
#endif

static int tf_spec_is_valid(const tf_l2tp_xfrm_spec_t *spec) {
  if (spec == NULL)
    return 0;
  if (spec->cipher != TF_L2TP_XFRM_CIPHER_AES && spec->cipher != TF_L2TP_XFRM_CIPHER_3DES)
    return 0;
  size_t expect_enc = (spec->cipher == TF_L2TP_XFRM_CIPHER_AES) ? 16u : 24u;
  if ((size_t)spec->enc_key_len != expect_enc)
    return 0;
  if (spec->auth_key_len != 20u)
    return 0;
  return 1;
}

int tf_l2tp_xfrm_spec_pack(const tf_l2tp_xfrm_spec_t *spec, uint8_t *out, size_t cap) {
  if (!tf_spec_is_valid(spec) || out == NULL || cap < TF_L2TP_XFRM_WIRE_LEN)
    return -1;
  size_t o = 0u;
  memcpy(out + o, spec->local_ipv4, 4u);
  o += 4u;
  memcpy(out + o, spec->peer_ipv4, 4u);
  o += 4u;
  memcpy(out + o, &spec->l2tp_local_port_be, 2u);
  o += 2u;
  memcpy(out + o, &spec->ike_local_port_be, 2u);
  o += 2u;
  util_write_be32(out + o, spec->spi_out_be);
  o += 4u;
  util_write_be32(out + o, spec->spi_in_be);
  o += 4u;
  util_write_be32(out + o, spec->reqid);
  o += 4u;
  out[o++] = spec->cipher;
  out[o++] = spec->enc_key_len;
  out[o++] = spec->auth_key_len;
  out[o++] = spec->use4500 ? 1u : 0u;
  memcpy(out + o, spec->enc_key_out, 32u);
  o += 32u;
  memcpy(out + o, spec->auth_key_out, 32u);
  o += 32u;
  memcpy(out + o, spec->enc_key_in, 32u);
  o += 32u;
  memcpy(out + o, spec->auth_key_in, 32u);
  o += 32u;
  return o == TF_L2TP_XFRM_WIRE_LEN ? 0 : -1;
}

int tf_l2tp_xfrm_spec_unpack(const uint8_t *in, size_t len, tf_l2tp_xfrm_spec_t *spec) {
  if (in == NULL || spec == NULL || len != TF_L2TP_XFRM_WIRE_LEN)
    return -1;
  memset(spec, 0, sizeof(*spec));
  size_t o = 0u;
  memcpy(spec->local_ipv4, in + o, 4u);
  o += 4u;
  memcpy(spec->peer_ipv4, in + o, 4u);
  o += 4u;
  memcpy(&spec->l2tp_local_port_be, in + o, 2u);
  o += 2u;
  memcpy(&spec->ike_local_port_be, in + o, 2u);
  o += 2u;
  spec->spi_out_be = util_read_be32(in + o);
  o += 4u;
  spec->spi_in_be = util_read_be32(in + o);
  o += 4u;
  spec->reqid = util_read_be32(in + o);
  o += 4u;
  spec->cipher = in[o++];
  spec->enc_key_len = in[o++];
  spec->auth_key_len = in[o++];
  spec->use4500 = in[o++] ? 1u : 0u;
  memcpy(spec->enc_key_out, in + o, 32u);
  o += 32u;
  memcpy(spec->auth_key_out, in + o, 32u);
  o += 32u;
  memcpy(spec->enc_key_in, in + o, 32u);
  o += 32u;
  memcpy(spec->auth_key_in, in + o, 32u);
  return tf_spec_is_valid(spec) ? 0 : -1;
}

static size_t tf_nl_append_attr(uint8_t *buf, size_t cap, size_t off, uint16_t type, const void *p1, size_t l1,
                                const void *p2, size_t l2) {
  size_t hdr_len = sizeof(struct nlattr);
  size_t total = hdr_len + l1 + l2;
  size_t aligned = TF_NL_ALIGN(total);
  if (off + aligned > cap || total > UINT16_MAX)
    return 0u;
  struct nlattr attr;
  memset(&attr, 0, sizeof(attr));
  attr.nla_len = (uint16_t)total;
  attr.nla_type = type;
  memset(buf + off, 0, aligned);
  memcpy(buf + off, &attr, hdr_len);
  if (l1 > 0u && p1 != NULL)
    memcpy(buf + off + hdr_len, p1, l1);
  if (l2 > 0u && p2 != NULL)
    memcpy(buf + off + hdr_len + l1, p2, l2);
  return off + aligned;
}

static void tf_fill_lifetime_inf(struct xfrm_lifetime_cfg *lft) {
  lft->soft_byte_limit = XFRM_INF;
  lft->hard_byte_limit = XFRM_INF;
  lft->soft_packet_limit = XFRM_INF;
  lft->hard_packet_limit = XFRM_INF;
}

static size_t tf_nl_begin(uint8_t *buf, size_t cap, uint16_t type, uint32_t seq, const void *body, size_t body_len) {
  size_t hdr_len = TF_NL_ALIGN(sizeof(struct nlmsghdr));
  size_t aligned_body = TF_NL_ALIGN(body_len);
  if (buf == NULL || cap < hdr_len + aligned_body)
    return 0u;
  memset(buf, 0, hdr_len + aligned_body);
  struct nlmsghdr nh;
  memset(&nh, 0, sizeof(nh));
  nh.nlmsg_type = type;
  nh.nlmsg_flags = (uint16_t)(NLM_F_REQUEST | NLM_F_ACK);
  nh.nlmsg_seq = seq;
  memcpy(buf, &nh, sizeof(nh));
  memcpy(buf + hdr_len, body, body_len);
  return hdr_len + aligned_body;
}

static size_t tf_nl_finish(uint8_t *buf, size_t off) {
  if (off == 0u)
    return 0u;
  struct nlmsghdr nh;
  memcpy(&nh, buf, sizeof(nh));
  nh.nlmsg_len = (uint32_t)off;
  memcpy(buf, &nh, sizeof(nh));
  return off;
}

static void tf_fill_policy_selector(struct xfrm_selector *sel, const tf_l2tp_xfrm_spec_t *spec, int dir) {
  memset(sel, 0, sizeof(*sel));
  sel->family = (uint16_t)AF_INET;
  sel->proto = (uint8_t)IPPROTO_UDP;
  sel->prefixlen_s = 32u;
  sel->prefixlen_d = 32u;
  if (dir == (int)TF_XFRM_DIR_OUT) {
    memcpy(&sel->saddr.a4, spec->local_ipv4, 4u);
    memcpy(&sel->daddr.a4, spec->peer_ipv4, 4u);
    sel->sport = spec->l2tp_local_port_be;
    sel->dport = tf_htons(1701u);
  } else {
    memcpy(&sel->saddr.a4, spec->peer_ipv4, 4u);
    memcpy(&sel->daddr.a4, spec->local_ipv4, 4u);
    sel->sport = tf_htons(1701u);
    sel->dport = spec->l2tp_local_port_be;
  }
  sel->sport_mask = 0xffffu;
  sel->dport_mask = 0xffffu;
}

size_t tf_xfrm_nl_build_newsa(uint8_t *buf, size_t cap, uint32_t seq, const tf_l2tp_xfrm_spec_t *spec, int inbound) {
  if (!tf_spec_is_valid(spec))
    return 0u;

  struct xfrm_usersa_info sa;
  memset(&sa, 0, sizeof(sa));
  sa.sel.family = (uint16_t)AF_INET;
  sa.id.proto = (uint8_t)IPPROTO_ESP;
  sa.id.spi = inbound ? spec->spi_in_be : spec->spi_out_be;
  if (inbound) {
    memcpy(&sa.saddr.a4, spec->peer_ipv4, 4u);
    memcpy(&sa.id.daddr.a4, spec->local_ipv4, 4u);
  } else {
    memcpy(&sa.saddr.a4, spec->local_ipv4, 4u);
    memcpy(&sa.id.daddr.a4, spec->peer_ipv4, 4u);
  }
  tf_fill_lifetime_inf(&sa.lft);
  sa.reqid = spec->reqid;
  sa.family = (uint16_t)AF_INET;
  sa.mode = (uint8_t)XFRM_MODE_TRANSPORT;
  sa.replay_window = inbound ? 32u : 0u;
  sa.flags = (uint8_t)XFRM_STATE_NOPMTUDISC;

  size_t off = tf_nl_begin(buf, cap, (uint16_t)XFRM_MSG_NEWSA, seq, &sa, sizeof(sa));
  if (off == 0u)
    return 0u;

  struct xfrm_algo crypt_hdr;
  memset(&crypt_hdr, 0, sizeof(crypt_hdr));
  const char *alg_name = (spec->cipher == TF_L2TP_XFRM_CIPHER_AES) ? "cbc(aes)" : "cbc(des3_ede)";
  memcpy(crypt_hdr.alg_name, alg_name, strlen(alg_name));
  crypt_hdr.alg_key_len = (unsigned int)spec->enc_key_len * 8u;
  const uint8_t *enc_key = inbound ? spec->enc_key_in : spec->enc_key_out;
  off = tf_nl_append_attr(buf, cap, off, (uint16_t)XFRMA_ALG_CRYPT, &crypt_hdr, 68u, enc_key, spec->enc_key_len);
  if (off == 0u)
    return 0u;

  struct xfrm_algo_auth auth_hdr;
  memset(&auth_hdr, 0, sizeof(auth_hdr));
  memcpy(auth_hdr.alg_name, "hmac(sha1)", 10u);
  auth_hdr.alg_key_len = (unsigned int)spec->auth_key_len * 8u;
  auth_hdr.alg_trunc_len = 96u;
  const uint8_t *auth_key = inbound ? spec->auth_key_in : spec->auth_key_out;
  off = tf_nl_append_attr(buf, cap, off, (uint16_t)XFRMA_ALG_AUTH_TRUNC, &auth_hdr, 72u, auth_key, spec->auth_key_len);
  if (off == 0u)
    return 0u;

  if (spec->use4500) {
    struct xfrm_encap_tmpl encap;
    memset(&encap, 0, sizeof(encap));
    encap.encap_type = (uint16_t)UDP_ENCAP_ESPINUDP;
    if (inbound) {
      encap.encap_sport = tf_htons(4500u);
      encap.encap_dport = spec->ike_local_port_be;
    } else {
      encap.encap_sport = spec->ike_local_port_be;
      encap.encap_dport = tf_htons(4500u);
    }
    off = tf_nl_append_attr(buf, cap, off, (uint16_t)XFRMA_ENCAP, &encap, sizeof(encap), NULL, 0u);
    if (off == 0u)
      return 0u;
  }

  return tf_nl_finish(buf, off);
}

size_t tf_xfrm_nl_build_delsa(uint8_t *buf, size_t cap, uint32_t seq, const uint8_t daddr[4], uint32_t spi_be) {
  if (daddr == NULL)
    return 0u;
  struct xfrm_usersa_id id;
  memset(&id, 0, sizeof(id));
  memcpy(&id.daddr.a4, daddr, 4u);
  id.spi = spi_be;
  id.family = (uint16_t)AF_INET;
  id.proto = (uint8_t)IPPROTO_ESP;
  size_t off = tf_nl_begin(buf, cap, (uint16_t)XFRM_MSG_DELSA, seq, &id, sizeof(id));
  return tf_nl_finish(buf, off);
}

size_t tf_xfrm_nl_build_newpolicy(uint8_t *buf, size_t cap, uint32_t seq, const tf_l2tp_xfrm_spec_t *spec, int dir) {
  if (!tf_spec_is_valid(spec) || (dir != (int)TF_XFRM_DIR_IN && dir != (int)TF_XFRM_DIR_OUT))
    return 0u;

  struct xfrm_userpolicy_info pol;
  memset(&pol, 0, sizeof(pol));
  tf_fill_policy_selector(&pol.sel, spec, dir);
  tf_fill_lifetime_inf(&pol.lft);
  pol.priority = 1000u;
  pol.dir = (dir == (int)TF_XFRM_DIR_OUT) ? (uint8_t)XFRM_POLICY_OUT : (uint8_t)XFRM_POLICY_IN;
  pol.action = (uint8_t)XFRM_POLICY_ALLOW;

  size_t off = tf_nl_begin(buf, cap, (uint16_t)XFRM_MSG_NEWPOLICY, seq, &pol, sizeof(pol));
  if (off == 0u)
    return 0u;

  struct xfrm_user_tmpl tmpl;
  memset(&tmpl, 0, sizeof(tmpl));
  tmpl.id.proto = (uint8_t)IPPROTO_ESP;
  tmpl.family = (uint16_t)AF_INET;
  tmpl.saddr = pol.sel.saddr;
  tmpl.id.daddr = pol.sel.daddr;
  tmpl.reqid = spec->reqid;
  tmpl.mode = (uint8_t)XFRM_MODE_TRANSPORT;
  tmpl.aalgos = ~0u;
  tmpl.ealgos = ~0u;
  tmpl.calgos = ~0u;
  off = tf_nl_append_attr(buf, cap, off, (uint16_t)XFRMA_TMPL, &tmpl, sizeof(tmpl), NULL, 0u);
  if (off == 0u)
    return 0u;

  return tf_nl_finish(buf, off);
}

size_t tf_xfrm_nl_build_delpolicy(uint8_t *buf, size_t cap, uint32_t seq, const tf_l2tp_xfrm_spec_t *spec, int dir) {
  if (!tf_spec_is_valid(spec) || (dir != (int)TF_XFRM_DIR_IN && dir != (int)TF_XFRM_DIR_OUT))
    return 0u;
  struct xfrm_userpolicy_id pid;
  memset(&pid, 0, sizeof(pid));
  tf_fill_policy_selector(&pid.sel, spec, dir);
  pid.dir = (dir == (int)TF_XFRM_DIR_OUT) ? (uint8_t)XFRM_POLICY_OUT : (uint8_t)XFRM_POLICY_IN;
  size_t off = tf_nl_begin(buf, cap, (uint16_t)XFRM_MSG_DELPOLICY, seq, &pid, sizeof(pid));
  return tf_nl_finish(buf, off);
}

int tf_xfrm_nl_parse_ack(const uint8_t *msg, size_t msg_len, uint32_t expected_seq, int *out_err) {
  if (out_err != NULL)
    *out_err = 0;
  if (msg == NULL || msg_len < sizeof(struct nlmsghdr))
    return -1;
  size_t off = 0u;
  while (off + sizeof(struct nlmsghdr) <= msg_len) {
    struct nlmsghdr nh;
    memcpy(&nh, msg + off, sizeof(nh));
    if (nh.nlmsg_len < sizeof(struct nlmsghdr) || (size_t)nh.nlmsg_len > msg_len - off)
      return -1;
    if (nh.nlmsg_seq == expected_seq && nh.nlmsg_type == (uint16_t)NLMSG_ERROR) {
      if ((size_t)nh.nlmsg_len < sizeof(struct nlmsghdr) + sizeof(struct nlmsgerr))
        return -1;
      struct nlmsgerr nle;
      memcpy(&nle, msg + off + sizeof(struct nlmsghdr), sizeof(nle));
      if (out_err != NULL)
        *out_err = (nle.error < 0) ? (int)(-nle.error) : (int)nle.error;
      return 1;
    }
    size_t step = TF_NL_ALIGN((size_t)nh.nlmsg_len);
    if (step == 0u || step > msg_len - off)
      break;
    off += step;
  }
  return 0;
}

#ifdef __linux__
static int tf_xfrm_open_netlink(int *out_errno) {
  int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_XFRM);
  if (fd < 0) {
    if (out_errno != NULL)
      *out_errno = errno;
    return -1;
  }
  struct sockaddr_nl local;
  memset(&local, 0, sizeof(local));
  local.nl_family = AF_NETLINK;
  if (bind(fd, (const struct sockaddr *)&local, (socklen_t)sizeof(local)) != 0) {
    int err = errno;
    close(fd);
    if (out_errno != NULL)
      *out_errno = err;
    return -1;
  }
  struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
  (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, (socklen_t)sizeof(tv));
  return fd;
}

static int tf_xfrm_send_and_ack(int nl_fd, const uint8_t *msg, size_t msg_len, uint32_t seq, int *out_errno) {
  if (msg_len == 0u) {
    if (out_errno != NULL)
      *out_errno = EINVAL;
    return -1;
  }
  ssize_t sent = send(nl_fd, msg, msg_len, 0);
  if (sent != (ssize_t)msg_len) {
    if (out_errno != NULL)
      *out_errno = errno != 0 ? errno : EIO;
    return -1;
  }
  uint8_t rx[4096];
  for (int tries = 0; tries < 8; tries++) {
    ssize_t n = recv(nl_fd, rx, sizeof(rx), 0);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      if (out_errno != NULL)
        *out_errno = errno;
      return -1;
    }
    int ack_err = 0;
    int rc = tf_xfrm_nl_parse_ack(rx, (size_t)n, seq, &ack_err);
    if (rc < 0) {
      if (out_errno != NULL)
        *out_errno = EPROTO;
      return -1;
    }
    if (rc == 1) {
      if (ack_err != 0) {
        if (out_errno != NULL)
          *out_errno = ack_err;
        return -1;
      }
      return 0;
    }
  }
  if (out_errno != NULL)
    *out_errno = ETIMEDOUT;
  return -1;
}

int tf_xfrm_install_pair(const tf_l2tp_xfrm_spec_t *spec, int *out_errno) {
  if (out_errno != NULL)
    *out_errno = 0;
  int nl_fd = tf_xfrm_open_netlink(out_errno);
  if (nl_fd < 0)
    return -1;

  uint8_t msg[1024];
  size_t mlen = 0u;
  uint32_t seq = 1u;
  int has_sa_out = 0;
  int has_sa_in = 0;
  int has_sp_out = 0;

  mlen = tf_xfrm_nl_build_newsa(msg, sizeof(msg), seq, spec, 0);
  if (tf_xfrm_send_and_ack(nl_fd, msg, mlen, seq++, out_errno) != 0)
    goto rollback;
  has_sa_out = 1;

  mlen = tf_xfrm_nl_build_newsa(msg, sizeof(msg), seq, spec, 1);
  if (tf_xfrm_send_and_ack(nl_fd, msg, mlen, seq++, out_errno) != 0)
    goto rollback;
  has_sa_in = 1;

  mlen = tf_xfrm_nl_build_newpolicy(msg, sizeof(msg), seq, spec, (int)TF_XFRM_DIR_OUT);
  if (tf_xfrm_send_and_ack(nl_fd, msg, mlen, seq++, out_errno) != 0)
    goto rollback;
  has_sp_out = 1;

  mlen = tf_xfrm_nl_build_newpolicy(msg, sizeof(msg), seq, spec, (int)TF_XFRM_DIR_IN);
  if (tf_xfrm_send_and_ack(nl_fd, msg, mlen, seq++, out_errno) != 0)
    goto rollback;

  close(nl_fd);
  return 0;

rollback:;
  int saved_err = (out_errno != NULL) ? *out_errno : 0;
  if (has_sp_out) {
    mlen = tf_xfrm_nl_build_delpolicy(msg, sizeof(msg), seq, spec, (int)TF_XFRM_DIR_OUT);
    (void)tf_xfrm_send_and_ack(nl_fd, msg, mlen, seq++, NULL);
  }
  if (has_sa_in) {
    mlen = tf_xfrm_nl_build_delsa(msg, sizeof(msg), seq, spec->local_ipv4, spec->spi_in_be);
    (void)tf_xfrm_send_and_ack(nl_fd, msg, mlen, seq++, NULL);
  }
  if (has_sa_out) {
    mlen = tf_xfrm_nl_build_delsa(msg, sizeof(msg), seq, spec->peer_ipv4, spec->spi_out_be);
    (void)tf_xfrm_send_and_ack(nl_fd, msg, mlen, seq++, NULL);
  }
  close(nl_fd);
  if (out_errno != NULL)
    *out_errno = saved_err;
  return -1;
}

void tf_xfrm_delete_pair(const tf_l2tp_xfrm_spec_t *spec) {
  if (!tf_spec_is_valid(spec))
    return;
  int nl_fd = tf_xfrm_open_netlink(NULL);
  if (nl_fd < 0)
    return;
  uint8_t msg[1024];
  uint32_t seq = 100u;
  size_t mlen = tf_xfrm_nl_build_delpolicy(msg, sizeof(msg), seq, spec, (int)TF_XFRM_DIR_IN);
  (void)tf_xfrm_send_and_ack(nl_fd, msg, mlen, seq++, NULL);
  mlen = tf_xfrm_nl_build_delpolicy(msg, sizeof(msg), seq, spec, (int)TF_XFRM_DIR_OUT);
  (void)tf_xfrm_send_and_ack(nl_fd, msg, mlen, seq++, NULL);
  mlen = tf_xfrm_nl_build_delsa(msg, sizeof(msg), seq, spec->local_ipv4, spec->spi_in_be);
  (void)tf_xfrm_send_and_ack(nl_fd, msg, mlen, seq++, NULL);
  mlen = tf_xfrm_nl_build_delsa(msg, sizeof(msg), seq, spec->peer_ipv4, spec->spi_out_be);
  (void)tf_xfrm_send_and_ack(nl_fd, msg, mlen, seq++, NULL);
  close(nl_fd);
}
#endif
