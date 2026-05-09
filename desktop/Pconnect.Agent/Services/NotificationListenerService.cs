using System.Text.Json;
using Windows.UI.Notifications;
using Windows.UI.Notifications.Management;

namespace Pconnect.Agent.Services;

/// <summary>
/// Listens for Windows toast notifications and forwards them to the connected mobile device.
/// Requires Windows 10 build 17763+ and user consent via Settings → Notifications → Notification access.
/// </summary>
internal sealed class NotificationListenerService
{
    private readonly Func<string, Task> _sendMessage;
    private readonly AuditLogService _auditLog;
    private UserNotificationListener? _listener;

    public NotificationListenerService(Func<string, Task> sendMessage, AuditLogService auditLog)
    {
        _sendMessage = sendMessage;
        _auditLog = auditLog;
    }

    /// <summary>
    /// Requests notification listener access from Windows.
    /// Returns true only if the user has granted access.
    /// </summary>
    public async Task<bool> RequestAccessAsync()
    {
        try
        {
            _listener = UserNotificationListener.Current;
            var status = await _listener.RequestAccessAsync();
            return status == UserNotificationListenerAccessStatus.Allowed;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[NotificationListener] RequestAccessAsync failed: {ex.Message}");
            _listener = null;
            return false;
        }
    }

    /// <summary>
    /// Subscribes to the NotificationChanged event. Call after RequestAccessAsync returns true.
    /// </summary>
    public void Start()
    {
        if (_listener is null) return;
        _listener.NotificationChanged += OnNotificationChanged;
        Console.WriteLine("[NotificationListener] Started listening for notifications.");
    }

    /// <summary>
    /// Unsubscribes from the NotificationChanged event.
    /// </summary>
    public void Stop()
    {
        if (_listener is null) return;
        try
        {
            _listener.NotificationChanged -= OnNotificationChanged;
        }
        catch { /* ignore */ }
        Console.WriteLine("[NotificationListener] Stopped.");
    }

    private async void OnNotificationChanged(UserNotificationListener sender, UserNotificationChangedEventArgs args)
    {
        try
        {
            if (args.ChangeKind != UserNotificationChangedKind.Added)
                return;

            var notification = sender.GetNotification(args.UserNotificationId);
            if (notification is null) return;

            var visual = notification.Notification?.Visual;
            if (visual is null) return;

            var binding = visual.GetBinding(KnownNotificationBindings.ToastGeneric);
            if (binding is null) return;

            var elements = binding.GetTextElements();
            string? title = elements.Count > 0 ? elements[0].Text : null;
            string? body = elements.Count > 1 ? elements[1].Text : null;

            if (string.IsNullOrWhiteSpace(title) && string.IsNullOrWhiteSpace(body))
                return;

            string appName;
            try
            {
                appName = notification.AppInfo?.DisplayInfo?.DisplayName ?? "Unknown";
            }
            catch
            {
                appName = "Unknown";
            }

            var payload = JsonSerializer.Serialize(new
            {
                v = 1,
                type = "notification",
                title = title ?? "",
                body = body ?? "",
                appName
            });

            await _sendMessage(payload);
            _auditLog.Log("system", $"notification:{appName} – {title}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[NotificationListener] OnNotificationChanged error: {ex.Message}");
        }
    }
}
