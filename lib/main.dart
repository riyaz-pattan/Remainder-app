import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:alarm/alarm.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'services/alarm_service.dart';
import 'custom_toast.dart';
import 'custom_interval_picker.dart';

/// Global navigator key — allows navigation from main() before widgets are built.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Global key to access the home page state from main()
final GlobalKey<_ReminderHomePageState> reminderHomePageKey =
    GlobalKey<_ReminderHomePageState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AlarmService.init();



  Alarm.updateStream.stream.listen((alarmId) async {
    if ((alarmId == 42 || alarmId == 43) && !AlarmService.isBusy) {
      print('main: Alarm $alarmId stopped externally. Scheduling next...');
      await AlarmService.handleExternalAlarmStop();
      reminderHomePageKey.currentState?.externalAlarmStop();
    }
  });

  // Listen for alarm ring events globally.
  Alarm.ringStream.stream.listen((alarmSettings) {
    if (alarmSettings.id == 42 || alarmSettings.id == 43) {
      reminderHomePageKey.currentState?.externalAlarmRing();

      // Auto-stop after 1 minute if user hasn't responded
      Timer(const Duration(minutes: 1), () async {
        if (await Alarm.isRinging(42) || await Alarm.isRinging(43)) {
          print('main: Alarm ${alarmSettings.id} auto-stopped after 1 minute.');
          // Stop it and schedule the next one
          await AlarmService.handleExternalAlarmStop();
          reminderHomePageKey.currentState?.externalAlarmStop();
        }
      });
    }
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: "Water",
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFFF0F8FF),
      ),
      home: ReminderHomePage(key: reminderHomePageKey),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ReminderHomePage extends StatefulWidget {
  const ReminderHomePage({super.key});

  @override
  State<ReminderHomePage> createState() => _ReminderHomePageState();
}

class _ReminderHomePageState extends State<ReminderHomePage>
    with WidgetsBindingObserver {
  bool _isEnabled = false;
  bool _isRinging = false;

  void externalAlarmStop() {
    if (mounted) {
      setState(() => _isRinging = false);
    }
  }

  void externalAlarmRing() {
    if (mounted) {
      setState(() => _isRinging = true);
    }
  }

  String? _customAudioPath;
  late SharedPreferences _prefs;

  TimeOfDay _startTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _endTime = const TimeOfDay(hour: 20, minute: 0);
  int _intervalMinutes = 60;
  List<int> _activeDays = [1, 2, 3, 4, 5, 6, 7]; // 1=Mon, 7=Sun

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStatus();
    _checkPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-check alarms and FSI permission when the user returns to the app
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkFSIPermission();
      // Safety net: re-check if alarms need rescheduling
      _ensureAlarmScheduled();
    }
  }

  /// If reminders are enabled but no alarm is scheduled, reschedule.
  Future<void> _ensureAlarmScheduled() async {
    if (!_isEnabled || _customAudioPath == null) return;
    final alarms = await Alarm.getAlarms();
    if (alarms.isEmpty) {
      print('_ensureAlarmScheduled: No alarms found, rescheduling...');
      _scheduleNext();
    }
  }

  Future<void> _checkPermissions() async {
    // Request exact alarm and notification permissions
    await Permission.scheduleExactAlarm.request();
    await Permission.notification.request();

    // We use permission_handler because Android 11+ intentionally blocks direct deep linking
    // to the specific app's overlay toggle for security reasons.
    if (!await Permission.systemAlertWindow.isGranted) {
      await Permission.systemAlertWindow.request();
    }

    // Check full-screen intent permission (Android 14+)
    await _checkFSIPermission();
  }

  Future<void> _checkFSIPermission() async {
    final hasPermission = await AlarmService.checkFullScreenIntentPermission();
    if (!hasPermission && mounted) {
      _showFSIPermissionDialog();
    }
  }

  void _showFSIPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFF0066CC),
              size: 28,
            ),
            SizedBox(width: 10),
            Expanded(child: Text('Permission Required')),
          ],
        ),
        content: const Text(
          'To show the water reminder over your lock screen, '
          'please enable "Full-screen intents" for this app in Settings.\n\n'
          'Without this, you\'ll only see a notification instead of the full alarm screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              AlarmService.openFullScreenIntentSettings();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0066CC),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadStatus() async {
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      _isEnabled = _prefs.getBool('reminders_enabled') ?? false;
      _customAudioPath = _prefs.getString('custom_audio_path');

      _startTime = TimeOfDay(
        hour: _prefs.getInt('start_time_hour') ?? 8,
        minute: _prefs.getInt('start_time_minute') ?? 0,
      );
      _endTime = TimeOfDay(
        hour: _prefs.getInt('end_time_hour') ?? 20,
        minute: _prefs.getInt('end_time_minute') ?? 0,
      );
      _intervalMinutes = _prefs.getInt('reminder_interval_minutes') ?? 60;

      final activeDaysStr = _prefs.getString('active_days') ?? '1,2,3,4,5,6,7';
      _activeDays = activeDaysStr
          .split(',')
          .map((e) => int.tryParse(e) ?? 1)
          .toList();
    });

    final alarms = await Alarm.getAlarms();
    if (alarms.isEmpty && _isEnabled) {
      // It might have been cleared, let's schedule the next one
      _scheduleNext();
    }

    // Check if alarm is currently ringing (if app was opened while ringing)
    final isRinging = await Alarm.isRinging(42) || await Alarm.isRinging(43);
    if (mounted) {
      setState(() => _isRinging = isRinging);
    }
  }

  Future<void> _pickAudio() async {
    // Request storage permission first
    await Permission.storage.request();

    final result = await FilePicker.pickFiles(
      type: FileType.audio,
      allowMultiple: false,
    );

    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      setState(() => _customAudioPath = path);
      await _prefs.setString('custom_audio_path', path);

      if (!mounted) return;
      CustomToast.show(context, 'Custom alarm sound saved!');

      // If already enabled, restart alarm with new sound
      if (_isEnabled) {
        _scheduleNext();
      }
    }
  }

  Future<void> _pickTime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _startTime : _endTime,
    );
    if (picked != null) {
      setState(() {
        if (isStart)
          _startTime = picked;
        else
          _endTime = picked;
      });
      await _prefs.setInt(
        isStart ? 'start_time_hour' : 'end_time_hour',
        picked.hour,
      );
      await _prefs.setInt(
        isStart ? 'start_time_minute' : 'end_time_minute',
        picked.minute,
      );

      if (_isEnabled) _scheduleNext(isInitialSetup: true);
    }
  }

  List<DropdownMenuItem<int>> _getIntervalItems() {
    final items = <DropdownMenuItem<int>>[
      const DropdownMenuItem(value: 1, child: Text('1 Min')),
      const DropdownMenuItem(value: 15, child: Text('15 Mins')),
      const DropdownMenuItem(value: 30, child: Text('30 Mins')),
      const DropdownMenuItem(value: 60, child: Text('1 Hour')),
      const DropdownMenuItem(value: 120, child: Text('2 Hours')),
      const DropdownMenuItem(value: 180, child: Text('3 Hours')),
    ];

    // Add current custom value if it's not in the standard list
    if (![1, 15, 30, 60, 120, 180].contains(_intervalMinutes)) {
      final hours = _intervalMinutes ~/ 60;
      final mins = _intervalMinutes % 60;
      String text;
      if (_intervalMinutes < 60) {
        text = '$_intervalMinutes Mins';
      } else {
        text =
            '$hours Hour${hours > 1 ? 's' : ''}${mins > 0 ? ' $mins Mins' : ''}';
      }
      items.add(DropdownMenuItem(value: _intervalMinutes, child: Text(text)));
    }

    // Add Custom button
    items.add(const DropdownMenuItem(value: -1, child: Text('Custom...')));

    return items;
  }

  Future<void> _setInterval(int? minutes) async {
    if (minutes != null) {
      if (minutes == -1) {
        // Open custom picker
        final customMinutes = await showModalBottomSheet<int>(
          context: context,
          builder: (context) =>
              CustomIntervalPicker(initialMinutes: _intervalMinutes),
        );
        if (customMinutes != null) {
          setState(() => _intervalMinutes = customMinutes);
          await _prefs.setInt('reminder_interval_minutes', customMinutes);
          if (_isEnabled) _scheduleNext(isInitialSetup: true);
        }
      } else {
        setState(() => _intervalMinutes = minutes);
        await _prefs.setInt('reminder_interval_minutes', minutes);
        if (_isEnabled) _scheduleNext(isInitialSetup: true);
      }
    }
  }

  Future<void> _toggleDay(int day) async {
    setState(() {
      if (_activeDays.contains(day)) {
        if (_activeDays.length > 1) {
          // prevent disabling all days
          _activeDays.remove(day);
        } else {
          CustomToast.show(
            context,
            'You must keep at least one active day.',
            isError: true,
          );
        }
      } else {
        _activeDays.add(day);
      }
    });
    await _prefs.setString('active_days', _activeDays.join(','));
    if (_isEnabled) _scheduleNext(isInitialSetup: true);
  }

  Future<void> _scheduleNext({bool isInitialSetup = false}) async {
    if (_customAudioPath == null) {
      if (mounted) {
        CustomToast.show(
          context,
          'Please select a custom alarm sound first.',
          isError: true,
        );
      }
      return;
    }
    await AlarmService.scheduleNextWaterReminder(
      _customAudioPath!,
      isInitialSetup: isInitialSetup,
    );
  }

  Future<void> _toggleReminders() async {
    if (_isEnabled) {
      // DISABLE: Save preference FIRST (so updateStream listener won't reschedule)
      setState(() {
        _isEnabled = false;
        _isRinging = false;
      });
      await _prefs.setBool('reminders_enabled', false);
      await AlarmService.cancelWaterReminders();

      if (!mounted) return;
      CustomToast.show(context, 'Cancelled. Water reminders are off.');
    } else {
      // ENABLE: Check permissions only when enabling
      await _checkPermissions();

      // Ensure user has selected a custom sound
      if (_customAudioPath == null) {
        if (mounted) {
          CustomToast.show(
            context,
            'Please select a custom alarm sound first.',
            isError: true,
          );
        }
        return;
      }

      setState(() => _isEnabled = true);
      await _prefs.setBool('reminders_enabled', true);
      await _scheduleNext(isInitialSetup: true);

      if (!mounted) return;
      CustomToast.show(context, 'Success! Water reminders are active.');
    }
  }

  String _formatTime(TimeOfDay time) {
    final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    final min = time.minute.toString().padLeft(2, '0');
    final period = time.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$min $period';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/icon.png'),
            fit: BoxFit.cover,
          ),
        ),
        child: Container(
          // Darker overlay so the white glass card pops
          color: Colors.black.withOpacity(0.3),
          child: SafeArea(
            child: Column(
              children: [
                if (_isRinging)
                  Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.alarm_on,
                              color: Color(0xFF0066CC),
                              size: 32,
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                "Alarm Playing",
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0066CC),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: () async {
                            await AlarmService.stopAndScheduleNext();
                            setState(() => _isRinging = false);
                          },
                          icon: const Icon(Icons.water_drop),
                          label: const Text(
                            "STOP & I DRANK WATER",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0066CC),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 24,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(32),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 20.0, sigmaY: 20.0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24.0,
                            vertical: 48.0,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(32),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.3),
                              width: 1.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 30,
                                spreadRadius: -5,
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Icon(
                                Icons.water_drop,
                                size: 60,
                                color: Colors.white,
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                "Water",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 36,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _isEnabled
                                    ? 'Alarms Active\n(8 AM - 8 PM)'
                                    : 'Alarms Off',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white.withOpacity(0.9),
                                ),
                              ),
                              const SizedBox(height: 48),
                              ElevatedButton(
                                onPressed: _toggleReminders,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _isEnabled
                                      ? Colors.white
                                      : const Color(0xFF0066CC),
                                  foregroundColor: _isEnabled
                                      ? const Color(0xFF0066CC)
                                      : Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 20,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  elevation: 10,
                                  shadowColor: Colors.black.withOpacity(0.3),
                                ),
                                child: Text(
                                  _isEnabled
                                      ? 'TURN OFF REMINDERS'
                                      : 'TURN ON REMINDERS',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 32),
                              // --- Settings Panel ---
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.2),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      "Schedule Settings",
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 16),

                                    // Time Range
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: _buildSettingButton(
                                            "From",
                                            _formatTime(_startTime),
                                            Icons.schedule,
                                            () => _pickTime(true),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: _buildSettingButton(
                                            "To",
                                            _formatTime(_endTime),
                                            Icons.schedule,
                                            () => _pickTime(false),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),

                                    // Interval Dropdown
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Icon(
                                            Icons.timer,
                                            color: Colors.white70,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 8),
                                          const Expanded(
                                            child: Text(
                                              "Remind Every",
                                              style: TextStyle(
                                                color: Colors.white70,
                                                fontSize: 14,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          DropdownButton<int>(
                                            value: _intervalMinutes,
                                            dropdownColor: const Color(
                                              0xFF0066CC,
                                            ),
                                            iconEnabledColor: Colors.white,
                                            underline: const SizedBox(),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                            items: _getIntervalItems(),
                                            onChanged: _setInterval,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 16),

                                    // Days of week
                                    const Text(
                                      "Active Days",
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        _buildDayToggle(1, 'M'),
                                        _buildDayToggle(2, 'T'),
                                        _buildDayToggle(3, 'W'),
                                        _buildDayToggle(4, 'T'),
                                        _buildDayToggle(5, 'F'),
                                        _buildDayToggle(6, 'S'),
                                        _buildDayToggle(7, 'S'),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              // ------------------------
                              const SizedBox(height: 32),
                              OutlinedButton.icon(
                                onPressed: _pickAudio,
                                icon: const Icon(Icons.audio_file),
                                label: Text(
                                  _customAudioPath != null
                                      ? "Song: ${_customAudioPath!.split('/').last}"
                                      : 'Select Custom Sound',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 16),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 18,
                                  ),
                                  side: BorderSide(
                                    color: Colors.white.withOpacity(0.5),
                                    width: 1.5,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingButton(
    String label,
    String value,
    IconData icon,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.2),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Colors.white70, size: 16),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDayToggle(int day, String label) {
    final isActive = _activeDays.contains(day);
    return GestureDetector(
      onTap: () => _toggleDay(day),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isActive ? Colors.white : Colors.white.withOpacity(0.1),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: isActive ? const Color(0xFF0066CC) : Colors.white70,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------
// This is the full-screen alarm screen that pops up when the alarm rings.
// It also has a Dart-level auto-stop as a fallback.
// The PRIMARY auto-stop is handled natively via AndroidAlarmManager.
// -------------------------------------------------------------
class AlarmRingScreen extends StatefulWidget {
  const AlarmRingScreen({super.key});

  @override
  State<AlarmRingScreen> createState() => _AlarmRingScreenState();
}

class _AlarmRingScreenState extends State<AlarmRingScreen> {
  Timer? _autoStopTimer;

  @override
  void initState() {
    super.initState();
    // Auto-stop after 2 minutes as a safety net.
    // If the user doesn't dismiss the alarm, it will auto-dismiss
    // and schedule the next one.
    _autoStopTimer = Timer(const Duration(minutes: 2), () {
      if (mounted) {
        _drankWater(context);
      }
    });
  }

  @override
  void dispose() {
    _autoStopTimer?.cancel();
    super.dispose();
  }

  Future<void> _drankWater(BuildContext context) async {
    print('_drankWater: User tapped I DRANK WATER');

    // Stop the current alarm AND schedule the next one in a single call.
    await AlarmService.stopAndScheduleNext();
    print('_drankWater: Alarm stopped and next scheduled');

    // Close this full-screen alert
    if (context.mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0066CC),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.water_drop, size: 150, color: Colors.white),
              const SizedBox(height: 40),
              const Text(
                "Time to Drink Water!",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 60),
              ElevatedButton(
                onPressed: () => _drankWater(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF0066CC),
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                  elevation: 10,
                ),
                child: const Text(
                  'I DRANK WATER!',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
