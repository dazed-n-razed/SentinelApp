import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Initialize Firebase and start the app.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SENTINEL Home Security',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const DashboardScreen(),
    );
  }
}

// Lightweight in-memory notifications service for the app UI.
class NotificationItem {
  final String message;
  final DateTime time;
  final String? trigger; // e.g. 'alarm', 'gas', 'intruder', 'door', 'temp', 'manual'
  NotificationItem(this.message, this.time, {this.trigger});
}

class NotificationsService extends ChangeNotifier {
  NotificationsService._();
  static final NotificationsService instance = NotificationsService._();

  final List<NotificationItem> _items = [];

  List<NotificationItem> get items => List.unmodifiable(_items);

  void add(String message, {String? trigger}) {
    final item = NotificationItem(message, DateTime.now(), trigger: trigger);
    _items.insert(0, item);
    notifyListeners();
  }

  void removeAt(int index) {
    if (index < 0 || index >= _items.length) return;
    _items.removeAt(index);
    notifyListeners();
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<
DashboardScreen> {
  final DatabaseReference _sensorRef = FirebaseDatabase.instance.ref('sensor');
  bool _previousAlarm = false;
  bool _previousDoorOpen = false;
  int _previousWrongAttempts = 0;
  StreamSubscription<DatabaseEvent>? _sensorSub;
  Timer? _pollTimer;
  Map<dynamic, dynamic> _latestData = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SENTINEL Dashboard'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
              ),
              child: const Align(
                alignment: Alignment.bottomLeft,
                child: Text('SENTINEL', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.dashboard),
              title: const Text('Dashboard'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.notifications),
              title: const Text('Notifications'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsScreen()));
              },
            ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: _buildGrid(),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // Listen for server push events
    _sensorSub = _sensorRef.onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw is Map) {
        setState(() {
          _latestData = Map<dynamic, dynamic>.from(raw);
        });
      }
    }, onError: (_) {});

    // Poll as a fallback (2s default) to reduce latency if pushes are slow
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollSensor());
  }

  Future<void> _pollSensor() async {
    try {
      final snap = await _sensorRef.get();
      final raw = snap.value;
      if (raw is Map) {
        if (!mapEquals(_latestData, raw)) {
          setState(() {
            _latestData = Map<dynamic, dynamic>.from(raw);
          });
        }
      }
    } catch (_) {
      // ignore polling errors
    }
  }

  @override
  void dispose() {
    _sensorSub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  Widget _buildGrid() {
    final Map<dynamic, dynamic> data = _latestData;
    if (data.isEmpty) {
      return GridView.count(
        crossAxisCount: 2,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        children: const [
          _DashboardCard(title: 'Temperature', value: '-- °C'),
          _DashboardCard(title: 'Humidity', value: '-- %'),
          _DashboardCard(title: 'Gas Leak', value: 'N'),
          _DashboardCard(title: 'Intruder Distance', value: '-- cm'),
          _DashboardCard(title: 'IR Activity', value: '--'),
          _DashboardCard(title: 'Alarm', value: 'Off'),
        ],
      );
    }

    String temp = data['temp_c']?.toString() ?? '--';
    String hum = data['hum_pct']?.toString() ?? '--';
    bool gas = (data['gas_detect'] == true || data['gas_detect']?.toString().toLowerCase() == 'true');
    String gasStr = gas ? 'Y' : 'N';
    String dist = data['distance_cm']?.toString() ?? '--';
    bool ir = (data['ir_detect'] == true || data['ir_detect']?.toString().toLowerCase() == 'true');
    String irStr = ir ? 'Active' : 'Idle';
  bool alarm = (data['alarm'] == true || data['alarm']?.toString().toLowerCase() == 'true');
  String alarmStr = alarm ? 'On' : 'Off';

    bool doorOpen = (data['door_open'] == true || data['door_open']?.toString().toLowerCase() == 'true');
    String doorStr = doorOpen ? 'Open' : 'Closed';

    // detect transition from closed -> open (door unlocked/opened)
    if (doorOpen && !_previousDoorOpen) {
      final alarmText = alarm ? ' (ALARM ACTIVE)' : '';
      NotificationsService.instance.add('Door unlocked$alarmText', trigger: 'door');
    }
    _previousDoorOpen = doorOpen;

    // detect wrong password attempts and notify when threshold reached or increased
    final wrongAttemptsRaw = data['wrong_attempts'];
    int wrongAttempts = 0;
    try {
      if (wrongAttemptsRaw is int) {
        wrongAttempts = wrongAttemptsRaw;
      } else if (wrongAttemptsRaw is String) wrongAttempts = int.tryParse(wrongAttemptsRaw) ?? 0;
    } catch (_) {
      wrongAttempts = 0;
    }

    if (wrongAttempts >= 3 && wrongAttempts > _previousWrongAttempts) {
      NotificationsService.instance.add('Wrong password attempts: $wrongAttempts', trigger: 'auth');
    }
    _previousWrongAttempts = wrongAttempts;

    // When alarm turns on, create notifications for every cause detected
    if (alarm && !_previousAlarm) {
      final List<String> causes = [];

      if (gas) causes.add('Gas leak detected');
      if (ir) causes.add('IR activity detected');

      // check distance as numeric: consider < 100 cm as intrusion
      double distNum = double.tryParse(data['distance_cm']?.toString() ?? '') ?? double.infinity;
      if (distNum.isFinite && distNum < 100.0) {
        causes.add('Intruder within ${distNum.toStringAsFixed(0)} cm');
      }

      if (doorOpen) causes.add('Door opened');
      if (wrongAttempts >= 3) causes.add('Multiple wrong password attempts ($wrongAttempts)');

      final causesText = causes.isEmpty ? 'Unknown' : causes.join(', ');
      // summary notification
      NotificationsService.instance.add('Alarm turned ON — Causes: $causesText', trigger: 'alarm');

      // individual notifications for each cause
      for (final c in causes) {
        String trig = 'intruder';
        if (c.toLowerCase().contains('gas')) {
          trig = 'gas';
        } else if (c.toLowerCase().contains('ir')) trig = 'intruder';
        else if (c.toLowerCase().contains('door')) trig = 'door';
        else if (c.toLowerCase().contains('wrong')) trig = 'auth';
        NotificationsService.instance.add(c, trigger: trig);
      }
    }
    _previousAlarm = alarm;

    // Modern layout: alarm panel at top, stats grid below
    return Column(
      children: [
        _AlarmPanel(alarm: alarm),
        const SizedBox(height: 16),
        Expanded(
          child: GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 1.2,
            children: [
              _DashboardCard(title: 'Temperature', value: '$temp °C'),
              _DashboardCard(title: 'Humidity', value: '$hum %'),
              _DashboardCard(title: 'Gas Leak', value: gasStr),
              _DashboardCard(title: 'Intruder Distance', value: '$dist cm'),
              _DashboardCard(title: 'IR Activity', value: irStr),
              _DashboardCard(title: 'Door', value: doorStr),
            ],
          ),
        ),
      ],
    );
  }
}

class _AlarmPanel extends StatelessWidget {
  final bool alarm;
  const _AlarmPanel({required this.alarm});

  @override
  Widget build(BuildContext context) {
    final color = alarm ? Colors.redAccent : Colors.green;
    final icon = alarm ? Icons.warning_amber_rounded : Icons.check_circle_outline;
    final status = alarm ? 'ACTIVE' : 'Normal';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(0.9), color.withOpacity(0.6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: color.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: Colors.white.withOpacity(0.2),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('ALARM', style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(status, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white70)),
              ],
            ),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white.withOpacity(0.18), elevation: 0),
            onPressed: () {
              // quick action placeholder: open notifications
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));
            },
            icon: const Icon(Icons.arrow_forward, color: Colors.white),
            label: const Text('View', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  final String title;
  final String value;

  const _DashboardCard({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
  }

  void _removeAt(int index) {
    NotificationsService.instance.removeAt(index);
  }

  void _addSample() {
  NotificationsService.instance.add('Sample notification', trigger: 'manual');
  }

  String _format12(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute:$second $ampm';
  }

  Widget _leadingForTrigger(String? trigger) {
    const double size = 40;
    IconData icon = Icons.notifications;
    Color color = Colors.grey;
    switch (trigger) {
      case 'alarm':
        icon = Icons.warning_amber_rounded;
        color = Colors.red;
        break;
      case 'gas':
        icon = Icons.cloud;
        color = Colors.orange;
        break;
      case 'intruder':
        icon = Icons.person;
        color = Colors.deepPurple;
        break;
      case 'door':
        icon = Icons.meeting_room;
        color = Colors.blue;
        break;
      case 'auth':
        icon = Icons.lock_open;
        color = Colors.indigo;
        break;
      case 'temp':
        icon = Icons.thermostat;
        color = Colors.teal;
        break;
      case 'manual':
      default:
        icon = Icons.edit;
        color = Colors.grey;
    }
    return CircleAvatar(
      backgroundColor: color.withOpacity(0.15),
      radius: size / 2,
      child: Icon(icon, color: color, size: 20),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: AnimatedBuilder(
        animation: NotificationsService.instance,
        builder: (context, _) {
          final list = NotificationsService.instance.items;
          if (list.isEmpty) return const Center(child: Text('No notifications', style: TextStyle(fontSize: 16)));
          return ListView.separated(
            padding: const EdgeInsets.all(8),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, index) {
              final item = list[index];
              final timeLabel = _format12(item.time);
              final triggerLabel = (item.trigger ?? 'manual').toUpperCase();
              return ListTile(
                leading: _leadingForTrigger(item.trigger),
                title: Text(item.message),
                subtitle: Text('$timeLabel • $triggerLabel'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => _removeAt(index),
                  tooltip: 'Dismiss',
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addSample,
        tooltip: 'Add sample',
        child: const Icon(Icons.add),
      ),
    );
  }
}

