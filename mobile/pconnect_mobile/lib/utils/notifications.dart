import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../main.dart';

/// Displays a mirrored Windows notification as an Android local notification.
Future<void> showMirroredNotification({
  required String appName,
  required String title,
  required String body,
}) async {
  const androidDetails = AndroidNotificationDetails(
    'pconnect_mirror',
    'PC Notifications',
    channelDescription: 'Mirrored notifications from your Windows PC',
    importance: Importance.high,
    priority: Priority.high,
  );

  const details = NotificationDetails(android: androidDetails);

  await flutterLocalNotificationsPlugin.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
    '$appName: $title',
    body,
    details,
  );
}
