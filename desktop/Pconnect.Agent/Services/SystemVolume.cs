using System.Runtime.InteropServices;

namespace Pconnect.Agent.Services;

internal static class SystemVolume
{
    // CoreAudio endpoint volume: https://learn.microsoft.com/windows/win32/coreaudio/endpoint-volume-controls

    private const int CLSCTX_ALL = 0x17;

    private const int S_OK = 0;
    private const int S_FALSE = 1;
    private const int COINIT_MULTITHREADED = 0x0;

    // ReSharper disable once InconsistentNaming
    private enum EDataFlow
    {
        eRender = 0,
        eCapture = 1,
        eAll = 2,
    }

    // ReSharper disable once InconsistentNaming
    private enum ERole
    {
        eConsole = 0,
        eMultimedia = 1,
        eCommunications = 2,
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumerator
    {
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        IMMDevice GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        int Activate(ref Guid iid, int dwClsCtx, nint pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }

    [ComImport]
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume
    {
        // We only declare the members we need; order matters.
        int RegisterControlChangeNotify(nint pNotify);
        int UnregisterControlChangeNotify(nint pNotify);
        int GetChannelCount(out uint pnChannelCount);
        int SetMasterVolumeLevel(float fLevelDB, ref Guid pguidEventContext);
        int SetMasterVolumeLevelScalar(float fLevel, ref Guid pguidEventContext);
        int GetMasterVolumeLevel(out float pfLevelDB);
        int GetMasterVolumeLevelScalar(out float pfLevel);
        int SetChannelVolumeLevel(uint nChannel, float fLevelDB, ref Guid pguidEventContext);
        int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, ref Guid pguidEventContext);
        int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
        int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid pguidEventContext);
        int GetMute(out bool pbMute);
        int GetVolumeStepInfo(out uint pnStep, out uint pnStepCount);
        int VolumeStepUp(ref Guid pguidEventContext);
        int VolumeStepDown(ref Guid pguidEventContext);
        int QueryHardwareSupport(out uint pdwHardwareSupportMask);
        int GetVolumeRange(out float pflVolumeMindB, out float pflVolumeMaxdB, out float pflVolumeIncrementdB);
    }

    public static bool TrySetPercent(int level)
    {
        level = Math.Clamp(level, 0, 100);

        // CoreAudio COM objects are apartment-threaded (STA).
        // Kestrel request threads run in MTA, so we must dispatch onto
        // a dedicated STA thread to avoid COM marshalling failures.
        var success = false;
        var thread = new Thread(() =>
        {
            try
            {
                var scalar = level / 100f;

                static bool TrySetForRole(float scalar, ERole role)
                {
                    IMMDeviceEnumerator? enumerator = null;
                    IMMDevice? device = null;
                    object? obj = null;
                    try
                    {
                        enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
                        device = enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, role);

                        var iid = typeof(IAudioEndpointVolume).GUID;
                        var hr = device.Activate(ref iid, CLSCTX_ALL, nint.Zero, out obj);
                        if (hr != 0)
                        {
                            return false;
                        }

                        var endpoint = (IAudioEndpointVolume)obj;
                        var ctx = Guid.Empty;
                        hr = endpoint.SetMasterVolumeLevelScalar(scalar, ref ctx);
                        return hr == 0;
                    }
                    finally
                    {
                        if (obj is not null) Marshal.FinalReleaseComObject(obj);
                        if (device is not null) Marshal.FinalReleaseComObject(device);
                        if (enumerator is not null) Marshal.FinalReleaseComObject(enumerator);
                    }
                }

                // Try Multimedia first (common for media playback), then Console as a fallback.
                success = TrySetForRole(scalar, ERole.eMultimedia) || TrySetForRole(scalar, ERole.eConsole);
            }
            catch
            {
                success = false;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join(TimeSpan.FromSeconds(3));
        return success;
    }

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(nint pvReserved, int dwCoInit);

    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();
}
