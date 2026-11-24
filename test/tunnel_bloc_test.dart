import 'dart:async';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_forge/features/home/domain/home_models.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/tunnel_bloc.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/tunnel/data/vpn_contract.dart';
import 'package:tunnel_forge/features/tunnel/domain/tunnel_runtime_state.dart';
import 'package:tunnel_forge/features/tunnel/domain/tunnel_failure.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

void main() {
  final failureLogs = _FakeLogsRepository();
  const authFailure = TunnelFailure(namespace: 'mschap', code: '691');
  blocTest<TunnelBloc, TunnelState>(
    'reports a structured failure once and logs its code and label',
    build: () => TunnelBloc(_FakeTunnelRepository(), failureLogs),
    seed: () => const TunnelState(
      activeAttemptId: 'attempt-auth',
      awaitingTunnel: true,
    ),
    act: (bloc) {
      const event = TunnelHostStateReceived(
        TunnelHostUpdate(
          state: VpnTunnelState.failed,
          detail: 'PPP negotiation failed.',
          attemptId: 'attempt-auth',
          failure: authFailure,
        ),
      );
      bloc.add(event);
      bloc.add(event);
    },
    expect: () => [
      const TunnelState(),
      const TunnelState(
        message: HomeMessage(
          id: 1,
          text: 'PPP negotiation failed.',
          error: true,
          failure: authFailure,
        ),
      ),
    ],
    verify: (_) {
      expect(
        failureLogs.entries
            .where((entry) => entry.tag == 'TunnelFailure')
            .single
            .message,
        authFailure.summary,
      );
    },
  );

  blocTest<TunnelBloc, TunnelState>(
    'ignores stale failure from an older attempt while a newer tunnel is up',
    build: () => TunnelBloc(_FakeTunnelRepository(), _FakeLogsRepository()),
    seed: () =>
        const TunnelState(tunnelUp: true, activeAttemptId: 'attempt-new'),
    act: (bloc) {
      bloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.failed,
            detail: 'L2TP handshake failed.',
            attemptId: 'attempt-old',
          ),
        ),
      );
    },
    expect: () => const <TunnelState>[],
  );

  blocTest<TunnelBloc, TunnelState>(
    'current failure clears active attempt and disconnects the tunnel',
    build: () => TunnelBloc(_FakeTunnelRepository(), _FakeLogsRepository()),
    seed: () =>
        const TunnelState(tunnelUp: true, activeAttemptId: 'attempt-current'),
    act: (bloc) {
      bloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.failed,
            detail: 'L2TP handshake failed.',
            attemptId: 'attempt-current',
          ),
        ),
      );
    },
    expect: () => [
      const TunnelState(tunnelUp: false, activeAttemptId: null),
      const TunnelState(
        tunnelUp: false,
        activeAttemptId: null,
        message: HomeMessage(
          id: 1,
          text: 'L2TP handshake failed.',
          error: true,
          failure: TunnelFailure(
            namespace: 'app',
            code: 'UNKNOWN',
            detail: 'L2TP handshake failed.',
          ),
        ),
      ),
    ],
  );

  blocTest<TunnelBloc, TunnelState>(
    'shutdown-induced proxy failure during stop is treated as stopped',
    build: () => TunnelBloc(_FakeTunnelRepository(), _FakeLogsRepository()),
    seed: () => const TunnelState(
      tunnelUp: true,
      stopRequested: true,
      connectionMode: ConnectionMode.proxyOnly,
      activeAttemptId: 'attempt-current',
    ),
    act: (bloc) {
      bloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.failed,
            detail: 'Local proxy connection was lost.',
            attemptId: 'attempt-current',
          ),
        ),
      );
    },
    expect: () => const [TunnelState(connectionMode: ConnectionMode.proxyOnly)],
  );

  blocTest<TunnelBloc, TunnelState>(
    'connect request is ignored while disconnect is pending',
    build: () {
      return TunnelBloc(_countingTunnelRepository, _FakeLogsRepository());
    },
    setUp: () {
      _countingTunnelRepository = _CountingTunnelRepository();
    },
    seed: () => const TunnelState(stopRequested: true),
    act: (bloc) {
      bloc.add(TunnelConnectRequested(_connectRequest()));
    },
    expect: () => const <TunnelState>[],
    verify: (_) {
      expect(_countingTunnelRepository.connectCalls, 0);
    },
  );

  blocTest<TunnelBloc, TunnelState>(
    'startup bootstraps connected vpn runtime state',
    build: () => TunnelBloc(
      _FakeTunnelRepository(
        runtimeState: const TunnelRuntimeState(
          state: VpnTunnelState.connected,
          detail: 'VPN connected',
          connectionMode: ConnectionMode.vpnTunnel,
          attemptId: 'attempt-vpn',
        ),
      ),
      _FakeLogsRepository(),
    ),
    act: (bloc) => bloc.add(const TunnelStarted()),
    expect: () => const [
      TunnelState(
        tunnelUp: true,
        connectionMode: ConnectionMode.vpnTunnel,
        activeAttemptId: 'attempt-vpn',
      ),
    ],
  );

  blocTest<TunnelBloc, TunnelState>(
    'startup bootstraps connected proxy runtime state with exposure',
    build: () => TunnelBloc(
      _FakeTunnelRepository(
        runtimeState: const TunnelRuntimeState(
          state: VpnTunnelState.connected,
          detail: 'Local proxy listeners are active.',
          connectionMode: ConnectionMode.proxyOnly,
          attemptId: 'attempt-proxy',
          proxyExposure: ProxyExposure(
            active: true,
            bindAddress: '0.0.0.0',
            displayAddress: '192.168.1.20',
            httpPort: 18080,
            socksPort: 11080,
            lanRequested: true,
            lanActive: true,
          ),
        ),
      ),
      _FakeLogsRepository(),
    ),
    act: (bloc) => bloc.add(const TunnelStarted()),
    expect: () => const [
      TunnelState(
        tunnelUp: true,
        connectionMode: ConnectionMode.proxyOnly,
        activeAttemptId: 'attempt-proxy',
        proxyExposure: ProxyExposure(
          active: true,
          bindAddress: '0.0.0.0',
          displayAddress: '192.168.1.20',
          httpPort: 18080,
          socksPort: 11080,
          lanRequested: true,
          lanActive: true,
        ),
      ),
    ],
  );

  blocTest<TunnelBloc, TunnelState>(
    'connect request is ignored when runtime bootstrap has tunnel up',
    build: () {
      _countingTunnelRepository = _CountingTunnelRepository(
        runtimeState: const TunnelRuntimeState(
          state: VpnTunnelState.connected,
          detail: 'Local proxy listeners are active.',
          connectionMode: ConnectionMode.proxyOnly,
          attemptId: 'attempt-proxy',
        ),
      );
      return TunnelBloc(_countingTunnelRepository, _FakeLogsRepository());
    },
    act: (bloc) async {
      bloc.add(const TunnelStarted());
      await Future<void>.delayed(Duration.zero);
      bloc.add(TunnelConnectRequested(_connectRequest()));
    },
    expect: () => const [
      TunnelState(
        tunnelUp: true,
        connectionMode: ConnectionMode.proxyOnly,
        activeAttemptId: 'attempt-proxy',
      ),
    ],
    verify: (_) {
      expect(_countingTunnelRepository.connectCalls, 0);
    },
  );

  blocTest<TunnelBloc, TunnelState>(
    'connect request waits for pending runtime bootstrap before guard',
    build: () {
      _deferredTunnelRepository = _DeferredTunnelRepository();
      return TunnelBloc(_deferredTunnelRepository, _FakeLogsRepository());
    },
    act: (bloc) async {
      bloc.add(const TunnelStarted());
      await Future<void>.delayed(Duration.zero);
      bloc.add(TunnelConnectRequested(_connectRequest()));
      await Future<void>.delayed(Duration.zero);
      expect(_deferredTunnelRepository.connectCalls, 0);
      _deferredTunnelRepository.completeRuntimeState(
        const TunnelRuntimeState(
          state: VpnTunnelState.connected,
          detail: 'Local proxy listeners are active.',
          connectionMode: ConnectionMode.proxyOnly,
          attemptId: 'attempt-proxy',
        ),
      );
    },
    expect: () => const [
      TunnelState(
        tunnelUp: true,
        connectionMode: ConnectionMode.proxyOnly,
        activeAttemptId: 'attempt-proxy',
      ),
    ],
    verify: (_) {
      expect(_deferredTunnelRepository.connectCalls, 0);
    },
  );

  blocTest<TunnelBloc, TunnelState>(
    'untagged terminal event is ignored while an attempt is active',
    build: () => TunnelBloc(_FakeTunnelRepository(), _FakeLogsRepository()),
    seed: () => const TunnelState(
      tunnelUp: true,
      stopRequested: true,
      connectionMode: ConnectionMode.proxyOnly,
      activeAttemptId: 'attempt-current',
    ),
    act: (bloc) {
      bloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.stopped,
            detail: 'Stopped by app',
            attemptId: '',
          ),
        ),
      );
    },
    expect: () => const <TunnelState>[],
  );

  blocTest<TunnelBloc, TunnelState>(
    'await timeout stays non-terminal while Android is still connecting',
    build: () => TunnelBloc(_FakeTunnelRepository(), _FakeLogsRepository()),
    seed: () => const TunnelState(
      awaitingTunnel: true,
      activeAttemptId: 'attempt-current',
      connectionMode: ConnectionMode.proxyOnly,
    ),
    act: (bloc) {
      bloc.add(const TunnelAwaitTimedOut('attempt-current'));
    },
    expect: () => const <TunnelState>[],
    verify: (bloc) {
      expect(bloc.state.awaitingTunnel, isTrue);
      expect(bloc.state.activeAttemptId, 'attempt-current');
      expect(bloc.state.message, isNull);
      expect(bloc.state.timedOutThisAttempt, isFalse);
    },
  );

  blocTest<TunnelBloc, TunnelState>(
    'disconnect timeout clears stop-pending state when runtime is idle',
    build: () => TunnelBloc(
      _MutableRuntimeTunnelRepository(const TunnelRuntimeState.idle()),
      _FakeLogsRepository(),
    ),
    seed: () => const TunnelState(
      tunnelUp: true,
      stopRequested: true,
      activeAttemptId: 'attempt-current',
    ),
    act: (bloc) {
      bloc.add(const TunnelDisconnectTimedOut('attempt-current'));
    },
    expect: () => const [TunnelState()],
  );

  blocTest<TunnelBloc, TunnelState>(
    'disconnect timeout keeps waiting when runtime is still active',
    build: () => TunnelBloc(
      _MutableRuntimeTunnelRepository(
        const TunnelRuntimeState(
          state: VpnTunnelState.connected,
          detail: 'Still active',
          connectionMode: ConnectionMode.proxyOnly,
          attemptId: 'attempt-current',
        ),
      ),
      _FakeLogsRepository(),
    ),
    seed: () => const TunnelState(
      tunnelUp: true,
      stopRequested: true,
      connectionMode: ConnectionMode.proxyOnly,
      activeAttemptId: 'attempt-current',
    ),
    act: (bloc) {
      bloc.add(const TunnelDisconnectTimedOut('attempt-current'));
    },
    expect: () => const <TunnelState>[],
  );

  blocTest<TunnelBloc, TunnelState>(
    'proxy connected event surfaces changed port notice',
    build: () => TunnelBloc(_FakeTunnelRepository(), _FakeLogsRepository()),
    seed: () => const TunnelState(
      awaitingTunnel: true,
      connectionMode: ConnectionMode.proxyOnly,
      activeAttemptId: 'attempt-current',
    ),
    act: (bloc) {
      bloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.connected,
            detail:
                'Proxy ports changed: HTTP 127.0.0.1:8081, SOCKS5 127.0.0.1:1081',
            attemptId: 'attempt-current',
          ),
        ),
      );
    },
    expect: () => const [
      TunnelState(
        tunnelUp: true,
        connectionMode: ConnectionMode.proxyOnly,
        activeAttemptId: 'attempt-current',
      ),
      TunnelState(
        tunnelUp: true,
        connectionMode: ConnectionMode.proxyOnly,
        activeAttemptId: 'attempt-current',
        message: HomeMessage(
          id: 1,
          text:
              'Proxy ports changed: HTTP 127.0.0.1:8081, SOCKS5 127.0.0.1:1081',
        ),
      ),
    ],
  );

  blocTest<TunnelBloc, TunnelState>(
    'vpn connected event does not surface proxy changed port notice',
    build: () => TunnelBloc(_FakeTunnelRepository(), _FakeLogsRepository()),
    seed: () => const TunnelState(
      awaitingTunnel: true,
      connectionMode: ConnectionMode.vpnTunnel,
      activeAttemptId: 'attempt-current',
    ),
    act: (bloc) {
      bloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.connected,
            detail:
                'Proxy ports changed: HTTP 127.0.0.1:8081, SOCKS5 127.0.0.1:1081',
            attemptId: 'attempt-current',
          ),
        ),
      );
    },
    expect: () => const [
      TunnelState(
        tunnelUp: true,
        connectionMode: ConnectionMode.vpnTunnel,
        activeAttemptId: 'attempt-current',
      ),
      TunnelState(
        tunnelUp: true,
        connectionMode: ConnectionMode.vpnTunnel,
        activeAttemptId: 'attempt-current',
        message: HomeMessage(id: 1, text: 'VPN connected'),
      ),
    ],
  );

  blocTest<TunnelBloc, TunnelState>(
    'reports failed lastTerminal from idle getRuntimeState on startup',
    build: () {
      const failure = TunnelFailure(namespace: 'mschap', code: '691');
      final logs = _FakeLogsRepository();
      return TunnelBloc(
        _FakeTunnelRepository(
          runtimeState: const TunnelRuntimeState(
            state: VpnTunnelState.stopped,
            detail: 'Idle',
            connectionMode: ConnectionMode.vpnTunnel,
            lastTerminal: TunnelHostUpdate(
              state: VpnTunnelState.failed,
              detail: 'PPP negotiation failed.',
              attemptId: 'attempt-bg',
              failure: failure,
            ),
          ),
        ),
        logs,
      );
    },
    act: (bloc) => bloc.add(const TunnelStarted()),
    expect: () => const [
      TunnelState(
        message: HomeMessage(
          id: 1,
          text: 'PPP negotiation failed.',
          error: true,
          failure: TunnelFailure(namespace: 'mschap', code: '691'),
        ),
      ),
    ],
  );

  blocTest<TunnelBloc, TunnelState>(
    'reports revoked android lastTerminal on startup so return to app shows error',
    build: () {
      const failure = TunnelFailure(namespace: 'android', code: '1');
      final logs = _FakeLogsRepository();
      return TunnelBloc(
        _FakeTunnelRepository(
          runtimeState: const TunnelRuntimeState(
            state: VpnTunnelState.stopped,
            detail: 'Idle',
            connectionMode: ConnectionMode.vpnTunnel,
            lastTerminal: TunnelHostUpdate(
              state: VpnTunnelState.failed,
              detail: 'Disconnected: VPN revoked by Android',
              attemptId: 'attempt-revoked',
              failure: failure,
            ),
          ),
        ),
        logs,
      );
    },
    act: (bloc) => bloc.add(const TunnelStarted()),
    expect: () => const [
      TunnelState(
        message: HomeMessage(
          id: 1,
          text: 'Disconnected: VPN revoked by Android',
          error: true,
          failure: TunnelFailure(namespace: 'android', code: '1'),
        ),
      ),
    ],
  );

  blocTest<TunnelBloc, TunnelState>(
    'reports live android system-kill failure while connected',
    build: () => TunnelBloc(_FakeTunnelRepository(), _FakeLogsRepository()),
    seed: () => const TunnelState(
      tunnelUp: true,
      activeAttemptId: 'attempt-kill',
      connectionMode: ConnectionMode.proxyOnly,
    ),
    act: (bloc) {
      bloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.failed,
            detail: 'Disconnected: stopped by Android system',
            attemptId: 'attempt-kill',
            failure: TunnelFailure(namespace: 'android', code: '2'),
          ),
        ),
      );
    },
    expect: () => const [
      TunnelState(
        tunnelUp: false,
        awaitingTunnel: false,
        recoveryPhase: TunnelRecoveryPhase.none,
        stopRequested: false,
        timedOutThisAttempt: false,
        connectionMode: ConnectionMode.proxyOnly,
        activeAttemptId: null,
      ),
      TunnelState(
        tunnelUp: false,
        awaitingTunnel: false,
        recoveryPhase: TunnelRecoveryPhase.none,
        stopRequested: false,
        timedOutThisAttempt: false,
        connectionMode: ConnectionMode.proxyOnly,
        activeAttemptId: null,
        message: HomeMessage(
          id: 1,
          text: 'Disconnected: stopped by Android system',
          error: true,
          failure: TunnelFailure(namespace: 'android', code: '2'),
        ),
      ),
    ],
  );

  blocTest<TunnelBloc, TunnelState>(
    'logs stopped lastTerminal without error toast on startup',
    build: () {
      final logs = _FakeLogsRepository();
      return TunnelBloc(
        _FakeTunnelRepository(
          runtimeState: const TunnelRuntimeState(
            state: VpnTunnelState.stopped,
            detail: 'Idle',
            connectionMode: ConnectionMode.vpnTunnel,
            lastTerminal: TunnelHostUpdate(
              state: VpnTunnelState.stopped,
              detail: 'Disconnected cleanly.',
              attemptId: 'attempt-bg-stop',
            ),
          ),
        ),
        logs,
      );
    },
    act: (bloc) => bloc.add(const TunnelStarted()),
    expect: () => const <TunnelState>[],
  );

  blocTest<TunnelBloc, TunnelState>(
    'transitions connected through waitingForNetwork and reconnecting back to connected',
    build: () => TunnelBloc(_FakeTunnelRepository(), _FakeLogsRepository()),
    seed: () =>
        const TunnelState(tunnelUp: true, activeAttemptId: 'attempt-recover'),
    act: (bloc) {
      bloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.waitingForNetwork,
            detail: 'Waiting for network (blocking internet)',
            attemptId: 'attempt-recover',
          ),
        ),
      );
      bloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.reconnecting,
            detail: 'Reconnecting...',
            attemptId: 'attempt-recover',
          ),
        ),
      );
      bloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.connected,
            detail: 'TUN ready',
            attemptId: 'attempt-recover',
          ),
        ),
      );
    },
    expect: () => [
      const TunnelState(
        tunnelUp: false,
        awaitingTunnel: true,
        recoveryPhase: TunnelRecoveryPhase.waitingForNetwork,
        activeAttemptId: 'attempt-recover',
      ),
      const TunnelState(
        tunnelUp: false,
        awaitingTunnel: true,
        recoveryPhase: TunnelRecoveryPhase.reconnecting,
        activeAttemptId: 'attempt-recover',
      ),
      const TunnelState(
        tunnelUp: true,
        awaitingTunnel: false,
        recoveryPhase: TunnelRecoveryPhase.none,
        activeAttemptId: 'attempt-recover',
      ),
      const TunnelState(
        tunnelUp: true,
        awaitingTunnel: false,
        recoveryPhase: TunnelRecoveryPhase.none,
        activeAttemptId: 'attempt-recover',
        message: HomeMessage(id: 1, text: 'VPN connected'),
      ),
    ],
  );

  blocTest<TunnelBloc, TunnelState>(
    'syncs waitingForNetwork and clears stale active state when runtime reports stopped',
    build: () {
      _mutableRuntimeRepository = _MutableRuntimeTunnelRepository(
        const TunnelRuntimeState(
          state: VpnTunnelState.waitingForNetwork,
          detail: 'Waiting for network (blocking internet)',
          attemptId: 'attempt-bg-wait',
          connectionMode: ConnectionMode.vpnTunnel,
        ),
      );
      return TunnelBloc(_mutableRuntimeRepository, _FakeLogsRepository());
    },
    act: (bloc) async {
      bloc.add(const TunnelRuntimeSyncRequested());
      await Future<void>.delayed(Duration.zero);
      _mutableRuntimeRepository.currentRuntimeState =
          const TunnelRuntimeState.idle();
      bloc.add(const TunnelRuntimeSyncRequested());
    },
    expect: () => [
      const TunnelState(
        tunnelUp: false,
        awaitingTunnel: true,
        recoveryPhase: TunnelRecoveryPhase.waitingForNetwork,
        activeAttemptId: 'attempt-bg-wait',
        connectionMode: ConnectionMode.vpnTunnel,
      ),
      const TunnelState(
        tunnelUp: false,
        awaitingTunnel: false,
        recoveryPhase: TunnelRecoveryPhase.none,
        activeAttemptId: null,
        connectionMode: ConnectionMode.vpnTunnel,
      ),
    ],
  );

  blocTest<TunnelBloc, TunnelState>(
    'emits failure popup message when connected tunnel is closed by server',
    build: () => TunnelBloc(_FakeTunnelRepository(), _FakeLogsRepository()),
    seed: () => const TunnelState(
      tunnelUp: true,
      connectionMode: ConnectionMode.vpnTunnel,
      activeAttemptId: 'attempt-server-close',
    ),
    act: (bloc) {
      bloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.failed,
            detail: 'VPN server closed the connection.',
            attemptId: 'attempt-server-close',
            failure: TunnelFailure(
              namespace: 'l2tp-cdn',
              code: '1',
              detail: 'VPN server closed the connection.',
            ),
          ),
        ),
      );
    },
    expect: () => const [
      TunnelState(
        tunnelUp: false,
        awaitingTunnel: false,
        recoveryPhase: TunnelRecoveryPhase.none,
        connectionMode: ConnectionMode.vpnTunnel,
        activeAttemptId: null,
      ),
      TunnelState(
        tunnelUp: false,
        awaitingTunnel: false,
        recoveryPhase: TunnelRecoveryPhase.none,
        connectionMode: ConnectionMode.vpnTunnel,
        activeAttemptId: null,
        message: HomeMessage(
          id: 1,
          text: 'VPN server closed the connection.',
          error: true,
          failure: TunnelFailure(
            namespace: 'l2tp-cdn',
            code: '1',
            detail: 'VPN server closed the connection.',
          ),
        ),
      ),
    ],
  );

  test(
    'TunnelReconnectRequested replaces an active tunnel with a new attemptId',
    () async {
      final repo = _CountingTunnelRepository();
      final bloc = TunnelBloc(repo, _FakeLogsRepository());
      addTearDown(bloc.close);

      bloc.add(TunnelConnectRequested(_connectRequest()));
      await Future<void>.delayed(Duration.zero);
      final firstAttempt = bloc.state.activeAttemptId;
      expect(firstAttempt, isNotNull);

      bloc.add(
        TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.connected,
            detail: 'Connected',
            attemptId: firstAttempt!,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.tunnelUp, isTrue);

      bloc.add(
        TunnelReconnectRequested(
          const TunnelConnectRequest(
            activeProfileId: 'p2',
            profileName: 'Second',
            server: 'vpn2.example',
            user: 'u2',
            password: 'pw2',
            psk: 'psk2',
            dnsAutomatic: true,
            dnsServers: [],
            mtu: Profile.defaultVpnMtu,
            connectionMode: ConnectionMode.vpnTunnel,
            splitTunnelSettings: SplitTunnelSettings(),
            proxySettings: ProxySettings(),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(repo.connectCalls, 2);
      expect(bloc.state.tunnelUp, isFalse);
      expect(bloc.state.awaitingTunnel, isTrue);
      expect(bloc.state.activeAttemptId, isNotNull);
      expect(bloc.state.activeAttemptId, isNot(equals(firstAttempt)));

      // Late stopped from old attempt must be ignored.
      bloc.add(
        TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.stopped,
            detail: 'Restarted by app',
            attemptId: firstAttempt,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.awaitingTunnel, isTrue);
    },
  );

  test('Quick Settings attempt while idle triggers runtime sync', () async {
    final repo = _MutableRuntimeTunnelRepository(
      const TunnelRuntimeState.idle(),
    );
    final bloc = TunnelBloc(repo, _FakeLogsRepository());
    addTearDown(bloc.close);

    bloc.add(const TunnelStarted());
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.tunnelUp, isFalse);

    repo.currentRuntimeState = const TunnelRuntimeState(
      state: VpnTunnelState.connected,
      detail: 'Connected',
      connectionMode: ConnectionMode.vpnTunnel,
      attemptId: 'qs-123',
    );
    bloc.add(
      const TunnelHostStateReceived(
        TunnelHostUpdate(
          state: VpnTunnelState.connected,
          detail: 'Connected',
          attemptId: 'qs-123',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.tunnelUp, isTrue);
    expect(bloc.state.activeAttemptId, 'qs-123');
  });

  test(
    'runtime sync while prepareVpn is pending preserves activeAttemptId and connected transition',
    () async {
      final prepCompleter = Completer<bool>();
      final repo = _RaceTunnelRepository(prepareFuture: prepCompleter.future);
      final bloc = TunnelBloc(repo, _FakeLogsRepository());
      addTearDown(bloc.close);

      bloc.add(const TunnelStarted());
      await Future<void>.delayed(Duration.zero);

      bloc.add(TunnelConnectRequested(_connectRequest()));
      await Future<void>.delayed(Duration.zero);
      final attemptId = bloc.state.activeAttemptId;
      expect(attemptId, isNotNull);
      expect(bloc.state.busy, isTrue);

      // Simulate Activity resume from Android VPN consent dialog while prepareVpn is pending.
      bloc.add(const TunnelRuntimeSyncRequested());
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.activeAttemptId, attemptId);

      prepCompleter.complete(true);
      await Future<void>.delayed(Duration.zero);

      repo.emitState(
        TunnelHostUpdate(
          state: VpnTunnelState.connected,
          detail: 'Connected',
          attemptId: attemptId!,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.tunnelUp, isTrue);
    },
  );

  test(
    'fast native connected event during connect() is not overwritten when connect returns',
    () async {
      final connectCompleter = Completer<void>();
      final repo = _RaceTunnelRepository(
        connectFuture: connectCompleter.future,
      );
      final bloc = TunnelBloc(repo, _FakeLogsRepository());
      addTearDown(bloc.close);

      bloc.add(const TunnelStarted());
      await Future<void>.delayed(Duration.zero);

      bloc.add(TunnelConnectRequested(_connectRequest()));
      await Future<void>.delayed(Duration.zero);
      final attemptId = repo.lastAttemptId;
      expect(attemptId, isNotNull);

      repo.emitState(
        TunnelHostUpdate(
          state: VpnTunnelState.connected,
          detail: 'Connected fast',
          attemptId: attemptId!,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.tunnelUp, isTrue);

      connectCompleter.complete();
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.tunnelUp, isTrue);
      expect(bloc.state.awaitingTunnel, isFalse);
      expect(bloc.state.busy, isFalse);
    },
  );

  blocTest<TunnelBloc, TunnelState>(
    'inclusive split tunneling with no apps emits error toast without TunnelFailure',
    build: () => TunnelBloc(_FakeTunnelRepository(), _FakeLogsRepository()),
    act: (bloc) {
      bloc.add(
        const TunnelConnectRequested(
          TunnelConnectRequest(
            activeProfileId: null,
            profileName: null,
            server: 'vpn.example',
            user: '',
            password: '',
            psk: '',
            dnsAutomatic: true,
            dnsServers: [],
            mtu: Profile.defaultVpnMtu,
            connectionMode: ConnectionMode.vpnTunnel,
            splitTunnelSettings: SplitTunnelSettings(
              enabled: true,
              mode: SplitTunnelMode.inclusive,
            ),
            proxySettings: ProxySettings(),
          ),
        ),
      );
    },
    expect: () => [
      TunnelState(
        message: HomeMessage(
          id: 1,
          text: AppL10n.current.selectAppsForInclusiveSplitTunnel,
          error: true,
        ),
      ),
    ],
  );
}

class _RaceTunnelRepository extends _FakeTunnelRepository {
  _RaceTunnelRepository({this.prepareFuture, this.connectFuture});

  final Future<bool>? prepareFuture;
  final Future<void>? connectFuture;
  final StreamController<TunnelHostUpdate> _states =
      StreamController<TunnelHostUpdate>.broadcast();
  String? lastAttemptId;

  @override
  Stream<TunnelHostUpdate> get tunnelStates => _states.stream;

  void emitState(TunnelHostUpdate update) => _states.add(update);

  @override
  Future<bool> prepareVpn() => prepareFuture ?? Future.value(true);

  @override
  Future<void> connect(TunnelConnectRequest request) {
    lastAttemptId = request.attemptId;
    return connectFuture ?? Future.value();
  }

  @override
  void dispose() {
    _states.close();
  }
}

late _MutableRuntimeTunnelRepository _mutableRuntimeRepository;
late _CountingTunnelRepository _countingTunnelRepository;
late _DeferredTunnelRepository _deferredTunnelRepository;

TunnelConnectRequest _connectRequest() {
  return const TunnelConnectRequest(
    activeProfileId: null,
    profileName: null,
    server: 'vpn.example',
    user: '',
    password: '',
    psk: '',
    dnsAutomatic: true,
    dnsServers: [],
    mtu: Profile.defaultVpnMtu,
    connectionMode: ConnectionMode.vpnTunnel,
    splitTunnelSettings: SplitTunnelSettings(),
    proxySettings: ProxySettings(),
  );
}

class _FakeTunnelRepository implements TunnelRepository {
  _FakeTunnelRepository({this.runtimeState = const TunnelRuntimeState.idle()});

  final TunnelRuntimeState runtimeState;

  @override
  Stream<EngineLogMessage> get engineLogs => const Stream.empty();

  @override
  Stream<ProxyExposure> get proxyExposures => const Stream.empty();

  @override
  Stream<BatteryOptimizationStatus> get batteryOptimizationStatuses =>
      const Stream.empty();

  @override
  Stream<void> get quickSettingsConnectRequests => const Stream.empty();

  @override
  Stream<TunnelHostUpdate> get tunnelStates => const Stream.empty();

  @override
  Future<bool> prepareVpn() async => true;

  @override
  Future<TunnelRuntimeState> getRuntimeState() async => runtimeState;

  @override
  Future<void> syncQuickSettingsProfile(
    QuickSettingsProfileConfig? config,
  ) async {}

  @override
  Future<bool> consumePendingQuickSettingsConnect() async => false;

  @override
  Future<BatteryOptimizationStatus> getBatteryOptimizationStatus() async {
    return const BatteryOptimizationStatus.unknown();
  }

  @override
  Future<void> connect(TunnelConnectRequest request) async {}

  @override
  Future<void> disconnect({
    required ConnectionMode connectionMode,
    String attemptId = '',
  }) async {}

  @override
  Future<Uint8List?> getAppIcon(String packageName) async => null;

  @override
  Future<List<CandidateApp>> listVpnCandidateApps() async => const [];

  @override
  Future<bool?> checkProxyPortAvailable(
    int port, {
    required bool allowLanConnections,
  }) async => true;

  @override
  Future<BatteryOptimizationRequestResult> openBatteryOptimizationSettings() {
    return Future.value(
      const BatteryOptimizationRequestResult(
        outcome: BatteryOptimizationRequestOutcome.settingsOpened,
      ),
    );
  }

  @override
  Future<BatteryOptimizationRequestResult>
  openManufacturerBackgroundSettings() {
    return Future.value(
      const BatteryOptimizationRequestResult(
        outcome: BatteryOptimizationRequestOutcome.settingsOpened,
      ),
    );
  }

  @override
  Future<BatteryOptimizationRequestResult> requestIgnoreBatteryOptimizations() {
    return Future.value(
      const BatteryOptimizationRequestResult(
        outcome: BatteryOptimizationRequestOutcome.requested,
      ),
    );
  }

  @override
  Future<void> setLogLevel(LogDisplayLevel level) async {}

  @override
  void dispose() {}
}

class _CountingTunnelRepository extends _FakeTunnelRepository {
  _CountingTunnelRepository({super.runtimeState});

  int connectCalls = 0;

  @override
  Future<void> connect(TunnelConnectRequest request) async {
    connectCalls += 1;
  }
}

class _MutableRuntimeTunnelRepository extends _FakeTunnelRepository {
  _MutableRuntimeTunnelRepository(this.currentRuntimeState);

  TunnelRuntimeState currentRuntimeState;

  @override
  Future<TunnelRuntimeState> getRuntimeState() async => currentRuntimeState;
}

class _DeferredTunnelRepository extends _CountingTunnelRepository {
  final Completer<TunnelRuntimeState> _runtimeState =
      Completer<TunnelRuntimeState>();

  @override
  Future<TunnelRuntimeState> getRuntimeState() => _runtimeState.future;

  void completeRuntimeState(TunnelRuntimeState state) {
    _runtimeState.complete(state);
  }
}

class _FakeLogsRepository implements LogsRepository {
  @override
  final List<LogEntry> entries = <LogEntry>[];

  @override
  Stream<List<LogEntry>> get entriesStream => const Stream.empty();

  @override
  Future<void> loadPersisted() async {}

  @override
  void append(LogEntry entry) {
    entries.add(entry);
  }

  @override
  void clear() {
    entries.clear();
  }
}
