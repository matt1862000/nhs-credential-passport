# Run this on your WORK PC (behind Zscaler) in PowerShell to see which cert Zscaler sees.
# Right-click PowerShell -> Run as needed, then: cd to folder, then: .\check-ssl-from-work.ps1

$HostName = "www.wewaitwell.com"
$Port = 443

Write-Host "=== SSL check from this machine (through Zscaler) ===" -ForegroundColor Cyan
Write-Host "Host: $HostName`n" -ForegroundColor Cyan

try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient($HostName, $Port)
    $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, { $true })
    $sslStream.AuthenticateAsClient($HostName)
    $cert = $sslStream.RemoteCertificate
    $sslStream.Close()
    $tcpClient.Close()

    $subject = $cert.Subject
    $issuer = $cert.Issuer

    Write-Host "Certificate SUBJECT (CN): " -NoNewline
    Write-Host $subject -ForegroundColor Yellow
    Write-Host "Certificate ISSUER:        " -NoNewline
    Write-Host $issuer -ForegroundColor Yellow
    Write-Host ""

    if ($subject -match "no-sni\.vercel-infra\.com") {
        Write-Host "Result: Zscaler is seeing Vercel FALLBACK cert - that's what it flags." -ForegroundColor Red
        Write-Host "Fix: Enable Cloudflare proxy (orange cloud) + SSL Full (Strict) for wewaitwell.com" -ForegroundColor Red
    } elseif ($subject -match "wewaitwell") {
        Write-Host "Result: Correct cert (wewaitwell.com) - Zscaler should accept. If browser still warns, it may be a different issue." -ForegroundColor Green
    } else {
        Write-Host "Result: Cert CN is: $subject - check if this is expected (e.g. Cloudflare)." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host "Possible: firewall, Zscaler block, or TLS failure. Try in browser: https://$HostName" -ForegroundColor Yellow
}

Write-Host "`nDone. Share the SUBJECT/ISSUER lines if you need help." -ForegroundColor Gray
