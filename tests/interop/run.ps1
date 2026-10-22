#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Runs the HTTP/2 and HTTP/3 interoperability matrix.

.DESCRIPTION
    Exercises the Zig implementation against independent implementations in
    both directions:

      * Python `h2` client  -> Zig HTTP/2 server
      * Zig HTTP/2 client   -> Python `h2` server
      * Python `aioquic`    -> Zig HTTP/3 server
      * Zig HTTP/3 client   -> Python `aioquic` server

    Each case covers a small response, a request/response echo, a 256 KiB
    flow-controlled body, and `:authority` propagation. Servers are killed
    when a case finishes; logs stay in .zig-cache/interop for diagnosis.

.PARAMETER Python
    Python 3 executable with `h2` (and `aioquic` unless `-SkipHttp3`).
    Defaults to $env:HTTPX_INTEROP_PYTHON, then .venv, then `python` on PATH.

.PARAMETER SkipBuild
    Reuse the binaries already installed in zig-out/bin.

.PARAMETER SkipHttp3
    Run only the HTTP/2 matrix. Use this when `aioquic` is unavailable; `h2`
    is still required.
#>
[CmdletBinding()]
param(
    [string]$Python = $env:HTTPX_INTEROP_PYTHON,
    [switch]$SkipBuild,
    [switch]$SkipHttp3
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$bin = Join-Path $root "zig-out\bin"
$logDir = Join-Path $root ".zig-cache\interop"
$cert = "src/protocols/tls/testdata/localhostCert.pem"
$key = "src/protocols/tls/testdata/localhostKey.pem"
$exeSuffix = if ($IsWindows -or $env:OS -eq "Windows_NT") { ".exe" } else { "" }

Push-Location $root
try {
    if (-not $Python) {
        $venv = Join-Path $root ".venv"
        $candidates = @(
            (Join-Path $venv "Scripts\python.exe"),
            (Join-Path $venv "bin\python"),
            "python",
            "python3"
        )
        foreach ($candidate in $candidates) {
            if ($candidate -eq "python" -or $candidate -eq "python3") {
                $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
                if ($cmd) { $Python = $cmd.Source; break }
            } elseif (Test-Path $candidate) {
                $Python = $candidate
                break
            }
        }
    }
    if (-not $Python) {
        throw "No Python found. Install h2 and aioquic, then pass -Python <path>."
    }
    $imports = if ($SkipHttp3) { "import h2" } else { "import h2, aioquic" }
    & $Python -c $imports 2>$null
    if ($LASTEXITCODE -ne 0) {
        $required = if ($SkipHttp3) { "h2==4.4.1" } else { "h2==4.4.1 aioquic==1.7.0" }
        throw "$Python is missing the test dependencies. Run: $Python -m pip install $required"
    }

    if (-not $SkipBuild) {
        & zig build interop
        if ($LASTEXITCODE -ne 0) { throw "zig build interop failed" }
    }

    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    $zigH2 = Join-Path $bin "interop-h2-server$exeSuffix"
    $zigH3 = Join-Path $bin "interop-h3-server$exeSuffix"
    $zigClient = Join-Path $bin "interop-client$exeSuffix"
    $requiredBinaries = if ($SkipHttp3) { @($zigH2, $zigClient) } else { @($zigH2, $zigH3, $zigClient) }
    foreach ($exe in $requiredBinaries) {
        if (-not (Test-Path $exe)) { throw "missing $exe (run without -SkipBuild)" }
    }

    $script:Checks = 0

    function Start-TestServer {
        param(
            [string]$FilePath,
            [string[]]$ArgumentList,
            [string]$Name
        )
        $stdout = Join-Path $logDir "$Name.out.log"
        $stderr = Join-Path $logDir "$Name.err.log"
        Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue
        $startParams = @{
            FilePath               = $FilePath
            WorkingDirectory       = $root
            RedirectStandardOutput = $stdout
            RedirectStandardError  = $stderr
            PassThru               = $true
            NoNewWindow            = $true
        }
        if ($ArgumentList -and $ArgumentList.Count -gt 0) {
            $startParams.ArgumentList = $ArgumentList
        }
        $process = Start-Process @startParams
        return [pscustomobject]@{
            Process = $process
            Stdout  = $stdout
            Stderr  = $stderr
            Name    = $Name
        }
    }

    function Stop-TestServer {
        param($Server)
        if ($null -eq $Server) { return }
        if (-not $Server.Process.HasExited) {
            Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $Server.Process.Id -Timeout 5 -ErrorAction SilentlyContinue
        }
    }

    function Wait-Listen {
        param($Server, [int]$TimeoutSeconds = 25)
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            foreach ($path in @($Server.Stdout, $Server.Stderr)) {
                if (Test-Path $path) {
                    $text = Get-Content -Raw -ErrorAction SilentlyContinue $path
                    if ($text -match "LISTEN (\d+)(?: (\d+))?") {
                        return [pscustomobject]@{
                            Tcp = [int]$Matches[1]
                            Udp = if ($Matches[2]) { [int]$Matches[2] } else { $null }
                        }
                    }
                }
            }
            if ($Server.Process.HasExited) {
                $err = Get-Content -Raw -ErrorAction SilentlyContinue $Server.Stderr
                throw "$($Server.Name) exited before listening: $err"
            }
            Start-Sleep -Milliseconds 100
        }
        throw "timed out waiting for $($Server.Name) to listen"
    }

    function Invoke-Check {
        param(
            [string]$Name,
            [string]$FilePath,
            [string[]]$ArgumentList
        )
        Write-Host "==> $Name"
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "$Name failed (exit $LASTEXITCODE)"
        }
        $script:Checks++
    }

    # --- Python h2 client -> Zig HTTP/2 server -------------------------
    $server = $null
    try {
        $server = Start-TestServer $zigH2 @("0") "zig-h2"
        $listen = Wait-Listen $server
        $port = $listen.Tcp
        $authority = "127.0.0.1:$port"
        Invoke-Check "h2 python->zig GET /hello" $Python @(
            "tests/interop/h2_client.py", "--port", "$port",
            "--path", "/hello", "--expect", "hello-from-zig-h2")
        Invoke-Check "h2 python->zig POST /echo" $Python @(
            "tests/interop/h2_client.py", "--port", "$port", "--method", "POST",
            "--path", "/echo", "--body", "python-h2-echo",
            "--expect", "python-h2-echo")
        Invoke-Check "h2 python->zig GET /large" $Python @(
            "tests/interop/h2_client.py", "--port", "$port",
            "--path", "/large", "--expect", "unused", "--expect-gen", "large")
        Invoke-Check "h2 python->zig GET /host" $Python @(
            "tests/interop/h2_client.py", "--port", "$port",
            "--path", "/host", "--expect", $authority)
    } finally {
        Stop-TestServer $server
    }

    # --- Zig HTTP/2 client -> Python h2 server -------------------------
    $server = $null
    try {
        $server = Start-TestServer $Python @("tests/interop/h2_server.py", "--port", "0") "python-h2"
        $listen = Wait-Listen $server
        $port = $listen.Tcp
        $url = "http://127.0.0.1:$port"
        $authority = "127.0.0.1:$port"
        Invoke-Check "h2 zig->python GET /hello" $zigClient @(
            "h2", "GET", "$url/hello", "hello-from-python-h2", "-", "-")
        Invoke-Check "h2 zig->python POST /echo" $zigClient @(
            "h2", "POST", "$url/echo", "zig-h2-echo", "-", "zig-h2-echo")
        Invoke-Check "h2 zig->python GET /large" $zigClient @(
            "h2", "GET", "$url/large", "@large", "-", "-")
        Invoke-Check "h2 zig->python GET /host" $zigClient @(
            "h2", "GET", "$url/host", $authority, "-", "-")
    } finally {
        Stop-TestServer $server
    }

    if (-not $SkipHttp3) {
    # --- Python aioquic client -> Zig HTTP/3 server --------------------
    $server = $null
    try {
        $server = Start-TestServer $zigH3 @() "zig-h3"
        $listen = Wait-Listen $server
        if (-not $listen.Udp) { throw "Zig HTTP/3 server did not report a UDP port" }
        $port = $listen.Udp
        $authority = "127.0.0.1:$port"
        Invoke-Check "h3 python->zig GET /hello" $Python @(
            "tests/interop/h3_client.py", "--port", "$port",
            "--path", "/hello", "--expect", "hello-from-zig-h3", "--ca", $cert)
        Invoke-Check "h3 python->zig POST /echo" $Python @(
            "tests/interop/h3_client.py", "--port", "$port", "--method", "POST",
            "--path", "/echo", "--body", "python-h3-echo",
            "--expect", "python-h3-echo", "--ca", $cert)
        Invoke-Check "h3 python->zig GET /host" $Python @(
            "tests/interop/h3_client.py", "--port", "$port",
            "--path", "/host", "--expect", $authority, "--ca", $cert)
    } finally {
        Stop-TestServer $server
    }

    # --- Zig HTTP/3 client -> Python aioquic server --------------------
    $server = $null
    try {
        $server = Start-TestServer $Python @(
            "tests/interop/h3_server.py", "--port", "0",
            "--cert", $cert, "--key", $key) "python-h3"
        $listen = Wait-Listen $server
        $port = $listen.Tcp
        $url = "https://127.0.0.1:$port"
        $authority = "127.0.0.1:$port"
        Invoke-Check "h3 zig->python GET /hello" $zigClient @(
            "h3", "GET", "$url/hello", "hello-from-python-h3", $cert, "-")
        Invoke-Check "h3 zig->python POST /echo" $zigClient @(
            "h3", "POST", "$url/echo", "zig-h3-echo", $cert, "zig-h3-echo")
        Invoke-Check "h3 zig->python GET /large" $zigClient @(
            "h3", "GET", "$url/large", "@large", $cert, "-")
        Invoke-Check "h3 zig->python GET /host" $zigClient @(
            "h3", "GET", "$url/host", $authority, $cert, "-")
    } finally {
        Stop-TestServer $server
    }
    }

    Write-Host ""
    $suffix = if ($SkipHttp3) { " (HTTP/3 skipped)" } else { "" }
    Write-Host "interop: $script:Checks checks passed$suffix"
} finally {
    Pop-Location
}
