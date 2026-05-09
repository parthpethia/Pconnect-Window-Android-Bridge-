using System.Runtime.InteropServices;

namespace Pconnect.Agent.Services;

/// <summary>
/// Sends media key presses (play/pause, next, prev, stop, mute, vol up/down)
/// using the keybd_event Win32 API with VK_MEDIA_* virtual key codes.
/// </summary>
internal static class MediaKeyService
{
    // Media virtual key codes
    private const byte VK_MEDIA_NEXT_TRACK = 0xB0;
    private const byte VK_MEDIA_PREV_TRACK = 0xB1;
    private const byte VK_MEDIA_STOP = 0xB2;
    private const byte VK_MEDIA_PLAY_PAUSE = 0xB3;
    private const byte VK_VOLUME_MUTE = 0xAD;
    private const byte VK_VOLUME_DOWN = 0xAE;
    private const byte VK_VOLUME_UP = 0xAF;

    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, nuint dwExtraInfo);

    /// <summary>
    /// Sends a media key press for the given key name.
    /// Returns true if the key was recognized and sent.
    /// </summary>
    public static bool Send(string key)
    {
        byte vk;
        switch (key.Trim().ToLowerInvariant())
        {
            case "play_pause":
                vk = VK_MEDIA_PLAY_PAUSE;
                break;
            case "next":
                vk = VK_MEDIA_NEXT_TRACK;
                break;
            case "prev":
                vk = VK_MEDIA_PREV_TRACK;
                break;
            case "stop":
                vk = VK_MEDIA_STOP;
                break;
            case "mute":
                vk = VK_VOLUME_MUTE;
                break;
            case "vol_up":
                vk = VK_VOLUME_UP;
                break;
            case "vol_down":
                vk = VK_VOLUME_DOWN;
                break;
            default:
                return false;
        }

        try
        {
            keybd_event(vk, 0, KEYEVENTF_EXTENDEDKEY, 0);
            keybd_event(vk, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0);
            return true;
        }
        catch
        {
            return false;
        }
    }
}
