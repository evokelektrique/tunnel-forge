import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/tunnel/data/vpn_client.dart';
import 'package:tunnel_forge/features/tunnel/data/vpn_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VpnClient.prepareVpn', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(VpnContract.channel),
            null,
          );
    });

    test('returns false when platform returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(VpnContract.channel), (
            call,
          ) async {
            expect(call.method, VpnContract.prepareVpn);
            return null;
          });
      expect(await VpnClient().prepareVpn(), isFalse);
    });

    test('returns false when platform returns non-bool', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(VpnContract.channel), (
            call,
          ) async {
            return 'yes';
          });
      expect(await VpnClient().prepareVpn(), isFalse);
    });
  });

  group('VpnClient.connect', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(VpnContract.channel),
            null,
          );
    });

    test('throws PlatformException when platform reports error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(VpnContract.channel), (
            call,
          ) async {
            if (call.method == VpnContract.connect) {
              throw PlatformException(
                code: 'vpn_permission',
                message: 'not granted',
              );
            }
            return null;
          });
      expect(
        () => VpnClient().connect(server: 'x.example'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'vpn_permission',
          ),
        ),
      );
    });

    test('sends ordered dns servers in manual mode', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(VpnContract.channel), (
            call,
          ) async {
            capturedCall = call;
            return null;
          });

      await VpnClient().connect(
        server: 'x.example',
        dnsAutomatic: false,
        dnsServers: const [
          DnsServerConfig(host: '1.1.1.1', protocol: DnsProtocol.dnsOverUdp),
          DnsServerConfig(host: '8.8.8.8', protocol: DnsProtocol.dnsOverTcp),
          DnsServerConfig(host: '1.1.1.1', protocol: DnsProtocol.dnsOverUdp),
        ],
      );

      expect(capturedCall?.method, VpnContract.connect);
      final args = Map<Object?, Object?>.from(capturedCall?.arguments as Map);
      expect(args[VpnContract.argDnsAutomatic], isFalse);
      expect(args[VpnContract.argDnsServers], [
        {
          VpnContract.argDnsServerHost: '1.1.1.1',
          VpnContract.argDnsServerProtocol: DnsProtocol.dnsOverUdp.jsonValue,
        },
        {
          VpnContract.argDnsServerHost: '8.8.8.8',
          VpnContract.argDnsServerProtocol: DnsProtocol.dnsOverTcp.jsonValue,
        },
        {
          VpnContract.argDnsServerHost: '1.1.1.1',
          VpnContract.argDnsServerProtocol: DnsProtocol.dnsOverUdp.jsonValue,
        },
      ]);
    });

    test('sends automatic dns mode without explicit servers', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(VpnContract.channel), (
            call,
          ) async {
            capturedCall = call;
            return null;
          });

      await VpnClient().connect(server: 'x.example');

      final args = Map<Object?, Object?>.from(capturedCall?.arguments as Map);
      expect(args[VpnContract.argProtocol], VpnContract.protocolL2tp);
      expect(args[VpnContract.argDnsAutomatic], isTrue);
      expect(args[VpnContract.argDnsServers], isEmpty);
    });

    test('sends pptp protocol and clears psk when connecting PPTP', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(VpnContract.channel), (
            call,
          ) async {
            capturedCall = call;
            return null;
          });

      await VpnClient().connect(
        server: 'pptp.example',
        protocol: TunnelProtocol.pptp,
        user: 'alice',
        password: 'pw',
        psk: 'ignored',
      );

      final args = Map<Object?, Object?>.from(capturedCall?.arguments as Map);
      expect(args[VpnContract.argProtocol], VpnContract.protocolPptp);
      expect(args[VpnContract.argPppAuth], VpnContract.pppAuthAuto);
      expect(args[VpnContract.argMppe], VpnContract.mppeAuto);
      expect(args[VpnContract.argPsk], isEmpty);
    });

    test('sends explicit pppAuth and mppeMode for PPTP and normalizes L2TP mppe', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(VpnContract.channel), (
            call,
          ) async {
            capturedCall = call;
            return null;
          });

      await VpnClient().connect(
        server: 'pptp.example',
        protocol: TunnelProtocol.pptp,
        pppAuth: PppAuthMethod.mschapV2,
        mppeMode: MppeMode.off,
      );
      var args = Map<Object?, Object?>.from(capturedCall?.arguments as Map);
      expect(args[VpnContract.argPppAuth], VpnContract.pppAuthMschapV2);
      expect(args[VpnContract.argMppe], VpnContract.mppeOff);

      await VpnClient().connect(
        server: 'l2tp.example',
        protocol: TunnelProtocol.l2tp,
        pppAuth: PppAuthMethod.pap,
        mppeMode: MppeMode.on,
      );
      args = Map<Object?, Object?>.from(capturedCall?.arguments as Map);
      expect(args[VpnContract.argPppAuth], VpnContract.pppAuthPap);
      expect(args[VpnContract.argMppe], VpnContract.mppeAuto);
    });
  });
}
