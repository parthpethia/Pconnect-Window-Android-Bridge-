using System.Security.Cryptography;
using System.Text.Json;

namespace Pconnect.Agent.Services;

internal sealed class FileTransferManager : IDisposable
{
    private sealed class ActiveTransfer
    {
        public string TempFilePath { get; set; } = string.Empty;
        public FileStream? FileStream { get; set; }
        public int TotalChunks { get; set; }
        public HashSet<int> ReceivedChunks { get; set; } = new();
        public long TotalBytes { get; set; }
        public long ReceivedBytes { get; set; }
        public DateTime LastActivity { get; set; } = DateTime.UtcNow;
        public string TargetPath { get; set; } = string.Empty;
    }

    private readonly Dictionary<string, ActiveTransfer> _activeTransfers = new();
    private readonly object _lock = new();
    private System.Threading.Timer? _cleanupTimer;

    public FileTransferManager()
    {
        // Cleanup abandoned transfers every 5 minutes
        _cleanupTimer = new System.Threading.Timer(_ => CleanupExpired(), null, TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(5));
    }

    /// <summary>
    /// Initiates a file transfer. Returns the target file path or null if invalid.
    /// </summary>
    public string? StartTransfer(string transferId, string filename, long size)
    {
        lock (_lock)
        {
            if (_activeTransfers.ContainsKey(transferId))
            {
                return null; // Transfer already exists
            }

            try
            {
                var tempFile = Path.GetTempFileName();
                var downloadFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
                var targetPath = Path.Combine(downloadFolder, SanitizeFilename(filename));

                // Ensure Downloads folder exists
                Directory.CreateDirectory(downloadFolder);

                var transfer = new ActiveTransfer
                {
                    TempFilePath = tempFile,
                    TotalChunks = (int)Math.Ceiling((double)size / (50 * 1024)),
                    TotalBytes = size,
                    TargetPath = targetPath,
                    FileStream = new FileStream(tempFile, FileMode.Create, FileAccess.Write, FileShare.None, 64 * 1024)
                };

                _activeTransfers[transferId] = transfer;
                return transferId;
            }
            catch
            {
                return null;
            }
        }
    }

    /// <summary>
    /// Writes a chunk to the transfer. Returns true if successful.
    /// </summary>
    public bool WriteChunk(string transferId, int chunkIndex, byte[] data)
    {
        lock (_lock)
        {
            if (!_activeTransfers.TryGetValue(transferId, out var transfer))
            {
                return false;
            }

            try
            {
                if (transfer.FileStream == null)
                {
                    return false;
                }

                transfer.FileStream.Write(data, 0, data.Length);
                transfer.ReceivedChunks.Add(chunkIndex);
                transfer.ReceivedBytes += data.Length;
                transfer.LastActivity = DateTime.UtcNow;
                return true;
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>
    /// Completes a transfer and moves the temp file to the target location.
    /// </summary>
    public bool CompleteTransfer(string transferId)
    {
        lock (_lock)
        {
            if (!_activeTransfers.TryGetValue(transferId, out var transfer))
            {
                return false;
            }

            try
            {
                transfer.FileStream?.Dispose();
                transfer.FileStream = null;

                // Verify file completeness by checking actual file size
                var actualSize = new FileInfo(transfer.TempFilePath).Length;
                if (actualSize != transfer.TotalBytes)
                {
                    File.Delete(transfer.TempFilePath);
                    _activeTransfers.Remove(transferId);
                    return false;
                }

                // Move temp file to target
                if (File.Exists(transfer.TargetPath))
                {
                    File.Delete(transfer.TargetPath);
                }

                File.Move(transfer.TempFilePath, transfer.TargetPath);
                _activeTransfers.Remove(transferId);
                return true;
            }
            catch
            {
                try
                {
                    File.Delete(transfer.TempFilePath);
                }
                catch { }

                _activeTransfers.Remove(transferId);
                return false;
            }
        }
    }

    /// <summary>
    /// Aborts a transfer and cleans up temp file.
    /// </summary>
    public void AbortTransfer(string transferId)
    {
        lock (_lock)
        {
            if (_activeTransfers.TryGetValue(transferId, out var transfer))
            {
                try
                {
                    transfer.FileStream?.Dispose();
                    if (File.Exists(transfer.TempFilePath))
                    {
                        File.Delete(transfer.TempFilePath);
                    }
                }
                catch { }

                _activeTransfers.Remove(transferId);
            }
        }
    }

    /// <summary>
    /// Gets transfer progress, or null if not found.
    /// </summary>
    public (long received, long total, int chunkCount)? GetProgress(string transferId)
    {
        lock (_lock)
        {
            if (_activeTransfers.TryGetValue(transferId, out var transfer))
            {
                return (transfer.ReceivedBytes, transfer.TotalBytes, transfer.ReceivedChunks.Count);
            }

            return null;
        }
    }

    private void CleanupExpired()
    {
        lock (_lock)
        {
            var expired = _activeTransfers
                .Where(kvp => DateTime.UtcNow.Subtract(kvp.Value.LastActivity).TotalMinutes > 15)
                .ToList();

            foreach (var (id, transfer) in expired)
            {
                try
                {
                    transfer.FileStream?.Dispose();
                    if (File.Exists(transfer.TempFilePath))
                    {
                        File.Delete(transfer.TempFilePath);
                    }
                }
                catch { }

                _activeTransfers.Remove(id);
            }
        }
    }

    private static string SanitizeFilename(string filename)
    {
        var invalidChars = Path.GetInvalidFileNameChars();
        return string.Concat(filename.Split(invalidChars));
    }

    public void Dispose()
    {
        _cleanupTimer?.Dispose();

        lock (_lock)
        {
            foreach (var transfer in _activeTransfers.Values)
            {
                try
                {
                    transfer.FileStream?.Dispose();
                }
                catch { }
            }

            _activeTransfers.Clear();
        }
    }
}
