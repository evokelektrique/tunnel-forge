import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart'
    show
        GestureDisposition,
        GestureMultiDragStartCallback,
        MultiDragGestureRecognizer,
        MultiDragPointerState,
        computeHitSlop,
        kTouchSlop;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:tunnel_forge/app/ui/app_scaffold_messenger.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/home/data/home_repositories_impl.dart';
import 'package:tunnel_forge/features/home/domain/home_models.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import 'package:tunnel_forge/features/home/domain/log_redaction.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/profiles_bloc.dart';
import 'package:tunnel_forge/features/profile_form/presentation/bloc/profile_form_bloc.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';
import 'package:tunnel_forge/features/profiles/presentation/profile_editor_sheet.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_contract.dart';

/// Bottom sheet listing saved profiles with select, edit, delete, and import actions.
class ProfilePickerSheet extends StatefulWidget {
  static const AnimationStyle _kSheetAnimationStyle = AnimationStyle(
    duration: Duration(milliseconds: 360),
    reverseDuration: Duration(milliseconds: 260),
  );

  const ProfilePickerSheet({
    super.key,
    required this.profilesBloc,
    required this.store,
    this.logsRepository,
  });

  final ProfilesBloc profilesBloc;
  final ProfileStore store;
  final LogsRepository? logsRepository;

  static Future<String?> show(
    BuildContext context, {
    required ProfilesBloc profilesBloc,
    required ProfileStore store,
    LogsRepository? logsRepository,
  }) {
    final theme = Theme.of(context);
    final sheetColor =
        theme.bottomSheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      useSafeArea: true,
      sheetAnimationStyle: _kSheetAnimationStyle,
      backgroundColor: sheetColor,
      builder: (sheetContext) => BlocProvider.value(
        value: profilesBloc,
        child: ProfilePickerSheet(
          profilesBloc: profilesBloc,
          store: store,
          logsRepository: logsRepository,
        ),
      ),
    );
  }

  @override
  State<ProfilePickerSheet> createState() => _ProfilePickerSheetState();
}

class _ProfilePickerSheetState extends State<ProfilePickerSheet> {
  static const Color _kFavoriteStarLight = Color(0xFFD48806);
  static const Color _kFavoriteStarDark = Color(0xFFF5C249);
  static const BoxConstraints _kCompactButtonConstraints = BoxConstraints(
    minWidth: 40,
    minHeight: 40,
  );
  static const EdgeInsets _kCompactButtonPadding = EdgeInsets.all(8);

  _ProfileSheetMode _mode = _ProfileSheetMode.list;
  String? _editingProfileId;
  int _editorSession = 0;
  bool _multiSelectMode = false;
  final Set<String> _selectedProfileIds = <String>{};

  ProfilesBloc get _profilesBloc => widget.profilesBloc;

  bool _isMultiSelect(ProfilesState state) =>
      _multiSelectMode && state.profiles.isNotEmpty;

  Set<String> _activeSelection(List<Profile> profiles) {
    if (_selectedProfileIds.isEmpty) return const <String>{};
    final existingIds = profiles.map((p) => p.id).toSet();
    return _selectedProfileIds.intersection(existingIds);
  }

  List<String> _orderedSelectedIds(List<Profile> profiles) {
    final selected = _activeSelection(profiles);
    return profiles
        .where((p) => selected.contains(p.id))
        .map((p) => p.id)
        .toList();
  }

  void _exitMultiSelect() {
    if (!_multiSelectMode && _selectedProfileIds.isEmpty) return;
    setState(() {
      _multiSelectMode = false;
      _selectedProfileIds.clear();
    });
  }

  void _enterMultiSelect(String id) {
    setState(() {
      _multiSelectMode = true;
      _selectedProfileIds.add(id);
    });
  }

  void _toggleSelection(String id, List<Profile> profiles) {
    setState(() {
      final validIds = profiles.map((p) => p.id).toSet();
      _selectedProfileIds.retainAll(validIds);
      if (!_selectedProfileIds.remove(id)) {
        _selectedProfileIds.add(id);
      }
      if (_selectedProfileIds.isEmpty) {
        _multiSelectMode = false;
      }
    });
  }

  void _toggleSelectAll(List<Profile> profiles, bool allSelected) {
    setState(() {
      _selectedProfileIds.clear();
      if (!allSelected) {
        _selectedProfileIds.addAll(profiles.map((p) => p.id));
      }
    });
  }

  void _openEditor({String? profileId}) {
    setState(() {
      _mode = _ProfileSheetMode.editor;
      _editingProfileId = profileId;
      _editorSession += 1;
    });
  }

  void _closeEditor() {
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _mode = _ProfileSheetMode.list;
      _editingProfileId = null;
    });
  }

  Future<void> _selectProfile(String id) async {
    Navigator.of(context).pop(id);
    _profilesBloc.add(ProfilesSelectionChanged(id));
  }

  Future<void> _refreshProfiles({required String preferredActiveId}) async {
    final refreshResult = _profilesBloc.stream
        .firstWhere((state) {
          return !state.loading &&
              state.activeProfileId == preferredActiveId &&
              state.profiles.any((profile) => profile.id == preferredActiveId);
        })
        .timeout(const Duration(seconds: 5));
    _profilesBloc.add(
      ProfilesRefreshRequested(preferredActiveId: preferredActiveId),
    );
    try {
      await refreshResult;
    } on TimeoutException {
      if (!mounted) return;
      showAppSnackBar(
        context,
        AppL10n.of(context).profileRefreshTimedOut,
        error: true,
      );
    }
  }

  Future<void> _importTransfer(IncomingProfileTransfer transfer) async {
    final initialMessageId = _profilesBloc.state.message?.id ?? 0;
    final importResult = _profilesBloc.stream
        .firstWhere((state) {
          return !state.loading &&
              state.message != null &&
              state.message!.id > initialMessageId;
        })
        .timeout(const Duration(seconds: 5));
    _profilesBloc.add(
      ProfilesImportRequested(
        ImportTransferRequest(
          transfer: transfer,
          selectAsLastProfile:
              _profilesBloc.state.selectImportedProfileWhenIdle,
        ),
      ),
    );
    try {
      await importResult;
      if (mounted) setState(() {});
    } on TimeoutException {
      if (!mounted) return;
      showAppSnackBar(
        context,
        AppL10n.of(context).profileImportTimedOut,
        error: true,
      );
    }
  }

  Future<void> _importTransferBatch(
    List<IncomingProfileTransfer> transfers,
  ) async {
    final initialMessageId = _profilesBloc.state.message?.id ?? 0;
    final importResult = _profilesBloc.stream
        .firstWhere((state) {
          return !state.loading &&
              state.message != null &&
              state.message!.id > initialMessageId;
        })
        .timeout(const Duration(seconds: 5));
    _profilesBloc.add(
      ProfilesImportBatchRequested(
        transfers,
        selectAsLastProfile: _profilesBloc.state.selectImportedProfileWhenIdle,
      ),
    );
    try {
      await importResult;
      if (mounted) setState(() {});
    } on TimeoutException {
      if (!mounted) return;
      showAppSnackBar(
        context,
        AppL10n.of(context).profileImportTimedOut,
        error: true,
      );
    }
  }

  Future<void> _importFromFile() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,

        allowedExtensions: const [ProfileTransferEnvelope.fileExtension],
      );
      if (!mounted) return;
      if (file == null) return;

      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (bytes.isEmpty) {
        widget.logsRepository?.logDart(
          LogLevel.warning,
          'profiles',
          'Profile import failed origin=file file=${quoteLogValue(file.name)} reason=empty_file',
        );
        showAppSnackBar(
          context,
          AppL10n.of(context).couldNotReadSelectedFile,
          error: true,
        );
        return;
      }
      final contents = utf8.decode(bytes);
      await _importTransfer(
        IncomingProfileTransfer(
          type: ProfileTransferContract.typeTfpJson,
          data: contents,
          source: file.name,
        ),
      );
    } catch (error) {
      widget.logsRepository?.logDart(
        LogLevel.warning,
        'profiles',
        'Profile import failed origin=file reason=${error.runtimeType}',
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        AppL10n.of(context).couldNotImportTfp,
        error: true,
      );
    }
  }

  Future<void> _importFromClipboard() async {
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        widget.logsRepository?.logDart(
          LogLevel.debug,
          'profiles',
          'Profile clipboard import skipped: clipboard empty',
        );
        if (!mounted) return;
        showAppSnackBar(
          context,
          AppL10n.of(context).clipboardEmpty,
          error: true,
        );
        return;
      }
      final uriPrefix = '${ProfileTransferEnvelope.uriScheme}://';
      final lines = text
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      if (lines.length > 1 && lines.first.toLowerCase().startsWith(uriPrefix)) {
        await _importTransferBatch([
          for (final line in lines)
            IncomingProfileTransfer(
              type: ProfileTransferContract.typeTfUri,
              data: line,
              source: 'Clipboard',
            ),
        ]);
        return;
      }
      final IncomingProfileTransfer transfer;
      if (text.toLowerCase().startsWith(uriPrefix)) {
        transfer = IncomingProfileTransfer(
          type: ProfileTransferContract.typeTfUri,
          data: text,
          source: 'Clipboard',
        );
      } else {
        final envelopes = ProfileTransferEnvelope.fromFileJsonList(text);
        transfer = IncomingProfileTransfer(
          type: ProfileTransferContract.typeTfpJson,
          data: envelopes.length == 1
              ? envelopes.single.toFileJson()
              : ProfileTransferEnvelope.toBundleFileJson(envelopes),
          source: 'Clipboard',
        );
      }
      await _importTransfer(transfer);
    } on FormatException catch (error) {
      widget.logsRepository?.logDart(
        LogLevel.warning,
        'profiles',
        'Profile import failed origin=clipboard reason=${error.runtimeType}',
      );
      if (!mounted) return;
      final t = AppL10n.of(context);
      final userMessage = error is ProfileTransferFormatException
          ? error.localizedMessage(t)
          : t.clipboardInvalidProfile;
      showAppSnackBar(context, userMessage, error: true);
    } catch (error) {
      widget.logsRepository?.logDart(
        LogLevel.warning,
        'profiles',
        'Profile import failed origin=clipboard reason=${error.runtimeType}',
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        AppL10n.of(context).couldNotImportClipboard,
        error: true,
      );
    }
  }

  Future<bool> _confirmDeleteProfiles(List<String> ids) async {
    final uniqueIds = ids.where((id) => id.isNotEmpty).toSet().toList();
    if (uniqueIds.isEmpty) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final t = AppL10n.of(ctx);
        return AlertDialog(
          title: Text(t.deleteProfilesQuestion(uniqueIds.length)),
          content: Text(t.deleteProfilesBody(uniqueIds.length)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.delete),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return false;
    final initialMessageId = _profilesBloc.state.message?.id ?? 0;
    final deleteResult = _profilesBloc.stream
        .firstWhere((state) {
          final remaining = state.profiles.map((p) => p.id).toSet();
          final deletedAll =
              !state.loading &&
              uniqueIds.every((id) => !remaining.contains(id));
          final failed =
              !state.loading &&
              uniqueIds.any(remaining.contains) &&
              state.message != null &&
              state.message!.error &&
              state.message!.id > initialMessageId;
          return deletedAll || failed;
        })
        .timeout(const Duration(seconds: 5));
    _profilesBloc.add(
      uniqueIds.length == 1
          ? ProfilesDeleteRequested(uniqueIds.single)
          : ProfilesDeleteMultipleRequested(uniqueIds),
    );
    try {
      final state = await deleteResult;
      final remaining = state.profiles.map((p) => p.id).toSet();
      final deletedAll = uniqueIds.every((id) => !remaining.contains(id));
      if (mounted) {
        setState(() {
          _selectedProfileIds.removeAll(uniqueIds);
          if (deletedAll || remaining.isEmpty) {
            _multiSelectMode = false;
          }
        });
      }
      return deletedAll;
    } on TimeoutException {
      return false;
    }
  }

  void _copySelectedLinks(List<Profile> profiles) {
    final ids = _orderedSelectedIds(profiles);
    if (ids.isEmpty) return;
    _profilesBloc.add(
      ids.length == 1
          ? ProfilesCopyShareLinkRequested(ids.single)
          : ProfilesCopyShareLinksRequested(ids),
    );
  }

  Future<void> _exportSelectedFiles(List<Profile> profiles) async {
    final ids = _orderedSelectedIds(profiles);
    if (ids.isEmpty) return;
    if (ids.length == 1) {
      _profilesBloc.add(ProfilesExportFileRequested(ids.single));
      return;
    }
    final combinedFileName = ProfileTransferEnvelope.combinedExportFileNameFor(
      ids.length,
    );
    final combined = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final t = AppL10n.of(ctx);
        return AlertDialog(
          title: Text(t.exportTfp),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.chooseExportFormat),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text(t.combinedTfpFile(combinedFileName)),
                onTap: () => Navigator.pop(ctx, true),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.file_copy_outlined),
                title: Text(t.separateTfpFiles(ids.length)),
                onTap: () => Navigator.pop(ctx, false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.cancel),
            ),
          ],
        );
      },
    );
    if (combined == null || !mounted) return;
    _profilesBloc.add(ProfilesExportFilesRequested(ids, combined: combined));
  }

  Widget _buildHeader(
    BuildContext context,
    ProfilesState state,
    Set<String> selectedIds,
  ) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;
    final t = AppL10n.of(context);
    final isMultiSelect = _isMultiSelect(state);
    final hasSelection = selectedIds.isNotEmpty;
    final allSelected =
        state.profiles.isNotEmpty &&
        selectedIds.length == state.profiles.length;
    const compactConstraints = _kCompactButtonConstraints;
    const compactPadding = _kCompactButtonPadding;

    final addButton = PopupMenuButton<_AddProfileAction>(
      tooltip: t.addProfile,
      icon: const Icon(Icons.add),
      onSelected: (action) async {
        _exitMultiSelect();
        switch (action) {
          case _AddProfileAction.create:
            _openEditor();
            break;
          case _AddProfileAction.importFile:
            await _importFromFile();
            break;
          case _AddProfileAction.importClipboard:
            await _importFromClipboard();
            break;
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<_AddProfileAction>(
          value: _AddProfileAction.create,
          child: _PopupMenuIconLabel(
            icon: Icons.add_circle_outline,
            label: t.createNewProfile,
          ),
        ),
        PopupMenuItem<_AddProfileAction>(
          value: _AddProfileAction.importFile,
          child: _PopupMenuIconLabel(
            icon: Icons.file_upload_outlined,
            label: t.importFromFile,
          ),
        ),
        PopupMenuItem<_AddProfileAction>(
          value: _AddProfileAction.importClipboard,
          child: _PopupMenuIconLabel(
            icon: Icons.content_paste_outlined,
            label: t.importFromClipboard,
          ),
        ),
      ],
    );

    if (!isMultiSelect) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
        child: Row(
          children: [
            Expanded(child: Text(t.profiles, style: tt.titleLarge)),
            addButton,
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 8, 8),
      child: Row(
        children: [
          IconButton(
            key: const Key('multi_select_close'),
            tooltip: t.cancel,
            constraints: compactConstraints,
            padding: compactPadding,
            icon: const Icon(Icons.close),
            onPressed: _exitMultiSelect,
          ),
          Expanded(
            child: Text(
              t.selectedCount(selectedIds.length),
              style: tt.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            key: const Key('multi_select_toggle_all'),
            tooltip: allSelected ? t.clearAll : t.selectAll,
            constraints: compactConstraints,
            padding: compactPadding,
            icon: Icon(
              allSelected ? Icons.deselect_outlined : Icons.select_all_outlined,
            ),
            onPressed: state.loading
                ? null
                : () => _toggleSelectAll(state.profiles, allSelected),
          ),
          IconButton(
            key: const Key('multi_select_copy'),
            tooltip: t.copyShareLinks,
            constraints: compactConstraints,
            padding: compactPadding,
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: state.loading || !hasSelection
                ? null
                : () => _copySelectedLinks(state.profiles),
          ),
          IconButton(
            key: const Key('multi_select_export'),
            tooltip: t.exportTfp,
            constraints: compactConstraints,
            padding: compactPadding,
            icon: const Icon(Icons.file_download_outlined),
            onPressed: state.loading || !hasSelection
                ? null
                : () => _exportSelectedFiles(state.profiles),
          ),
          IconButton(
            key: const Key('multi_select_delete'),
            tooltip: t.delete,
            constraints: compactConstraints,
            padding: compactPadding,
            icon: Icon(
              Icons.delete_outline,
              color: state.loading || !hasSelection ? null : cs.error,
            ),
            onPressed: state.loading || !hasSelection
                ? null
                : () => _confirmDeleteProfiles(
                    _orderedSelectedIds(state.profiles),
                  ),
          ),
          addButton,
        ],
      ),
    );
  }

  Widget _reorderProxyDecorator(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    final theme = Theme.of(context);
    final sheetColor =
        theme.bottomSheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final elev = 4.0 * Curves.easeInOut.transform(animation.value);
        return Material(elevation: elev, color: sheetColor, child: child);
      },
      child: child,
    );
  }

  Widget _buildReorderableSection(
    BuildContext context, {
    required ProfilesState state,
    required List<Profile> section,
    required bool favoritesSection,
    required Set<String> selectedIds,
    required bool isMultiSelect,
    required bool atFavoriteLimit,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = AppL10n.of(context);
    final canReorder = section.length > 1;

    return SliverReorderableList(
      itemCount: section.length,
      proxyDecorator: _reorderProxyDecorator,
      onReorderStart: (_) => unawaited(HapticFeedback.mediumImpact()),
      onReorderItem: (oldIndex, newIndex) => _profilesBloc.add(
        ProfilesGroupReordered(
          favoritesSection: favoritesSection,
          oldIndex: oldIndex,
          newIndex: newIndex,
        ),
      ),
      itemBuilder: (context, i) {
        final profile = section[i];
        final isActive = profile.id == state.activeProfileId;
        final isChecked = selectedIds.contains(profile.id);
        final starColor = profile.favorite
            ? (theme.brightness == Brightness.light
                  ? _kFavoriteStarLight
                  : _kFavoriteStarDark)
            : (atFavoriteLimit
                  ? cs.onSurface.withValues(alpha: 0.38)
                  : cs.onSurfaceVariant);

        return ReorderableDelayedDragStartListener(
          key: ValueKey<String>(profile.id),
          index: i,
          enabled: isMultiSelect && canReorder && !state.loading,
          child: _HoldToSelectTile(
            index: i,
            canReorder: canReorder,
            enabled: !state.loading,
            multiSelect: isMultiSelect,
            checked: isChecked,
            active: isActive,
            title: profile.displayName,
            subtitle: profile.server,
            protocol: profile.protocol,
            onHoldTriggered: () => _enterMultiSelect(profile.id),
            onTap: () {
              if (isMultiSelect) {
                _toggleSelection(profile.id, state.profiles);
              } else {
                _selectProfile(profile.id);
              }
            },
            trailing: isMultiSelect
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: ValueKey<String>('favorite_button_${profile.id}'),
                        tooltip: profile.favorite
                            ? t.removeFromFavorites
                            : t.addToFavorites,
                        constraints: _kCompactButtonConstraints,
                        padding: _kCompactButtonPadding,
                        icon: Icon(
                          profile.favorite
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          color: starColor,
                        ),
                        onPressed: state.loading
                            ? null
                            : () => _profilesBloc.add(
                                ProfilesFavoriteToggled(profile.id),
                              ),
                      ),
                      PopupMenuButton<_ProfileTileAction>(
                        tooltip: t.profileActions,
                        enabled: !state.loading,
                        onSelected: (action) async {
                          switch (action) {
                            case _ProfileTileAction.edit:
                              _openEditor(profileId: profile.id);
                              break;
                            case _ProfileTileAction.copyShareLink:
                              _profilesBloc.add(
                                ProfilesCopyShareLinkRequested(profile.id),
                              );
                              break;
                            case _ProfileTileAction.exportFile:
                              _profilesBloc.add(
                                ProfilesExportFileRequested(profile.id),
                              );
                              break;
                            case _ProfileTileAction.delete:
                              await _confirmDeleteProfiles([profile.id]);
                              break;
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem<_ProfileTileAction>(
                            value: _ProfileTileAction.edit,
                            child: _PopupMenuIconLabel(
                              icon: Icons.edit_outlined,
                              label: t.editProfile,
                            ),
                          ),
                          PopupMenuItem<_ProfileTileAction>(
                            value: _ProfileTileAction.copyShareLink,
                            child: _PopupMenuIconLabel(
                              icon: Icons.link_outlined,
                              label: t.copyShareLink,
                            ),
                          ),
                          PopupMenuItem<_ProfileTileAction>(
                            value: _ProfileTileAction.exportFile,
                            child: _PopupMenuIconLabel(
                              icon: Icons.file_download_outlined,
                              label: t.exportTfp,
                            ),
                          ),
                          PopupMenuItem<_ProfileTileAction>(
                            value: _ProfileTileAction.delete,
                            child: _PopupMenuIconLabel(
                              icon: Icons.delete_outline,
                              label: t.deleteProfile,
                              color: cs.error,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _buildList(BuildContext context, ProfilesState state) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;
    final t = AppL10n.of(context);
    final selectedIds = _activeSelection(state.profiles);
    final isMultiSelect = _isMultiSelect(state);
    final favorites = state.profiles.where((p) => p.favorite).toList();
    final others = state.profiles.where((p) => !p.favorite).toList();
    final atFavoriteLimit = favorites.length >= Profile.maxFavorites;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context, state, selectedIds),
        if (state.loading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: LinearProgressIndicator(),
          ),
        Expanded(
          child: state.profiles.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                  child: Text(
                    t.noProfilesYet,
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                )
              : CustomScrollView(
                  slivers: [
                    if (favorites.isNotEmpty)
                      _buildReorderableSection(
                        context,
                        state: state,
                        section: favorites,
                        favoritesSection: true,
                        selectedIds: selectedIds,
                        isMultiSelect: isMultiSelect,
                        atFavoriteLimit: atFavoriteLimit,
                      ),
                    if (favorites.isNotEmpty && others.isNotEmpty)
                      const SliverToBoxAdapter(
                        child: Divider(
                          key: Key('favorites_divider'),
                          height: 1,
                          indent: 16,
                          endIndent: 16,
                        ),
                      ),
                    if (others.isNotEmpty)
                      _buildReorderableSection(
                        context,
                        state: state,
                        section: others,
                        favoritesSection: false,
                        selectedIds: selectedIds,
                        isMultiSelect: isMultiSelect,
                        atFavoriteLimit: atFavoriteLimit,
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildEditor(BuildContext context) {
    final repository = ProfilesRepositoryImpl(widget.store);
    return BlocProvider(
      key: ValueKey<String>(
        'editor:${_editingProfileId ?? 'draft'}:$_editorSession',
      ),
      create: (_) =>
          ProfileFormBloc(repository, logsRepository: widget.logsRepository)
            ..add(ProfileFormStarted(_editingProfileId)),
      child: ProfileEditorView(
        onClose: _closeEditor,
        onSaved: (profileId) async {
          await _refreshProfiles(preferredActiveId: profileId);
          if (!mounted) return;
          _closeEditor();
          if (!mounted) return;
          showAppSnackBar(this.context, AppL10n.of(this.context).profileSaved);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sheetColor =
        theme.bottomSheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;
    final listHeight = MediaQuery.sizeOf(context).height * 0.62;
    final editorHeight = MediaQuery.sizeOf(context).height * 0.9;
    final targetHeight = _mode == _ProfileSheetMode.editor
        ? editorHeight
        : listHeight;

    return SafeArea(
      child: Material(
        color: sheetColor,
        child: BlocBuilder<ProfilesBloc, ProfilesState>(
          bloc: _profilesBloc,
          builder: (context, state) {
            final isMultiSelect =
                _mode == _ProfileSheetMode.list && _isMultiSelect(state);
            return PopScope(
              canPop: !isMultiSelect,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop && isMultiSelect) _exitMultiSelect();
              },
              child: AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  height: targetHeight,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      final offset = Tween<Offset>(
                        begin: const Offset(0.08, 0),
                        end: Offset.zero,
                      ).animate(animation);
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(position: offset, child: child),
                      );
                    },
                    child: _mode == _ProfileSheetMode.editor
                        ? KeyedSubtree(
                            key: const ValueKey<String>('profile-editor-mode'),
                            child: _buildEditor(context),
                          )
                        : KeyedSubtree(
                            key: const ValueKey<String>('profile-list-mode'),
                            child: _buildList(context, state),
                          ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HoldToSelectTile extends StatefulWidget {
  const _HoldToSelectTile({
    required this.index,
    required this.canReorder,
    required this.enabled,
    required this.multiSelect,
    required this.checked,
    required this.active,
    required this.title,
    required this.subtitle,
    required this.protocol,
    required this.onHoldTriggered,
    required this.onTap,
    this.trailing,
  });

  static const Duration holdDuration = Duration(seconds: 1);

  final int index;
  final bool canReorder;
  final bool enabled;
  final bool multiSelect;
  final bool checked;
  final bool active;
  final String title;
  final String subtitle;
  final TunnelProtocol protocol;
  final VoidCallback onHoldTriggered;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  State<_HoldToSelectTile> createState() => _HoldToSelectTileState();
}

class _HoldToSelectTileState extends State<_HoldToSelectTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _holdController;
  Timer? _holdTimer;
  int? _activePointer;
  Offset? _downPosition;
  bool _usingRecognizer = false;
  final Set<int> _ignoredPointers = <int>{};
  bool _suppressNextTap = false;

  @override
  void initState() {
    super.initState();
    _holdController = AnimationController(
      vsync: this,
      duration: _HoldToSelectTile.holdDuration,
    );
  }

  @override
  void didUpdateWidget(covariant _HoldToSelectTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _cancelHold();
    } else if (widget.multiSelect && !_usingRecognizer) {
      _cancelHold();
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _holdController.dispose();
    super.dispose();
  }

  void _completeHold() {
    _holdTimer = null;
    if (_activePointer == null || !widget.enabled || widget.multiSelect) return;
    _activePointer = null;
    _downPosition = null;
    _suppressNextTap = true;
    _holdController.reset();
    unawaited(HapticFeedback.mediumImpact());
    widget.onHoldTriggered();
  }

  void _completeHoldFromRecognizer() {
    if (!mounted || !widget.enabled || widget.multiSelect) return;
    _activePointer = null;
    _downPosition = null;
    _usingRecognizer = false;
    _holdController.reset();
    unawaited(HapticFeedback.mediumImpact());
    widget.onHoldTriggered();
  }

  void _cancelHoldFromRecognizer() {
    if (!mounted) return;
    _cancelHold();
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _activePointer = null;
    _downPosition = null;
    _usingRecognizer = false;
    if (_holdController.isAnimating || _holdController.value > 0) {
      _holdController.reset();
    }
  }

  void _handleTrailingPointerDown(PointerDownEvent event) {
    _ignoredPointers.add(event.pointer);
  }

  void _handlePointerDown(PointerDownEvent event) {
    _suppressNextTap = false;
    if (_ignoredPointers.contains(event.pointer)) return;
    if (!widget.enabled || widget.multiSelect || _activePointer != null) return;
    _activePointer = event.pointer;
    _downPosition = event.position;
    final reorderableList = widget.canReorder
        ? SliverReorderableList.maybeOf(context)
        : null;
    _holdTimer?.cancel();
    if (reorderableList != null) {
      _usingRecognizer = true;
      _holdController.forward(from: 0);
      reorderableList.startItemDragReorder(
        index: widget.index,
        event: event,
        recognizer: _HoldThenMoveDragRecognizer(
          delay: _HoldToSelectTile.holdDuration,
          onHoldTriggered: _completeHoldFromRecognizer,
          onHoldCancelled: _cancelHoldFromRecognizer,
          debugOwner: this,
        )..gestureSettings = MediaQuery.maybeGestureSettingsOf(context),
      );
      return;
    }
    _usingRecognizer = false;
    _holdTimer = Timer(_HoldToSelectTile.holdDuration, _completeHold);
    _holdController.forward(from: 0);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_usingRecognizer ||
        event.pointer != _activePointer ||
        _downPosition == null) {
      return;
    }
    if ((event.position - _downPosition!).distance > kTouchSlop) {
      _cancelHold();
    }
  }

  void _handlePointerEnd(PointerEvent event) {
    _ignoredPointers.remove(event.pointer);
    if (event.pointer == _activePointer) {
      if (_usingRecognizer) {
        _activePointer = null;
        _downPosition = null;
        _usingRecognizer = false;
      } else {
        _cancelHold();
      }
    }
  }

  void _handleTap() {
    if (_suppressNextTap) {
      _suppressNextTap = false;
      return;
    }
    if (!widget.enabled) return;
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;
    final highlightTitle = widget.multiSelect ? widget.checked : widget.active;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _holdController,
                builder: (context, _) {
                  final progress = _holdController.value;
                  if (progress <= 0) return const SizedBox.shrink();
                  return FractionallySizedBox(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: progress,
                    child: ColoredBox(
                      color: cs.primary.withValues(alpha: 0.14),
                    ),
                  );
                },
              ),
            ),
          ),
          ListTile(
            selected: widget.multiSelect ? widget.checked : widget.active,
            leading: widget.multiSelect
                ? Checkbox(
                    value: widget.checked,
                    onChanged: widget.enabled ? (_) => _handleTap() : null,
                  )
                : null,
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.titleSmall?.copyWith(
                      color: highlightTitle ? cs.primary : null,
                      fontWeight: highlightTitle ? FontWeight.w600 : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: widget.protocol.isPptp
                        ? cs.secondaryContainer
                        : cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    widget.protocol.shortLabel,
                    style: tt.labelSmall?.copyWith(
                      color: widget.protocol.isPptp
                          ? cs.onSecondaryContainer
                          : cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: Text(
              widget.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            trailing: widget.trailing == null
                ? null
                : Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _handleTrailingPointerDown,
                    child: widget.trailing,
                  ),
            onTap: widget.enabled ? _handleTap : null,
          ),
        ],
      ),
    );
  }
}

/// Recognizes a 1 s hold to enter multi-select and starts dragging only after
/// the pointer moves past touch slop so lifting immediately causes no bounce.
class _HoldThenMoveDragRecognizer extends MultiDragGestureRecognizer {
  _HoldThenMoveDragRecognizer({
    required this.delay,
    required this.onHoldTriggered,
    required this.onHoldCancelled,
    super.debugOwner,
  });

  final Duration delay;
  final VoidCallback onHoldTriggered;
  final VoidCallback onHoldCancelled;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _HoldThenMovePointerState(
      event.position,
      event.kind,
      gestureSettings,
      delay: delay,
      onHoldTriggered: onHoldTriggered,
      onHoldCancelled: onHoldCancelled,
    );
  }

  @override
  String get debugDescription => 'hold then move multidrag';
}

class _HoldThenMovePointerState extends MultiDragPointerState {
  _HoldThenMovePointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings, {
    required Duration delay,
    required this.onHoldTriggered,
    required this.onHoldCancelled,
  }) {
    _timer = Timer(delay, _delayPassed);
  }

  final VoidCallback onHoldTriggered;
  final VoidCallback onHoldCancelled;

  Timer? _timer;
  GestureMultiDragStartCallback? _starter;
  bool _holdCompleted = false;
  bool _notifiedCancel = false;
  Offset _deltaAtHoldComplete = Offset.zero;

  void _delayPassed() {
    _timer = null;
    _holdCompleted = true;
    _deltaAtHoldComplete = pendingDelta ?? Offset.zero;
    resolve(GestureDisposition.accepted);
    onHoldTriggered();
  }

  void _cancelHoldBeforeCompletion() {
    _timer?.cancel();
    _timer = null;
    if (!_holdCompleted && !_notifiedCancel) {
      _notifiedCancel = true;
      onHoldCancelled();
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    _starter = starter;
  }

  @override
  void checkForResolutionAfterMove() {
    final delta = pendingDelta;
    if (delta == null) return;
    final slop = computeHitSlop(kind, gestureSettings);

    if (!_holdCompleted) {
      if (_timer != null && delta.distance > slop) {
        resolve(GestureDisposition.rejected);
        _cancelHoldBeforeCompletion();
      }
      return;
    }

    if (_starter != null) {
      final postHoldDelta = delta - _deltaAtHoldComplete;
      if (delta.distance > slop || postHoldDelta.distance > slop) {
        final starter = _starter!;
        _starter = null;
        starter(initialPosition);
      }
    }
  }

  @override
  void rejected() {
    _starter = null;
    _cancelHoldBeforeCompletion();
    super.rejected();
  }

  @override
  void dispose() {
    _starter = null;
    _cancelHoldBeforeCompletion();
    super.dispose();
  }
}

class _PopupMenuIconLabel extends StatelessWidget {
  const _PopupMenuIconLabel({
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: effectiveColor),
        const SizedBox(width: 12),
        Flexible(
          child: Text(label, style: TextStyle(color: color)),
        ),
      ],
    );
  }
}

enum _AddProfileAction { create, importFile, importClipboard }

enum _ProfileTileAction { edit, copyShareLink, exportFile, delete }

enum _ProfileSheetMode { list, editor }
