using System.Security.Cryptography;
using System.Text;

namespace Pconnect.Agent.Services;

/// <summary>
/// Deterministic HKDF-SHA256 subkey expansion for session material.
/// Wire when binary/authenticated frames are enabled: same labels on desktop and mobile.
/// </summary>
internal static class SessionKeyDerivation
{
    private const int KeyLen = 32;

    private static readonly byte[] InfoAuthB = Encoding.UTF8.GetBytes("pconnect/v1/auth");
    private static readonly byte[] InfoIntegrityB = Encoding.UTF8.GetBytes("pconnect/v1/integrity");
    private static readonly byte[] InfoFutureEncB = Encoding.UTF8.GetBytes("pconnect/v1/future-enc");
    private static readonly byte[] InfoClipboardB = Encoding.UTF8.GetBytes("pconnect/v1/clipboard");

    /// <summary>
    /// Derives four 256-bit subkeys. Zeros <paramref name="masterToken"/> after use; copies session nonce to a cleared buffer for HKDF.
    /// </summary>
    public static SessionSubkeys DeriveSubkeys(Span<byte> masterToken, ReadOnlySpan<byte> sessionNonce)
    {
        var ikm = masterToken.ToArray();
        var salt = sessionNonce.ToArray();
        CryptographicOperations.ZeroMemory(masterToken);
        try
        {
            var auth = HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, KeyLen, salt, InfoAuthB);
            var integrity = HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, KeyLen, salt, InfoIntegrityB);
            var futureEnc = HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, KeyLen, salt, InfoFutureEncB);
            var clipboard = HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, KeyLen, salt, InfoClipboardB);
            return new SessionSubkeys(auth, integrity, futureEnc, clipboard);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(ikm);
            CryptographicOperations.ZeroMemory(salt);
        }
    }

    /// <summary>
    /// On session reset / reconnect: dispose old subkeys, derive fresh with new nonce; never reuse (nonce, seq) pairs.
    /// </summary>
    public static void Rotate(ref SessionSubkeys keys, Span<byte> masterToken, ReadOnlySpan<byte> newSessionNonce)
    {
        keys.Dispose();
        keys = DeriveSubkeys(masterToken, newSessionNonce);
    }
}

/// <summary>Holds owned key buffers; call <see cref="Dispose"/> when session ends.</summary>
internal struct SessionSubkeys : IDisposable
{
    public byte[] AuthKey { get; }
    public byte[] IntegrityKey { get; }
    public byte[] FutureEncryptionKey { get; }
    public byte[] ClipboardKey { get; }

    public SessionSubkeys(byte[] authKey, byte[] integrityKey, byte[] futureEncryptionKey, byte[] clipboardKey)
    {
        AuthKey = authKey;
        IntegrityKey = integrityKey;
        FutureEncryptionKey = futureEncryptionKey;
        ClipboardKey = clipboardKey;
    }

    public readonly void Dispose()
    {
        Zero(AuthKey);
        Zero(IntegrityKey);
        Zero(FutureEncryptionKey);
        Zero(ClipboardKey);
    }

    private static void Zero(byte[]? buf)
    {
        if (buf is null) return;
        CryptographicOperations.ZeroMemory(buf.AsSpan());
    }
}
