using System.Security.Cryptography;

var rsa = RSA.Create(2048);
var repoRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
var dir = Path.Combine(repoRoot, "desktop", "Pconnect.Agent", "Assets");
Directory.CreateDirectory(dir);
var pubPath = Path.Combine(dir, "opconfig-pub.pem");
var privPath = Path.Combine(dir, "opconfig-priv.pem");
File.WriteAllText(pubPath, rsa.ExportRSAPublicKeyPem());
File.WriteAllText(privPath, rsa.ExportRSAPrivateKeyPem());
Console.WriteLine("Wrote " + pubPath);
Console.WriteLine("Wrote " + privPath + " (gitignore — do not ship private in app)");
