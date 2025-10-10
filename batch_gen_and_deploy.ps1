# D:\AnyText2-main\batch_gen_and_deploy.ps1
# Batch: read users from /etc/passwd -> generate local SSH keys (no passphrase) -> overwrite authorized_keys on server

# ===== Config =====
$Server         = "10.15.14.103"
$RootUser       = "root"
$LocalBase      = "D:\AnyText2-main"   # Each user will have its own folder here
$KeyType        = "rsa"                # rsa or ed25519
$KeyBits        = 4096
$ForceOverwrite = $true                # always overwrite private key to ensure no passphrase remains
$FilterHomePref = "/home/"             # Only process users whose home starts with this
$SkipShells     = @("nologin","false") # Skip system/disabled accounts
$StrictUsers    = $null                # e.g. @('zzy','sty') to test specific users only; $null = all matched users
# ===== /Config =====

function Require-Cmd($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    Write-Error "Command not found: $name. Please install OpenSSH (ssh) and ssh-keygen."
    exit 1
  }
}
Require-Cmd ssh
Require-Cmd ssh-keygen

# SSH options (force password login, prevent local key interference)
$SshOptsBase = @(
  "-o","StrictHostKeyChecking=accept-new",
  "-o","ConnectTimeout=8",
  "-o","ServerAliveInterval=10",
  "-o","ServerAliveCountMax=2",
  "-o","NumberOfPasswordPrompts=3"
)
$SshOptsPwdOnly = $SshOptsBase + @(
  "-o","PubkeyAuthentication=no",
  "-o","PreferredAuthentications=password,keyboard-interactive"
)

# 1) Read /etc/passwd from remote server
$passwd = & ssh @SshOptsPwdOnly "${RootUser}@${Server}" "cat /etc/passwd" 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($passwd)) {
  Write-Error "Failed to read /etc/passwd:`n$passwd"
  exit 1
}

# Parse users: username + home
$users = @()
$passwd -split "`n" | ForEach-Object {
  $line = $_.Trim()
  if ($line -and $line.Contains(':')) {
    $p = $line.Split(':')
    if ($p.Count -ge 7) {
      $name     = $p[0]
      $homePath = $p[5]
      $shell    = $p[6]
      $shellTail = ($shell -split "/")[-1]
      if ($homePath -like ($FilterHomePref + "*") -and -not ($SkipShells -contains $shellTail)) {
        $users += [PSCustomObject]@{ User=$name; Home=$homePath }
      }
    }
  }
}

# Optional: restrict to specific users
if ($StrictUsers) { $users = $users | Where-Object { $StrictUsers -contains $_.User } }

if ($users.Count -eq 0) {
  Write-Warning "No eligible users found."
  exit 0
}

Write-Host "Users to process: $($users.User -join ', ')" -ForegroundColor Yellow

# 2) For each user: generate key pair (no passphrase) and overwrite authorized_keys
foreach ($u in $users) {
  $name     = $u.User
  $homePath = $u.Home

  Write-Host "== user: $name (home: $homePath) ==" -ForegroundColor Cyan

  try {
    # Local key paths
    $userLocalDir = Join-Path $LocalBase $name
    if (-not (Test-Path $userLocalDir)) { New-Item -ItemType Directory -Path $userLocalDir -Force | Out-Null }
    $privKey = Join-Path $userLocalDir "id_rsa"
    $pubKey  = $privKey + ".pub"

    # Generate key pair (no -N parameter, guaranteed no passphrase)
    if ((Test-Path $privKey) -and (-not $ForceOverwrite)) {
      Write-Host "Private key already exists, skipping: $privKey" -ForegroundColor DarkGray
    } else {
      if ($KeyType -ieq "rsa") {
        & ssh-keygen -t rsa -b $KeyBits -C $name -f $privKey -q
      } else {
        & ssh-keygen -t $KeyType -C $name -f $privKey -q
      }
      if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed (exit $LASTEXITCODE)" }
      Write-Host "Generated: $privKey" -ForegroundColor Green
    }
    if (-not (Test-Path $pubKey)) { throw "Missing pubkey: $pubKey" }

    # Remote command (overwrite instead of append)
    $remoteCmd = "mkdir -p $homePath/.ssh && cat > $homePath/.ssh/authorized_keys && chown -R ${name}:${name} $homePath/.ssh && chmod 700 $homePath/.ssh && chmod 600 $homePath/.ssh/authorized_keys"

    # Send the public key via stdin to ssh
    Get-Content -Raw -Encoding UTF8 $pubKey | & ssh @SshOptsPwdOnly "${RootUser}@${Server}" $remoteCmd
    if ($LASTEXITCODE -ne 0) { throw "remote command failed (exit $LASTEXITCODE)" }

    Write-Host "${name}: deployed OK" -ForegroundColor Green
  }
  catch {
    Write-Host "${name}: ERROR -> $_" -ForegroundColor Red
    continue
  }
}

Write-Host "All done." -ForegroundColor Cyan
