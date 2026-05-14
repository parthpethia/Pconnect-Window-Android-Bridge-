using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

if (args.Length < 3)
{
    Console.WriteLine("Usage: SignOpConfig <payload.json> <opconfig-priv.pem> <output-operational.json>");
    return 1;
}

var payloadUtf8 = await File.ReadAllTextAsync(args[0]);
var privPem = await File.ReadAllTextAsync(args[1]);
using var rsa = RSA.Create();
rsa.ImportFromPem(privPem);
var payloadBytes = Encoding.UTF8.GetBytes(payloadUtf8.Trim());
var sig = rsa.SignData(payloadBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
var doc = new
{
    payloadB64 = Convert.ToBase64String(payloadBytes),
    sig = Convert.ToBase64String(sig),
};
await File.WriteAllTextAsync(args[2], JsonSerializer.Serialize(doc, new JsonSerializerOptions { WriteIndented = true }));
Console.WriteLine("Wrote " + args[2]);
return 0;
