using System.Security.Cryptography;
using System.Text;

// One-shot: dotnet run --project tools/CryptoGoldenDump
var ikm = Convert.FromHexString("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
var salt = Convert.FromHexString("404142434445464748494a4b4c4d4e4f");
var info = Encoding.UTF8.GetBytes("pconnect/v1/integrity");
var integrity = HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, 32, salt, info);
Console.WriteLine("integrity_key_hex=" + Convert.ToHexString(integrity));

using var h = new HMACSHA256(integrity);
var mac = h.ComputeHash(Encoding.UTF8.GetBytes("1|shutdown|1326"));
Console.WriteLine("hmac_b64=" + Convert.ToBase64String(mac));
