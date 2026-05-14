using System.Security.Cryptography;
using System.Text;
using Pconnect.Agent.Services;
using Xunit;

namespace Pconnect.Agent.Tests;

public class CryptoGoldenTests
{
    [Fact]
    public void Hkdf_integrity_key_matches_shared_vector()
    {
        var ikm = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var salt = Enumerable.Range(0x40, 16).Select(i => (byte)i).ToArray();
        var sub = SessionKeyDerivation.DeriveSubkeys(ikm.AsSpan(), salt);
        try
        {
            var hex = Convert.ToHexString(sub.IntegrityKey);
            Assert.Equal("EA55716A99CF6B48D8D5129B256226A6F2464EFD7112B06D850A719C5F7EEC5B", hex, ignoreCase: true);
        }
        finally
        {
            sub.Dispose();
        }
    }

    [Fact]
    public void Hmac_matches_shared_vector()
    {
        var key = Convert.FromHexString("EA55716A99CF6B48D8D5129B256226A6F2464EFD7112B06D850A719C5F7EEC5B");
        using var h = new HMACSHA256(key);
        var mac = h.ComputeHash(Encoding.UTF8.GetBytes("1|shutdown|1326"));
        Assert.Equal("3nT4/roLH63Dd20w7/2x/aIh6PnNR9QHG9NcL/giUmI=", Convert.ToBase64String(mac));
    }

    [Fact]
    public void Command_integrity_roundtrip()
    {
        var tokenHex = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        var nonce = RandomNumberGenerator.GetBytes(16);
        var key = CommandIntegrity.TryDeriveIntegrityKey(tokenHex, nonce);
        Assert.NotNull(key);
        try
        {
            using var h = new HMACSHA256(key!);
            var macB64 = Convert.ToBase64String(h.ComputeHash(Encoding.UTF8.GetBytes("1|shutdown|x")));
            Assert.True(CommandIntegrity.TryVerifyMac(key!, 1, "shutdown|x", macB64));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key!);
        }
    }
}
