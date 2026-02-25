# Run SSL check from work PC (behind Zscaler)

Run one of these **on your work computer** (where Zscaler runs) to see which certificate is being presented. That tells you if Zscaler is still seeing the Vercel fallback cert.

---

## Option A: Windows (PowerShell) – no file needed

1. On your work PC, open **PowerShell** (Windows key → type `PowerShell` → Enter).
2. Paste this and press Enter:

```powershell
$h="www.wewaitwell.com"; $t=New-Object Net.Sockets.TcpClient($h,443); $s=New-Object Net.Security.SslStream($t.GetStream(),$false,{$true}); $s.AuthenticateAsClient($h); $c=$s.RemoteCertificate; Write-Host "SUBJECT:" $c.Subject; Write-Host "ISSUER:" $c.Issuer; $s.Close(); $t.Close()
```

3. Check the output:
   - **SUBJECT** contains `no-sni.vercel-infra.com` → Zscaler is still seeing the fallback cert (fix: Cloudflare proxy ON + Full Strict).
   - **SUBJECT** contains `wewaitwell` → Your domain’s cert; Zscaler should accept (if browser still warns, it’s a different issue).

---

## Option B: Windows – run the script file

1. Copy `check-ssl-from-work.ps1` to your work PC (e.g. Downloads).
2. In PowerShell, go to that folder, e.g. `cd $env:USERPROFILE\Downloads`
3. Run:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; .\check-ssl-from-work.ps1
   ```

---

## Option C: Mac/Linux at work

In Terminal:

```bash
echo | openssl s_client -connect www.wewaitwell.com:443 -servername www.wewaitwell.com 2>/dev/null | openssl x509 -noout -subject -issuer
```

- **subject** = `CN=wewaitwell.com` (or similar) → correct cert.
- **subject** = `no-sni.vercel-infra.com` → fallback cert; enable Cloudflare proxy + Full Strict.

---

## What to do with the result

- Share the **SUBJECT** and **ISSUER** lines if you need help.
- If you see **no-sni.vercel-infra.com**: turn Cloudflare proxy ON (orange cloud) for both `wewaitwell.com` and `www` records, and set SSL/TLS to **Full (Strict)**.
- If you see **wewaitwell.com** but the browser still warns: possible Zscaler SSL inspection or custom block; IT may need to allow the site or adjust inspection.
