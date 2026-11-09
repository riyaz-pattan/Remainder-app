import 'package:alarm/alarm.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('app.channel.shared.data');

class AlarmService {
  /// Flag to prevent the updateStream listener from reacting
  /// when WE are the ones stopping/scheduling alarms.
  static bool _isBusy = false;
  static bool get isBusy => _isBusy;

  static Future<void> init() async {
    await Alarm.init();
  }

  /// Schedule the next water reminder alarm.
  static Future<void> scheduleNextWaterReminder(String audioPath, {bool isInitialSetup = false}) async {
    _isBusy = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Determine the next alarm ID to avoid stopping the foreground service
      // before scheduling the new alarm, which causes Android to suspend the app.
      int currentAlarmId = prefs.getInt('current_alarm_id') ?? 42;
      int nextAlarmId = currentAlarmId == 42 ? 43 : 42;
      
      if (isInitialSetup) {
        // Just to be safe, when turning ON we use 42
        nextAlarmId = 42;
      }

      // Read preferences
      final startHour = prefs.getInt('start_time_hour') ?? 8;
      final startMinute = prefs.getInt('start_time_minute') ?? 0;
      final endHour = prefs.getInt('end_time_hour') ?? 20;
      final endMinute = prefs.getInt('end_time_minute') ?? 0;
      final intervalMinutes = prefs.getInt('reminder_interval_minutes') ?? 60;
      
      final activeDaysStr = prefs.getString('active_days') ?? '1,2,3,4,5,6,7';
      final activeDays = activeDaysStr.split(',').map((e) => int.tryParse(e) ?? 1).toList();

      final now = DateTime.now();
      DateTime next = now.add(Duration(minutes: intervalMinutes));

      if (isInitialSetup) {
        final todayStart = DateTime(now.year, now.month, now.day, startHour, startMinute);
        if (now.isBefore(todayStart)) {
          next = todayStart;
        }
      }

      // Find the next valid time window (check up to 8 days ahead)
      for (int i = 0; i < 8; i++) {
        final dayStart = DateTime(next.year, next.month, next.day, startHour, startMinute);
        final dayEnd = DateTime(next.year, next.month, next.day, endHour, endMinute);
        
        if (!activeDays.contains(next.weekday)) {
          next = DateTime(next.year, next.month, next.day + 1, startHour, startMinute);
          continue;
        }
        
        if (next.isBefore(dayStart)) {
          next = dayStart;
          break;
        } else if (next.isAfter(dayEnd)) {
          next = DateTime(next.year, next.month, next.day + 1, startHour, startMinute);
          continue;
        } else {
          break;
        }
      }

      // Ensure the alarm time is in the future (at least 5 seconds from now)
      final nowAgain = DateTime.now();
      if (next.isBefore(nowAgain.add(const Duration(seconds: 5)))) {
        next = nowAgain.add(const Duration(seconds: 5));
      }

      print('AlarmService: Scheduling next alarm (ID $nextAlarmId) for $next');

      final alarmSettings = AlarmSettings(
        id: nextAlarmId,
        dateTime: next,
        assetAudioPath: audioPath,
        loopAudio: true,
        vibrate: true,
        warningNotificationOnKill: false,
        androidStopAlarmOnTermination: false,
        volumeSettings: VolumeSettings.fade(
          volume: 1.0,
          fadeDuration: const Duration(seconds: 3),
          volumeEnforced: true,
        ),
        notificationSettings: const NotificationSettings(
          title: 'Time to drink water!',
          body: 'Tap to open and confirm you drank water.',
          stopButton: 'Stop Alarm',
        ),
        androidFullScreenIntent: true,
      );
      
      // Schedule the next alarm FIRST
      await Alarm.set(alarmSettings: alarmSettings);
      print('AlarmService: ✅ Alarm set for $next');
      
      // Save the new current ID
      await prefs.setInt('current_alarm_id', nextAlarmId);
      
      // Now stop the old alarms safely without losing foreground priority too early!
      if (!isInitialSetup) {
        try {
          await Alarm.stop(currentAlarmId);
        } catch (e) {
          print('AlarmService: stop existing alarm: $e');
        }
      } else {
        // Just in case
        try { await Alarm.stop(42); } catch (_) {}
        try { await Alarm.stop(43); } catch (_) {}
      }
      
    } catch (e) {
      print('AlarmService: ❌ Alarm scheduling FAILED: $e');
    } finally {
      // Keep busy for a moment to let any async updateStream events pass
      await Future.delayed(const Duration(milliseconds: 500));
      _isBusy = false;
    }
  }

  /// Cancel all water reminders completely (user turned off reminders).
  static Future<void> cancelWaterReminders() async {
    _isBusy = true;
    try {
      try { await Alarm.stop(42); } catch (_) {}
      try { await Alarm.stop(43); } catch (_) {}
    } catch (e) {
      print('AlarmService: cancel alarm error: $e');
    } finally {
      await Future.delayed(const Duration(milliseconds: 500));
      _isBusy = false;
    }
  }

  /// Stop the current alarm AND schedule the next one.
  /// Called when user dismisses alarm from the AlarmRingScreen.
  static Future<void> stopAndScheduleNext() async {
    final prefs = await SharedPreferences.getInstance();
    final isEnabled = prefs.getBool('reminders_enabled') ?? false;
    final audio = prefs.getString('custom_audio_path');

    print('AlarmService: stopAndScheduleNext - enabled=$isEnabled, hasAudio=${audio != null}');

    if (isEnabled && audio != null) {
      // scheduleNextWaterReminder already stops the current alarm first
      await scheduleNextWaterReminder(audio);
      print('AlarmService: ✅ Next alarm scheduled after dismissal');
    } else {
      // Just stop, don't reschedule
      await cancelWaterReminders();
    }
  }

  /// Called when the alarm is stopped from OUTSIDE our code
  /// (e.g. the notification "Stop Alarm" button).
  /// This schedules the next alarm to keep the chain going.
  static Future<void> handleExternalAlarmStop() async {
    if (_isBusy) {
      print('AlarmService: handleExternalAlarmStop - ignoring (busy)');
      return;
    }
    
    final prefs = await SharedPreferences.getInstance();
    final isEnabled = prefs.getBool('reminders_enabled') ?? false;
    final audio = prefs.getString('custom_audio_path');

    print('AlarmService: handleExternalAlarmStop - enabled=$isEnabled, hasAudio=${audio != null}');

    if (isEnabled && audio != null) {
      await scheduleNextWaterReminder(audio);
      print('AlarmService: ✅ Next alarm scheduled after external stop');
    }
  }

  /// Check full-screen intent permission (Android 14+).
  static Future<bool> checkFullScreenIntentPermission() async {
    try {
      final result = await _channel.invokeMethod('checkFullScreenIntentPermission');
      return result as bool? ?? true;
    } catch (e) {
      return true;
    }
  }

  /// Open system settings for full-screen intent permission.
  static Future<void> openFullScreenIntentSettings() async {
    try {
      await _channel.invokeMethod('openFullScreenIntentSettings');
    } catch (e) {
      print('AlarmService: open FSI settings error: $e');
    }
  }

  /// Open system settings for display over other apps (overlay) permission.
  static Future<void> openOverlaySettings() async {
    try {
      await _channel.invokeMethod('openOverlaySettings');
    } catch (e) {
      print('AlarmService: open overlay settings error: $e');
    }
  }
}
