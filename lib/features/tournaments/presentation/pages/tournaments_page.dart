import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../players/data/repositories/player_repository.dart';
import '../../../players/domain/entities/player_stats.dart';
import '../../data/tournament_repository.dart';
import '../../domain/tournament.dart';
import 'tournament_detail_page.dart';

enum _TournamentFormat { single, double, league, groups, swiss }

class _PrizeDraft {
  int place;
  String type;
  final TextEditingController valueController;

  _PrizeDraft({required this.place, String value = ''})
    : type = 'percentage',
      valueController = TextEditingController(text: value);

  void dispose() => valueController.dispose();
}

class TournamentsPage extends StatefulWidget {
  const TournamentsPage({super.key});

  @override
  State<TournamentsPage> createState() => _TournamentsPageState();
}

class _TournamentsPageState extends State<TournamentsPage> {
  final _repository = TournamentRepository();
  final _playerRepository = PlayerRepository();
  final _nameController = TextEditingController();
  final _capacityController = TextEditingController(text: '8');
  final _raceToController = TextEditingController(text: '7');
  final _setsController = TextEditingController(text: '7');
  final _guaranteedPoolController = TextEditingController(text: '0');
  final _entryFeeController = TextEditingController(text: '0');
  final _timeFeeController = TextEditingController(text: '0');
  final List<_PrizeDraft> _prizeDrafts = [];
  List<TournamentEntity> _tournaments = [];
  List<TournamentEntity> _playedTournaments = [];
  List<PlayerEntity> _players = [];
  _TournamentFormat _format = _TournamentFormat.single;
  bool _limitedCapacity = true;
  bool _manualRaceTo = false;
  bool _manualSets = false;
  String _gameType = 'Bola 9';
  int _playoffQualifiers = 0;
  int _raceTo = 3;
  int _setsToPlay = 1;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _capacityController.dispose();
    _raceToController.dispose();
    _setsController.dispose();
    _guaranteedPoolController.dispose();
    _entryFeeController.dispose();
    _timeFeeController.dispose();
    for (final prize in _prizeDrafts) {
      prize.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final result = await Future.wait([
        _repository.listActive(),
        _repository.listPlayed(),
        _playerRepository.getAll(),
      ]);
      final tournaments = result[0] as List<TournamentEntity>;
      final playedTournaments = result[1] as List<TournamentEntity>;
      final players = result[2] as List<PlayerEntity>;
      if (!mounted) return;
      setState(() {
        _tournaments = tournaments;
        _playedTournaments = playedTournaments;
        _players =
            players.where((player) => player.enrollmentIsActive).toList();
      });
    } catch (error, stackTrace) {
      debugPrint(
        '[TournamentsPage] Could not load tournaments: $error\n$stackTrace',
      );
      if (mounted) _showMessage('No se pudieron cargar los torneos: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createTournament() async {
    final name = _nameController.text.trim().toUpperCase();
    final capacity =
        _limitedCapacity ? int.tryParse(_capacityController.text) : null;
    final raceTo =
        _manualRaceTo ? int.tryParse(_raceToController.text) : _raceTo;
    final setsToPlay =
        _manualSets ? int.tryParse(_setsController.text) : _setsToPlay;
    final guaranteedPool = _parseMoney(_guaranteedPoolController.text);
    final entryFee = _parseMoney(_entryFeeController.text);
    final timeFee = _parseMoney(_timeFeeController.text);
    if (name.isEmpty) {
      _showMessage('Escribe el nombre del torneo.');
      return;
    }
    if (_limitedCapacity &&
        (capacity == null || capacity < 8 || capacity > 256)) {
      _showMessage('El cupo debe ser de 8 a 256 jugadores.');
      return;
    }
    if (_format == _TournamentFormat.groups &&
        capacity != null &&
        capacity < 3) {
      _showMessage('El formato de grupos requiere al menos tres jugadores.');
      return;
    }
    if (raceTo == null || raceTo < 1 || raceTo > 99) {
      _showMessage('La cantidad manual debe ser de 1 a 99 partidas ganadas.');
      return;
    }
    if (setsToPlay == null ||
        setsToPlay < 1 ||
        setsToPlay > 99 ||
        setsToPlay.isEven) {
      _showMessage('Los sets deben ser un número impar entre 1 y 99.');
      return;
    }
    if (guaranteedPool == null ||
        entryFee == null ||
        timeFee == null ||
        guaranteedPool < 0 ||
        entryFee < 0 ||
        timeFee < 0) {
      _showMessage('Revisa los importes de bolsa, inscripción y tiempo.');
      return;
    }
    final prizes = <TournamentPrize>[];
    for (final draft in _prizeDrafts) {
      final value = _parseMoney(draft.valueController.text);
      if (value == null ||
          value < 0 ||
          (draft.type == 'percentage' && value > 100)) {
        _showMessage('Revisa el premio del lugar ${draft.place}.');
        return;
      }
      prizes.add(
        TournamentPrize(place: draft.place, type: draft.type, value: value),
      );
    }
    if (prizes.map((prize) => prize.place).toSet().length != prizes.length) {
      _showMessage('Cada lugar premiado debe ser único.');
      return;
    }
    if (prizes
            .where((prize) => prize.type == 'percentage')
            .fold<double>(0, (total, prize) => total + prize.value) >
        100) {
      _showMessage('Los porcentajes de premios no pueden superar el 100%.');
      return;
    }

    setState(() => _saving = true);
    try {
      await _repository.create(
        name: name,
        format: _format.name == 'league' ? 'liga' : _format.name,
        capacity: capacity,
        raceTo: raceTo,
        setsToPlay: setsToPlay,
        guaranteedPool: guaranteedPool,
        entryFee: entryFee,
        timeFee: timeFee,
        prizes: prizes,
        gameType: _gameType,
        playoffQualifiers:
            _format == _TournamentFormat.league ? _playoffQualifiers : 0,
      );
      _nameController.clear();
      await _load();
      if (mounted) _showMessage('Torneo creado.');
    } catch (error, stackTrace) {
      debugPrint(
        '[TournamentsPage] Could not create tournament: $error\n$stackTrace',
      );
      if (mounted) _showMessage(_creationErrorMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _chooseRegisteredPlayer(TournamentEntity tournament) async {
    final registeredCodes =
        tournament.entries
            .map((entry) => entry.playerCode)
            .where((code) => code.isNotEmpty)
            .toSet();
    final registeredIds =
        tournament.entries
            .map((entry) => entry.registeredPlayerId)
            .whereType<String>()
            .toSet();
    final available =
        _players
            .where(
              (player) =>
                  !registeredCodes.contains(player.playerCode) &&
                  (player.cloudId == null ||
                      !registeredIds.contains(player.cloudId)),
            )
            .toList();
    if (available.isEmpty) {
      _showMessage('No hay jugadores activos disponibles para inscribir.');
      return;
    }
    final selected = await showModalBottomSheet<PlayerEntity>(
      context: context,
      showDragHandle: true,
      builder:
          (context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(
                  title: Text('JUGADORES REGISTRADOS'),
                  subtitle: Text('Selecciona a quién quieres inscribir.'),
                ),
                for (final player in available)
                  ListTile(
                    leading: TournamentEntryAvatar(
                      entry: TournamentEntry(
                        id: player.playerCode,
                        name: player.name,
                        nickname: player.nickname,
                        avatar: player.avatar,
                      ),
                    ),
                    title: Text(player.displayName.toUpperCase()),
                    subtitle: Text(
                      player.playerCode.isEmpty
                          ? 'Sin código'
                          : player.playerCode,
                    ),
                    trailing: Text(
                      '★' * player.level,
                      style: const TextStyle(
                        color: Colors.amber,
                        letterSpacing: 1,
                      ),
                    ),
                    onTap: () => Navigator.pop(context, player),
                  ),
              ],
            ),
          ),
    );
    if (selected == null || !mounted) return;
    await _addRegisteredPlayer(tournament, selected);
  }

  Future<void> _addRegisteredPlayer(
    TournamentEntity tournament,
    PlayerEntity player,
  ) async {
    await _addEntry(
      tournament,
      TournamentEntry(
        id: TournamentRepository.newEntryId(),
        name: player.name.toUpperCase(),
        nickname: player.nickname.toUpperCase(),
        avatar: player.avatar,
        playerCode: player.playerCode,
        registeredPlayerId: player.cloudId,
        handicap: player.level,
      ),
    );
  }

  Future<void> _addWalkIn(TournamentEntity tournament) async {
    final nameController = TextEditingController();
    var handicap = 1;
    final entry = await showDialog<TournamentEntry>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('INSCRIBIR JUGADOR DE PASO'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: nameController,
                        autofocus: true,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          TextInputFormatter.withFunction(
                            (_, value) =>
                                value.copyWith(text: value.text.toUpperCase()),
                          ),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Nombre del jugador',
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: handicap,
                        decoration: const InputDecoration(
                          labelText: 'Handicap',
                        ),
                        items: List.generate(
                          6,
                          (index) => DropdownMenuItem(
                            value: index + 1,
                            child: Text('★' * (index + 1)),
                          ),
                        ),
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => handicap = value);
                          }
                        },
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('CANCELAR'),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        final name = nameController.text.trim().toUpperCase();
                        if (name.isEmpty) return;
                        Navigator.pop(
                          context,
                          TournamentEntry(
                            id: TournamentRepository.newEntryId(),
                            name: name,
                            handicap: handicap,
                            isGuest: true,
                          ),
                        );
                      },
                      child: const Text('INSCRIBIR'),
                    ),
                  ],
                ),
          ),
    );
    nameController.dispose();
    if (entry == null || !mounted) return;
    await _addEntry(tournament, entry);
  }

  Future<void> _addEntry(
    TournamentEntity tournament,
    TournamentEntry entry,
  ) async {
    try {
      await _repository.addEntry(tournament, entry);
      await _load();
    } catch (error, stackTrace) {
      debugPrint(
        '[TournamentsPage] Could not register tournament player: $error\n$stackTrace',
      );
      if (mounted) _showMessage('No se pudo inscribir: $error');
    }
  }

  Future<void> _removeEntry(
    TournamentEntity tournament,
    TournamentEntry entry,
  ) async {
    try {
      await _repository.removeEntry(tournament, entry.id);
      await _load();
    } catch (error, stackTrace) {
      debugPrint(
        '[TournamentsPage] Could not remove tournament player: $error\n$stackTrace',
      );
      if (mounted) _showMessage('No se pudo quitar la inscripción: $error');
    }
  }

  Future<void> _archive(TournamentEntity tournament) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Finalizar torneo'),
            content: Text(
              '¿Quieres quitar "${tournament.name}" de los torneos activos?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('CANCELAR'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('FINALIZAR'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _repository.archive(tournament);
      await _load();
    } catch (error, stackTrace) {
      debugPrint(
        '[TournamentsPage] Could not finish tournament: $error\n$stackTrace',
      );
      if (mounted) _showMessage('No se pudo finalizar el torneo: $error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  double? _parseMoney(String value) =>
      double.tryParse(value.trim().replaceAll(',', '.'));

  void _selectAllOnTap(TextEditingController controller) {
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
  }

  String _creationErrorMessage(Object error) {
    final text = error.toString();
    if (text.contains('PGRST204') &&
        [
          'guaranteed_pool',
          'entry_fee',
          'time_fee',
          'prizes',
        ].any((column) => text.contains(column))) {
      return 'Falta actualizar Supabase. Ejecuta supabase/add_tournaments.sql '
          'en el SQL Editor y vuelve a crear el torneo.';
    }
    return 'No se pudo crear el torneo: $error';
  }

  void _addPrizeDraft() {
    final usedPlaces = _prizeDrafts.map((prize) => prize.place).toSet();
    final place = List.generate(16, (index) => index + 1).firstWhere(
      (candidate) => !usedPlaces.contains(candidate),
      orElse: () => 0,
    );
    if (place == 0) {
      _showMessage('Solo puedes configurar premios hasta el lugar 16.');
      return;
    }
    setState(() => _prizeDrafts.add(_PrizeDraft(place: place)));
  }

  void _removePrizeDraft(_PrizeDraft prize) {
    setState(() => _prizeDrafts.remove(prize));
    prize.dispose();
  }

  Future<void> _openTournament(TournamentEntity tournament) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => TournamentDetailPage(tournament: tournament),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _cancelTournament(TournamentEntity tournament) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Cancelar torneo'),
            content: Text(
              '¿Cancelar "${tournament.name}"? Se quitará de torneos activos, '
              'pero se conservará su registro e historial.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('VOLVER'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('CANCELAR TORNEO'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      await _repository.cancel(tournament);
      await _load();
      if (mounted) {
        _showMessage('Torneo cancelado y conservado en el historial.');
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[TournamentsPage] Could not cancel tournament: $error\n$stackTrace',
      );
      if (mounted) _showMessage('No se pudo cancelar el torneo: $error');
    }
  }

  Future<void> _editRaceTo(TournamentEntity tournament) async {
    final controller = TextEditingController(text: '${tournament.raceTo}');
    final setsController = TextEditingController(
      text: '${tournament.setsToPlay}',
    );
    var selected = tournament.raceTo;
    var manual = !const [3, 9, 11, 13, 15].contains(selected);
    var selectedSets = tournament.setsToPlay;
    var manualSets = !const [1, 3, 5].contains(selectedSets);
    String? validationError;
    final settings = await showDialog<({int raceTo, int setsToPlay})>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('DURACIÓN DEL ENFRENTAMIENTO'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final target in const [3, 9, 11, 13, 15])
                            ChoiceChip(
                              label: Text('$target'),
                              selected: !manual && selected == target,
                              onSelected:
                                  (_) => setDialogState(() {
                                    selected = target;
                                    manual = false;
                                  }),
                            ),
                          ChoiceChip(
                            label: const Text('Manual'),
                            selected: manual,
                            onSelected:
                                (_) => setDialogState(() => manual = true),
                          ),
                        ],
                      ),
                      if (manual)
                        TextField(
                          controller: controller,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Número de partidas ganadas',
                          ),
                        ),
                      const SizedBox(height: 16),
                      const Text('SETS (GANA LA MAYORÍA)'),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final sets in const [1, 3, 5])
                            ChoiceChip(
                              label: Text('$sets'),
                              selected: !manualSets && selectedSets == sets,
                              onSelected:
                                  (_) => setDialogState(() {
                                    selectedSets = sets;
                                    manualSets = false;
                                  }),
                            ),
                          ChoiceChip(
                            label: const Text('Manual'),
                            selected: manualSets,
                            onSelected:
                                (_) => setDialogState(() => manualSets = true),
                          ),
                        ],
                      ),
                      if (manualSets)
                        TextField(
                          controller: setsController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Número impar de sets',
                          ),
                        ),
                      if (validationError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            validationError!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('CANCELAR'),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        final value =
                            manual ? int.tryParse(controller.text) : selected;
                        final sets =
                            manualSets
                                ? int.tryParse(setsController.text)
                                : selectedSets;
                        if (value == null ||
                            value < 1 ||
                            value > 99 ||
                            sets == null ||
                            sets < 1 ||
                            sets > 99 ||
                            sets.isEven) {
                          setDialogState(
                            () =>
                                validationError =
                                    'Las partidas deben ser de 1 a 99 y los sets un número impar de 1 a 99.',
                          );
                          return;
                        }
                        Navigator.pop(context, (
                          raceTo: value,
                          setsToPlay: sets,
                        ));
                      },
                      child: const Text('GUARDAR'),
                    ),
                  ],
                ),
          ),
    );
    controller.dispose();
    setsController.dispose();
    if (settings == null || !mounted) return;
    try {
      await _repository.updateMatchSettings(
        tournament,
        raceTo: settings.raceTo,
        setsToPlay: settings.setsToPlay,
      );
      await _load();
    } catch (error, stackTrace) {
      debugPrint(
        '[TournamentsPage] Could not update race-to: $error\n$stackTrace',
      );
      if (mounted) _showMessage('No se pudo actualizar: $error');
    }
  }

  String _formatLabel(_TournamentFormat format) => switch (format) {
    _TournamentFormat.single => 'Eliminación simple',
    _TournamentFormat.double => 'Doble eliminación (ronda de perdedores)',
    _TournamentFormat.league => 'Round Robin (todos contra todos)',
    _TournamentFormat.groups => 'Grupos',
    _TournamentFormat.swiss => 'Suizo',
  };

  Widget _buildPlayedTournamentCard(TournamentEntity tournament) {
    final champion =
        tournament.entries
            .where((entry) => entry.id == tournament.championEntryId)
            .firstOrNull;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: const Icon(Icons.emoji_events, color: Colors.amber),
        title: Text(tournament.name),
        subtitle: Text(
          tournament.isCancelled
              ? 'CANCELADO · ${tournament.entries.length} jugadores'
              : champion == null
              ? 'Finalizado'
              : 'CAMPEÓN: ${champion.displayName} · ${tournament.entries.length} jugadores',
        ),
        trailing: Icon(
          tournament.isCancelled ? Icons.block : Icons.chevron_right,
          color: tournament.isCancelled ? Colors.redAccent : null,
        ),
        onTap:
            tournament.isCancelled
                ? null
                : () => _openTournament(tournament),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'TORNEOS',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body:
          _loading && _tournaments.isEmpty
              ? Center(child: CircularProgressIndicator(color: primary))
              : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildCreateForm(primary),
                    const SizedBox(height: 20),
                    if (_tournaments.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Center(child: Text('Sin torneos activos')),
                      )
                    else ...[
                      const Text(
                        'TORNEOS ACTIVOS',
                        style: TextStyle(
                          color: Colors.white54,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      for (final tournament in _tournaments)
                        _buildTournamentCard(tournament, primary),
                    ],
                    if (_playedTournaments.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'TORNEOS JUGADOS',
                        style: TextStyle(
                          color: Colors.white54,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      for (final tournament in _playedTournaments)
                        _buildPlayedTournamentCard(tournament),
                    ],
                  ],
                ),
              ),
    );
  }

  Widget _buildCreateForm(Color primary) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'NUEVO TORNEO',
              style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (_, value) => value.copyWith(text: value.text.toUpperCase()),
                ),
              ],
              decoration: const InputDecoration(
                labelText: 'Nombre del torneo',
                hintText: 'TORNEO DE OTOÑO',
                prefixIcon: Icon(Icons.emoji_events_outlined),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'TIPO DE TORNEO',
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children:
                  _TournamentFormat.values.map((format) {
                    final selected = _format == format;
                    return ChoiceChip(
                      label: Text(_formatLabel(format)),
                      selected: selected,
                      selectedColor: primary.withValues(alpha: 0.25),
                      onSelected: (_) => setState(() => _format = format),
                    );
                  }).toList(),
            ),
            const SizedBox(height: 12),
            const Text('JUEGO', style: TextStyle(color: Colors.white54)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final gameType in const ['Bola 8', 'Bola 9', 'Bola 10'])
                  ChoiceChip(
                    label: Text(gameType.toUpperCase()),
                    selected: _gameType == gameType,
                    onSelected: (_) => setState(() => _gameType = gameType),
                  ),
              ],
            ),
            if (_gameType == 'Bola 8')
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Meter la bola 8 antes de tiempo cuenta como juego perdido.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            if (_format == _TournamentFormat.league) ...[
              const SizedBox(height: 16),
              const Text(
                'CÓMO DEFINIR AL CAMPEÓN',
                style: TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text('Por puntos de Round Robin'),
                    selected: _playoffQualifiers == 0,
                    onSelected: (_) => setState(() => _playoffQualifiers = 0),
                  ),
                  ChoiceChip(
                    label: const Text('Finales · mejores 8'),
                    selected: _playoffQualifiers == 8,
                    onSelected: (_) => setState(() => _playoffQualifiers = 8),
                  ),
                ],
              ),
              if (_playoffQualifiers == 8)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Clasifican los 8 mejores; se sortea una llave de cuartos de final y se juega por el tercer lugar.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
            ],
            const SizedBox(height: 16),
            const Text(
              'PARTIDAS PARA GANAR CADA SET',
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final target in const [3, 9, 11, 13, 15])
                  ChoiceChip(
                    label: Text('$target'),
                    selected: !_manualRaceTo && _raceTo == target,
                    onSelected:
                        (_) => setState(() {
                          _manualRaceTo = false;
                          _raceTo = target;
                        }),
                  ),
                ChoiceChip(
                  label: const Text('Manual'),
                  selected: _manualRaceTo,
                  onSelected: (_) => setState(() => _manualRaceTo = true),
                ),
              ],
            ),
            if (_manualRaceTo) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _raceToController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Número de partidas ganadas',
                  helperText: 'Ingresa un valor de 1 a 99.',
                ),
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              'SETS PARA GANAR (MAYORÍA)',
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final sets in const [1, 3, 5])
                  ChoiceChip(
                    label: Text('$sets'),
                    selected: !_manualSets && _setsToPlay == sets,
                    onSelected:
                        (_) => setState(() {
                          _manualSets = false;
                          _setsToPlay = sets;
                        }),
                  ),
                ChoiceChip(
                  label: const Text('Manual'),
                  selected: _manualSets,
                  onSelected: (_) => setState(() => _manualSets = true),
                ),
              ],
            ),
            if (_manualSets) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _setsController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Número impar de sets',
                  helperText: 'Ingresa un número impar de 1 a 99.',
                ),
              ),
            ],
            const SizedBox(height: 20),
            const Text(
              'INSCRIPCIÓN Y BOLSA',
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _guaranteedPoolController,
              onTap: () => _selectAllOnTap(_guaranteedPoolController),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              decoration: const InputDecoration(
                labelText: 'Bolsa garantizada (MXN)',
                helperText:
                    'Se suma completa a lo recaudado por inscripciones.',
                prefixText: '\$ ',
                suffixText: 'MXN',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _entryFeeController,
              onTap: () => _selectAllOnTap(_entryFeeController),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              decoration: const InputDecoration(
                labelText: 'Costo de inscripción por jugador (MXN)',
                prefixText: '\$ ',
                suffixText: 'MXN',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _timeFeeController,
              onTap: () => _selectAllOnTap(_timeFeeController),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              decoration: const InputDecoration(
                labelText:
                    'Costo de tiempo por enfrentamiento completado (MXN)',
                prefixText: '\$ ',
                suffixText: 'MXN',
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'PREMIOS POR LUGAR',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                TextButton.icon(
                  onPressed: _addPrizeDraft,
                  icon: const Icon(Icons.add),
                  label: const Text('AGREGAR LUGAR'),
                ),
              ],
            ),
            if (_prizeDrafts.isEmpty)
              const Text(
                'Opcional: agrega los lugares que recibirán premio.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            for (final prize in _prizeDrafts) _buildPrizeDraft(prize),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Cupo definido'),
                  selected: _limitedCapacity,
                  onSelected: (_) => setState(() => _limitedCapacity = true),
                ),
                ChoiceChip(
                  label: const Text('Inscripción abierta'),
                  selected: !_limitedCapacity,
                  onSelected: (_) => setState(() => _limitedCapacity = false),
                ),
              ],
            ),
            if (_limitedCapacity) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _capacityController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Cupo máximo de jugadores',
                  helperText: 'Se requieren al menos 8 jugadores para iniciar.',
                  prefixIcon: Icon(Icons.people_outline),
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _createTournament,
                icon: const Icon(Icons.add),
                label: Text(_saving ? 'GUARDANDO...' : 'CREAR TORNEO'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrizeDraft(_PrizeDraft prize) {
    final otherPlaces =
        _prizeDrafts
            .where((draft) => !identical(draft, prize))
            .map((draft) => draft.place)
            .toSet();
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            Row(
              children: [
                const Text('Lugar'),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: prize.place,
                  items: [
                    for (var place = 1; place <= 16; place++)
                      if (!otherPlaces.contains(place))
                        DropdownMenuItem(value: place, child: Text('$place')),
                  ],
                  onChanged:
                      (place) => setState(() {
                        if (place != null) prize.place = place;
                      }),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Quitar premio',
                  onPressed: () => _removePrizeDraft(prize),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: prize.type,
                    decoration: const InputDecoration(
                      labelText: 'Tipo de premio',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'percentage',
                        child: Text('Porcentaje'),
                      ),
                      DropdownMenuItem(
                        value: 'fixed',
                        child: Text('Monto fijo'),
                      ),
                    ],
                    onChanged:
                        (type) => setState(() {
                          if (type != null) prize.type = type;
                        }),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: prize.valueController,
                    onTap: () => _selectAllOnTap(prize.valueController),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d*\.?\d{0,2}'),
                      ),
                    ],
                    decoration: InputDecoration(
                      labelText:
                          prize.type == 'percentage'
                              ? 'Porcentaje'
                              : 'Monto (MXN)',
                      prefixText: prize.type == 'fixed' ? '\$ ' : null,
                      suffixText: prize.type == 'percentage' ? '%' : 'MXN',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTournamentCard(TournamentEntity tournament, Color primary) {
    final progress =
        tournament.capacity == null
            ? null
            : (tournament.entries.length / tournament.capacity!).clamp(
              0.0,
              1.0,
            );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _openTournament(tournament),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        tournament.name.toUpperCase(),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 17,
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Abrir torneo y marcador',
                  onPressed: () => _openTournament(tournament),
                  icon: const Icon(Icons.sports_score),
                ),
                IconButton(
                  tooltip:
                      tournament.matches.isEmpty
                          ? 'Cambiar partidas para ganar'
                          : 'El sorteo ya inició; cantidad bloqueada',
                  onPressed:
                      tournament.matches.isEmpty
                          ? () => _editRaceTo(tournament)
                          : null,
                  icon: const Icon(Icons.flag_outlined),
                ),
                IconButton(
                  tooltip:
                      tournament.hasChampion
                          ? 'Finalizar y guardar en historial'
                          : 'El torneo debe tener campeón para finalizarse',
                  onPressed:
                      tournament.hasChampion
                          ? () => _archive(tournament)
                          : null,
                  icon: const Icon(Icons.archive_outlined),
                ),
                IconButton(
                  tooltip: 'Cancelar torneo y conservar historial',
                  onPressed: () => _cancelTournament(tournament),
                  icon: const Icon(
                    Icons.cancel_outlined,
                    color: Colors.redAccent,
                  ),
                ),
              ],
            ),
            Text(
              '${_formatLabel(_TournamentFormat.values.firstWhere((format) => (format.name == 'league' ? 'liga' : format.name) == tournament.format, orElse: () => _TournamentFormat.single))} · ${tournament.gameType.toUpperCase()} · ${tournament.enrollmentLabel} · A ${tournament.raceTo} partidas, mejor de ${tournament.setsToPlay} sets${tournament.playoffQualifiers > 0 ? ' · FINALES TOP ${tournament.playoffQualifiers} + 3ER LUGAR' : ''}',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            if (tournament.entries.length < 8) ...[
              const SizedBox(height: 4),
              Text(
                'Faltan ${8 - tournament.entries.length} jugadores para habilitar el sorteo (mínimo 8).',
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Inscripciones: ${formatTournamentMoney(tournament.entryTotal)} · '
              'Bolsa: ${formatTournamentMoney(tournament.prizePool)} · '
              'Tiempo: ${formatTournamentMoney(tournament.timeRevenue)}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            if (progress != null) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: progress, color: primary),
            ],
            if (tournament.entries.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final entry in tournament.entries)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading:
                      entry.avatar.isNotEmpty
                          ? TournamentEntryAvatar(entry: entry)
                          : Icon(
                            entry.isGuest
                                ? Icons.person_add_alt
                                : Icons.person_outline,
                          ),
                  title: Text(entry.displayName.toUpperCase()),
                  subtitle: Row(
                    children: [
                      Text(entry.isGuest ? 'DE PASO' : entry.playerCode),
                      const SizedBox(width: 8),
                      Text(
                        '★' * entry.handicap.clamp(1, 6).toInt(),
                        style: const TextStyle(
                          color: Colors.amber,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    tooltip: 'Quitar inscripción',
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed:
                        tournament.matches.isEmpty
                            ? () => _removeEntry(tournament, entry)
                            : null,
                  ),
                ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    tournament.isFull || tournament.matches.isNotEmpty
                        ? null
                        : () => _chooseRegisteredPlayer(tournament),
                icon: const Icon(Icons.person_search),
                label: Text(
                  tournament.isFull ? 'CUPO LLENO' : 'INSCRIBIR JUGADOR',
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed:
                    tournament.isFull || tournament.matches.isNotEmpty
                        ? null
                        : () => _addWalkIn(tournament),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('INSCRIBIR JUGADOR DE PASO'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
