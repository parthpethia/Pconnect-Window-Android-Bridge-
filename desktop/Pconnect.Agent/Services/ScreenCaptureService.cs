using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.Versioning;

namespace Pconnect.Agent.Services;

/// <summary>
/// Captures the primary screen at a configurable interval, resizes to a thumbnail,
/// and JPEG-compresses it for transmission over WebSocket.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class ScreenCaptureService : IDisposable
{
    private System.Threading.Timer? _timer;
    private readonly Action<string, int, int>? _onFrame; // base64, width, height
    private readonly object _gate = new();
    private bool _running;
    private int _intervalMs = 2000;
    private int _targetWidth = 720;
    private long _jpegQuality = 65L;

    public ScreenCaptureService(Action<string, int, int>? onFrame)
    {
        _onFrame = onFrame;
    }

    public void Start(int intervalMs = 1000, int? targetWidth = null, long? jpegQuality = null)
    {
        lock (_gate)
        {
            if (_running) return;
            _running = true;
            _intervalMs = Math.Max(300, intervalMs);
            if (targetWidth is > 0 and <= 1920) _targetWidth = targetWidth.Value;
            if (jpegQuality is > 0 and <= 100) _jpegQuality = jpegQuality.Value;
            _timer = new System.Threading.Timer(CaptureCallback, null, 0, _intervalMs);
        }
    }

    public void Stop()
    {
        lock (_gate)
        {
            _running = false;
            _timer?.Dispose();
            _timer = null;
        }
    }

    private void CaptureCallback(object? state)
    {
        lock (_gate)
        {
            if (!_running) return;
        }

        try
        {
            var (base64, width, height) = CaptureScreen();
            if (base64 != null)
            {
                _onFrame?.Invoke(base64, width, height);
            }
        }
        catch
        {
            // Fail silently — screen capture may not be available in some contexts
        }
    }

    private (string? base64, int width, int height) CaptureScreen()
    {
        try
        {
            var bounds = System.Windows.Forms.Screen.PrimaryScreen?.Bounds;
            if (bounds == null || bounds.Value.Width <= 0 || bounds.Value.Height <= 0)
            {
                return (null, 0, 0);
            }

            var screenWidth = bounds.Value.Width;
            var screenHeight = bounds.Value.Height;

            using var fullBitmap = new Bitmap(screenWidth, screenHeight);
            using (var g = Graphics.FromImage(fullBitmap))
            {
                g.CopyFromScreen(bounds.Value.Location, Point.Empty, bounds.Value.Size);
            }

            // Resize to target width with high quality
            var ratio = (double)_targetWidth / screenWidth;
            var targetHeight = (int)(screenHeight * ratio);

            using var thumbnail = new Bitmap(_targetWidth, targetHeight);
            using (var g = Graphics.FromImage(thumbnail))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.HighQuality;
                g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                g.CompositingQuality = System.Drawing.Drawing2D.CompositingQuality.HighQuality;
                g.DrawImage(fullBitmap, 0, 0, _targetWidth, targetHeight);
            }

            // Compress to JPEG
            using var ms = new MemoryStream();
            var codecInfo = GetJpegCodecInfo();
            if (codecInfo != null)
            {
                var encoderParams = new EncoderParameters(1);
                encoderParams.Param[0] = new EncoderParameter(Encoder.Quality, _jpegQuality);
                thumbnail.Save(ms, codecInfo, encoderParams);
            }
            else
            {
                thumbnail.Save(ms, ImageFormat.Jpeg);
            }

            var base64 = Convert.ToBase64String(ms.ToArray());
            return (base64, _targetWidth, targetHeight);
        }
        catch
        {
            return (null, 0, 0);
        }
    }

    private static ImageCodecInfo? GetJpegCodecInfo()
    {
        foreach (var codec in ImageCodecInfo.GetImageEncoders())
        {
            if (codec.FormatID == ImageFormat.Jpeg.Guid)
            {
                return codec;
            }
        }
        return null;
    }

    public void Dispose()
    {
        Stop();
    }
}
