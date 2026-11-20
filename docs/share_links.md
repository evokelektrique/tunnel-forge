# Share links and subscriptions

## Overview

A `tf://` link carries one TunnelForge profile and can be opened by Android or pasted into the app. A `.tfp` profile file contains JSON and has one pointer line to this document when needed.

## Grammar

The grammar is `tf://<server>[?query]`.

- The scheme is case-insensitive.
- `<server>` is the host only. Userinfo, a port, and a path are rejected. `/` is accepted as the empty path.
- Fragments are rejected.
- Query values use UTF-8 percent encoding. Encode spaces as `%20` and non-ASCII text as UTF-8 bytes.
- Unknown query keys are ignored.

## Parameters

| Key | Meaning |
| --- | --- |
| `protocol` | `l2tp` by default. `pptp` selects PPTP. Values are case-insensitive. |
| `displayName` | Optional profile name. Blank names use the app's fallback name rules. |
| `user` | VPN username. |
| `password` | VPN password. |
| `psk` | L2TP/IPsec pre-shared key. PPTP ignores this value. |
| `dns` | Repeatable manual DNS server. At most two unique values are kept. A bare host uses UDP. `tcp://`, `tls://`, and `https://` select DNS transports. No `dns` means automatic DNS. |
| `mtu` | Integer MTU. Default is `1450`. Values are clamped to `576` through `1450`. |

For HTTPS DNS, use `https://host/path` to preserve a DoH endpoint path. Query values are decoded once before validation.

## Examples

An L2TP/IPsec link looks like this.

```text
tf://vpn.example.com?protocol=l2tp&displayName=Office%20L2TP&user=alice&password=secret&psk=shared-secret
```

A PPTP link looks like this.

```text
tf://pptp.example.com?protocol=pptp&displayName=Legacy%20PPTP&user=alice&password=secret
```

A link with custom DNS looks like this.

```text
tf://vpn.example.com?user=alice&password=secret&dns=1.1.1.1&dns=tls%3A%2F%2F1.0.0.1&mtu=1400
```

A link with a non-ASCII name looks like this.

```text
tf://vpn.example.com?displayName=%D8%AF%D9%81%D8%AA%D8%B1&user=alice&password=secret
```

A minimal link uses defaults.

```text
tf://vpn.example.com
```

## Errors

A link is invalid when it uses a legacy compressed `tf://p/...` form, has malformed percent escapes, lacks a server, includes userinfo, a port, a path other than `/`, or a fragment. Non-integer MTU values, unsupported protocols, invalid DNS values, and more than two unique DNS servers are rejected.

## Opening links on Android

Android registers a `VIEW` intent filter for the `tf` scheme. The host passes incoming links to Flutter over the profile-transfer method channel. The app also imports a link from the clipboard. Copying one profile produces one link. Copying multiple profiles produces one link per line.

## Subscriptions

A subscription URL returns a UTF-8 plaintext HTTP or HTTPS body with one `tf://` link per line.

- Blank lines and lines beginning with `#` are ignored.
- A leading UTF-8 BOM is removed.
- Invalid lines are skipped and the count is reported. A body with zero valid links is an error.
- Responses are limited to 5 MiB, with 15 seconds for connection, 20 seconds for reads, and five redirects.
- Requests send `User-Agent: TunnelForge`.
- The app uses a direct route when no tunnel is active and a local HTTP proxy when the tunnel requires it. Fetching is deferred while the tunnel is recovering.

## Sync semantics

Profiles match by `(protocol, server, user)`. A match keeps its profile ID and favorite star. Changed profile fields or secrets count as updated. Profiles missing from a later subscription response are removed with their stored secrets. Duplicate keys match existing profiles in order.

An imported link with a blank name keeps the matched profile's name. A new blank name receives the next available localized `Profile #N` name. Auto-update intervals are clamped to a minimum of 15 minutes and a maximum of 30 days. The default is 24 hours.

## Security notes

Links contain passwords and PSKs in plaintext. Treat them as secrets. The app redacts those values from logs. Serve subscriptions over HTTPS when possible.

## Server operator quick start

Save one link per line as a UTF-8 text file. A sample file follows.

```text
# TunnelForge office profiles
tf://vpn.example.com?protocol=l2tp&displayName=Office&user=alice&password=secret&psk=shared-secret
tf://backup.example.com?protocol=pptp&displayName=Backup&user=bob&password=secret
```

Host that file at an HTTP or HTTPS URL and add the URL as a subscription in TunnelForge.
