using System.Runtime.Versioning;
using System.Windows.Forms;

namespace Pconnect.Agent.Services;

[SupportedOSPlatform("windows")]
internal sealed class ClipboardMonitor : IDisposable
{
    private readonly Action<string>? _onClipboardChanged;
    private string? _lastClipboardContent;
    private DateTime _lastChangeTime = DateTime.MinValue;
    private const int ThrottleMs = 100; // Prevent spam from rapid clipboard changes
    private bool _disposed;

    /// <summary>
    /// Creates a clipboard monitor that invokes a callback when the system clipboard text changes.
    /// </summary>
    public ClipboardMonitor(Action<string>? onClipboardChanged = null)
    {
        _onClipboardChanged = onClipboardChanged;
        try
        {
            // Initialize clipboard content
            _lastClipboardContent = GetClipboardText();
        }
        catch
        {
            // Fail silently if clipboard access fails
        }
    }

    /// <summary>
    /// Polls the system clipboard for changes. Call this periodically (e.g., 500ms timer).
    /// </summary>
    public void Poll()
    {
        if (_disposed) return;

        try
        {
            var now = DateTime.UtcNow;
            if ((now - _lastChangeTime).TotalMilliseconds < ThrottleMs)
            {
                return; // Throttle rapid changes
            }

            var currentContent = GetClipboardText();
            if (currentContent != _lastClipboardContent)
            {
                _lastClipboardContent = currentContent;
                _lastChangeTime = now;
                _onClipboardChanged?.Invoke(currentContent);
            }
        }
        catch
        {
            // Fail silently - clipboard can be locked by other processes
        }
    }

    /// <summary>
    /// Safely retrieves text from the system clipboard.
    /// </summary>
    private static string GetClipboardText()
    {
        try
        {
            if (Clipboard.ContainsText())
            {
                return Clipboard.GetText() ?? string.Empty;
            }
        }
        catch
        {
            // Clipboard may be in use by another process
        }

        return string.Empty;
    }

    public void Dispose()
    {
        _disposed = true;
    }
}
