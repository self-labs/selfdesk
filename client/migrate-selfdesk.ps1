#Requires -Version 5.1
#
# migrate-selfdesk.ps1
# Troca o RustDesk pelo SelfDesk num Windows de cliente, MANTENDO O ID, e depois atualiza o
# SelfDesk no lugar. Gemeo Windows do migrate-selfdesk.sh (Linux).
#
# Uso (PowerShell como Administrador, pelo SSH ou dentro de uma sessao RustDesk):
#   migra, desacoplado do console (log em C:\ProgramData\SelfDesk-migrate\migrate-selfdesk.log):
#     [Net.ServicePointManager]::SecurityProtocol='Tls12'; iwr -useb https://raw.githubusercontent.com/self-labs/selfdesk/master/client/migrate-selfdesk.ps1 -OutFile $env:TEMP\migrate-selfdesk.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\migrate-selfdesk.ps1
#   so mostra o estado, nao muda nada:
#     [Net.ServicePointManager]::SecurityProtocol='Tls12'; iwr -useb https://raw.githubusercontent.com/self-labs/selfdesk/master/client/migrate-selfdesk.ps1 -OutFile $env:TEMP\migrate-selfdesk.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\migrate-selfdesk.ps1 -Check
#   ja no SelfDesk: reinstala o MSI da Release mais recente (versao nova ou pacote refeito), mesmo ID:
#     [Net.ServicePointManager]::SecurityProtocol='Tls12'; iwr -useb https://raw.githubusercontent.com/self-labs/selfdesk/master/client/migrate-selfdesk.ps1 -OutFile $env:TEMP\migrate-selfdesk.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\migrate-selfdesk.ps1 -Update
#   volta para o RustDesk (enquanto ele estiver instalado):
#     [Net.ServicePointManager]::SecurityProtocol='Tls12'; iwr -useb https://raw.githubusercontent.com/self-labs/selfdesk/master/client/migrate-selfdesk.ps1 -OutFile $env:TEMP\migrate-selfdesk.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\migrate-selfdesk.ps1 -Rollback
#   depois de confirmar que o SelfDesk funciona: remove o RustDesk (MSI) em silencio:
#     [Net.ServicePointManager]::SecurityProtocol='Tls12'; iwr -useb https://raw.githubusercontent.com/self-labs/selfdesk/master/client/migrate-selfdesk.ps1 -OutFile $env:TEMP\migrate-selfdesk.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\migrate-selfdesk.ps1 -Finalize
#   -Detached e interno: e o que a tarefa agendada passa para a copia que roda como SYSTEM.
#
# O que faz, na ordem:
#   1. le o ID do RustDesk (servico achado pelo PathName "RustDesk.exe --service")
#   2. baixa o selfdesk.msi da Release mais recente e confere o sha256 com o SHA256SUMS
#   3. para E DESABILITA o servico do RustDesk (senao ele volta no boot com a mesma
#      identidade copiada e os dois disputam o ID)
#   4. instala o MSI do SelfDesk e acha o servico dele pelo PathName "selfdesk.exe --service"
#   5. com o SelfDesk parado, copia o RustDesk.toml do servico para o <App>.toml do SelfDesk
#      (ID, chave e senha permanente moram nele)
#   6. sobe o SelfDesk e confere que o ID e o mesmo; se nao for, desfaz tudo sozinho
#
# Seguro rodar duas vezes: se o SelfDesk ja estiver com o ID do RustDesk, so confere.
# Nunca toca em servico do NSSM (RustDesk-hbbs, RustDesk-hbbr...) nem no RustDeskServer: o
# servico do cliente e escolhido pelo PathName, nunca pelo prefixo do nome.
# Nunca mostra o conteudo de um .toml: ele guarda a chave privada e a senha.

[CmdletBinding()]
param(
  [switch]$Check,
  [switch]$Update,
  [switch]$Rollback,
  [switch]$Finalize,
  [switch]$Detached
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # a barra de progresso deixa o iwr do PS 5.1 muito lento

$ReleaseUrl = 'https://github.com/self-labs/selfdesk/releases/latest/download'
# Pasta de trabalho so de SYSTEM e Administradores: a tarefa SYSTEM roda o script daqui, e o MSI,
# o log e o marcador de fim moram aqui. Na raiz do ProgramData qualquer usuario cria arquivos.
$WorkDir    = Join-Path $env:ProgramData 'SelfDesk-migrate'
$WorkScript = Join-Path $WorkDir 'migrate-selfdesk.ps1'
$LogFile    = Join-Path $WorkDir 'migrate-selfdesk.log'
$DoneFile   = Join-Path $WorkDir 'migrate-selfdesk.done'
$MsiLog     = Join-Path $WorkDir 'migrate-selfdesk-msi.log'
$TaskName   = 'migrate-selfdesk'
$PsExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$SvcRoaming = Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Roaming'
$RdToml     = Join-Path $SvcRoaming 'RustDesk\config\RustDesk.toml'
$RdToml2    = Join-Path $SvcRoaming 'RustDesk\config\RustDesk2.toml'
$DefaultApp = 'SelfDesk'   # nome esperado do app no MSI (nao verificado); o real vem do servico
# Servico do cliente: o exe com --service. O do servidor (hbbs/hbbr) roda pelo nssm.exe.
$RdPattern  = '\\RustDesk\.exe"?\s+--service'
$SdPattern  = '\\selfdesk\.exe"?\s+--service'
$PwPattern  = '^password\s*=\s*(''.+''|".+")'
$script:TmpDir = $null
# O texto exato que esta rodando (ja lido e analisado): e ele que vai para a pasta protegida, nao o
# arquivo em disco, que alguem pode ter trocado depois que o PowerShell o leu.
$ScriptText = & { $a = { }.Ast; while ($a.Parent) { $a = $a.Parent }; $a.Extent.Text }

# Cria (ou confere) a pasta de trabalho: dona Administradores ou SYSTEM, sem heranca, controle total
# so para os dois. A pasta nova ja nasce com essa ACL (CreateDirectory com a ACL, sem janela em que
# a heranca do ProgramData deixe um usuario criar arquivos nela). Uma pasta que ja existia com outro
# dono, ou com qualquer item dentro que nao seja de Administradores/SYSTEM ou que seja link, e
# recusada: alguem sem admin mexeu nela.
function New-WorkDirAcl {
  $acl = New-Object Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  $acl.SetOwner($script:AdminsSid)
  $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
  foreach ($sid in $script:AdminsSid, $script:SystemSid) {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, 'None', 'Allow')))
  }
  return $acl
}

function Test-TrustedOwner([string]$path) {
  $owner = (Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier])
  return ($owner -eq $script:AdminsSid -or $owner -eq $script:SystemSid)
}

function Initialize-WorkDir {
  $script:AdminsSid = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
  $script:SystemSid = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'
  $admins = $script:AdminsSid
  $system = $script:SystemSid
  # Criar e conferir sempre: se alguem criar a pasta entre o Test-Path e o CreateDirectory, ele so
  # devolve a pasta que ja existe, sem aplicar a ACL; a conferencia abaixo vale para os dois casos.
  if (-not (Test-Path -LiteralPath $WorkDir)) {
    [void][IO.Directory]::CreateDirectory($WorkDir, (New-WorkDirAcl))
  }
  $item = Get-Item -LiteralPath $WorkDir -Force
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    die ('{0} existe e nao e uma pasta comum; apague-o e rode de novo' -f $WorkDir)
  }
  $owner = (Get-Acl -LiteralPath $WorkDir).GetOwner([Security.Principal.SecurityIdentifier])
  if ($owner -ne $admins -and $owner -ne $system) {
    die ('{0} pertence a {1}, nao a Administradores/SYSTEM; apague a pasta e rode de novo' -f $WorkDir, $owner.Value)
  }
  Set-Acl -LiteralPath $WorkDir -AclObject (New-WorkDirAcl)
  foreach ($c in @(Get-ChildItem -LiteralPath $WorkDir -Force -Recurse -ErrorAction Stop)) {
    if (($c.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (Test-TrustedOwner $c.FullName)) {
      die ('{0} tem um item que nao e de Administradores/SYSTEM ou e link ({1}); apague a pasta e rode de novo' -f $WorkDir, $c.FullName)
    }
  }
}

# Grava um arquivo novo na pasta de trabalho: apaga o anterior e cria com CreateNew, que falha se
# algo reaparecer no caminho entre um passo e outro.
function Write-WorkFile([string]$path, [string]$text) {
  Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
  try {
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($text)
    $fs.Write($bytes, 0, $bytes.Length)
  } finally { $fs.Dispose() }
  if (-not (Test-TrustedOwner $path)) { die ('{0} nao ficou com dono Administradores/SYSTEM' -f $path) }
}

# ------------------------------------------------------------------ log

function Add-LogFile([string]$line) {
  for ($i = 0; $i -lt 5; $i++) {
    try { [IO.File]::AppendAllText($LogFile, $line + "`r`n"); return } catch { Start-Sleep -Milliseconds 200 }
  }
}

function Write-LogLine([string]$text, [ConsoleColor]$color) {
  Write-Host $text -ForegroundColor $color
  if ($Detached) { Add-LogFile ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $text) }
}

function log([string]$m)  { Write-LogLine ('[selfdesk] ' + $m) Cyan }
function warn([string]$m) { Write-LogLine ('[selfdesk] AVISO: ' + $m) Yellow }
function say([string]$m)  { Write-LogLine $m Gray }

# Sai limpando o temporario; desacoplado, grava o codigo no marcador que o console espera.
function Exit-Script([int]$rc) {
  if ($script:TmpDir -and (Test-Path -LiteralPath $script:TmpDir)) {
    Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($Detached) { try { [IO.File]::WriteAllText($DoneFile, [string]$rc) } catch { } }
  exit $rc
}

function die([string]$m) {
  Write-LogLine ('[selfdesk] ERRO: ' + $m) Red
  Exit-Script 1
}

# Valor lido de um comando, so para mensagem de erro: imprimivel e curto.
function Format-Obtained([string]$s) {
  $s = ($s -replace '[^\x20-\x7E]', ' ').Trim()
  if ($s.Length -gt 60) { $s = $s.Substring(0, 60) + '...' }
  return $s
}

# ------------------------------------------------------------------ servicos e processos

function Get-ExeFromPathName([string]$pathName) {
  if ($pathName -match '^\s*"([^"]+)"') { return $Matches[1] }
  if ($pathName -match '^\s*(.+?\.exe)(\s|$)') { return $Matches[1] }
  return $null
}

function Get-ClientService([string]$pattern) {
  $found = @(Get-CimInstance -ClassName Win32_Service | Where-Object {
      $_.PathName -and $_.PathName -match $pattern -and
      $_.PathName -notmatch 'nssm' -and $_.PathName -notmatch 'RustDeskServer'
    })
  if ($found.Count -gt 1) {
    warn ('mais de um servico com {0}: {1}; usando o primeiro' -f $pattern, (($found | ForEach-Object { $_.Name }) -join ', '))
  }
  if ($found.Count -ge 1) { return $found[0] }
  return $null
}

# Exe, pasta e nome do app a partir do servico. O RustDesk da ao servico o nome do app, que
# tambem e o nome da pasta de config (Roaming\<App>\config\<App>.toml).
function Get-AppInfo($svc) {
  if (-not $svc) { return $null }
  $exe = Get-ExeFromPathName $svc.PathName
  if (-not $exe) { return $null }
  $dir = Split-Path -Parent $exe
  return [pscustomobject]@{
    Service   = $svc.Name
    Exe       = $exe
    Dir       = $dir
    Folder    = Split-Path -Leaf $dir
    App       = $svc.Name
    State     = $svc.State
    StartMode = $svc.StartMode
  }
}

function Get-RustDeskInfo { return Get-AppInfo (Get-ClientService $RdPattern) }
function Get-SelfDeskInfo { return Get-AppInfo (Get-ClientService $SdPattern) }

function Get-AppToml([string]$roaming, [string]$app) {
  return Join-Path $roaming ('{0}\config\{0}.toml' -f $app)
}

function Get-ExeVersion([string]$exe) {
  try { return (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } catch { return '?' }
}

# So os processos daquele exe exato (nunca hbbs/hbbr, nunca nada do RustDeskServer).
function Stop-AppProcesses([string]$exe) {
  if (-not $exe -or $exe -match 'RustDeskServer|nssm') { throw ('exe recusado para encerrar processos: {0}' -f $exe) }
  $procs = @(Get-CimInstance -ClassName Win32_Process | Where-Object {
      $_.ExecutablePath -and $_.ProcessId -ne $PID -and
      [string]::Equals($_.ExecutablePath, $exe, [StringComparison]::OrdinalIgnoreCase)
    })
  foreach ($p in $procs) {
    log ('encerrando {0} (pid {1})' -f $p.Name, $p.ProcessId)
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

function Stop-AppService($info) {
  $svc = Get-Service -Name $info.Service -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -ne 'Stopped') {
    try { $svc.Stop() } catch { warn ('pedido de parada do {0} falhou: {1}' -f $info.Service, $_.Exception.Message) }
    try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) }
    catch { warn ('{0} nao parou em 30 s; encerrando os processos' -f $info.Service) }
  }
  Stop-AppProcesses $info.Exe
  $svc = Get-Service -Name $info.Service -ErrorAction SilentlyContinue
  if ($svc) {
    try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10)) } catch { }
    $svc.Refresh()
    if ($svc.Status -ne 'Stopped') { throw ('o servico {0} nao parou (estado {1})' -f $info.Service, $svc.Status) }
  }
}

function Start-AppService($info) {
  Start-Service -Name $info.Service
  (Get-Service -Name $info.Service).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
}

# "<exe> --get-id" num job com prazo de 20 s (o timeout 20 do script Linux).
function Get-AppId([string]$exe) {
  if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { return '' }
  $job = Start-Job -ScriptBlock { param($p) & $p --get-id 2>$null | Out-String } -ArgumentList $exe
  $out = ''
  if (Wait-Job -Job $job -Timeout 20) {
    $out = [string](Receive-Job -Job $job -ErrorAction SilentlyContinue)
  } else {
    warn ('{0} --get-id nao respondeu em 20 s' -f $exe)
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Get-CimInstance -ClassName Win32_Process | Where-Object {
      $_.ExecutablePath -and [string]::Equals($_.ExecutablePath, $exe, [StringComparison]::OrdinalIgnoreCase) -and
      $_.CommandLine -match '--get-id'
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  }
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
  return $out.Trim()
}

# Depois de subir o servico: espera 10 s e tenta ate ~40 s ate o ID esperado aparecer.
function Wait-AppId([string]$exe, [string]$want) {
  Start-Sleep -Seconds 10
  $deadline = (Get-Date).AddSeconds(40)
  $id = ''
  do {
    $id = Get-AppId $exe
    if ($id -eq $want) { return $id }
    Start-Sleep -Seconds 5
  } while ((Get-Date) -lt $deadline)
  return $id
}

function Wait-SelfDeskInfo([int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  do {
    $i = Get-SelfDeskInfo
    if ($i) { return $i }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  return $null
}

function Test-PermanentPassword([string]$toml) {
  if (-not (Test-Path -LiteralPath $toml)) { return $false }
  return [bool](Select-String -LiteralPath $toml -Pattern $PwPattern -Quiet)
}

function Get-UserRoamings {
  Get-CimInstance -ClassName Win32_UserProfile | Where-Object {
    -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath)
  } | ForEach-Object { Join-Path $_.LocalPath 'AppData\Roaming' }
}

function Get-NssmServices {
  Get-CimInstance -ClassName Win32_Service | Where-Object { $_.PathName -and $_.PathName -match 'nssm' }
}

function Get-RustDeskUninstallEntries {
  $roots = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  Get-ItemProperty -Path $roots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'RustDesk' }
}

function Get-RustDeskProductCodes {
  @(Get-RustDeskUninstallEntries | Where-Object { $_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$' } |
    ForEach-Object { $_.PSChildName.ToUpper() })
}

# Nomes das pastas de config do servico que parecem de um *Desk (so nomes, nunca conteudo).
function Show-ServiceConfigDirs {
  Get-ChildItem -LiteralPath $SvcRoaming -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'desk' } |
    ForEach-Object { log ('pasta de config do servico: {0}' -f $_.FullName) }
}

# ------------------------------------------------------------------ MSI (COM do Windows Installer)

# O objeto WindowsInstaller.Installer nao tem type library no PowerShell: tudo por InvokeMember.
function Invoke-ComMember($obj, [string]$name, [string]$kind, [object[]]$memberArgs) {
  return , ($obj.GetType().InvokeMember($name, [Reflection.BindingFlags]$kind, $null, $obj, $memberArgs))
}

function Release-Com($obj) {
  if ($null -ne $obj) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($obj) }
}

function Get-MsiInfo([string]$msi) {
  $inst = New-Object -ComObject WindowsInstaller.Installer
  $db = Invoke-ComMember $inst 'OpenDatabase' 'InvokeMethod' @($msi, 0)
  $info = @{}
  foreach ($prop in 'ProductCode', 'ProductVersion', 'UpgradeCode', 'ProductName') {
    $view = Invoke-ComMember $db 'OpenView' 'InvokeMethod' @("SELECT Value FROM Property WHERE Property='" + $prop + "'")
    [void](Invoke-ComMember $view 'Execute' 'InvokeMethod' $null)
    $rec = Invoke-ComMember $view 'Fetch' 'InvokeMethod' $null
    $info[$prop] = ''
    if ($null -ne $rec) { $info[$prop] = [string](Invoke-ComMember $rec 'StringData' 'GetProperty' @(1)) }
    [void](Invoke-ComMember $view 'Close' 'InvokeMethod' $null)
    Release-Com $rec
    Release-Com $view
  }
  Release-Com $db
  Release-Com $inst
  [GC]::Collect()
  [GC]::WaitForPendingFinalizers()
  return [pscustomobject]$info
}

# ProductCodes instalados com o mesmo UpgradeCode.
function Get-RelatedProducts([string]$upgradeCode) {
  $codes = @()
  if (-not $upgradeCode) { return $codes }
  $inst = New-Object -ComObject WindowsInstaller.Installer
  $list = Invoke-ComMember $inst 'RelatedProducts' 'GetProperty' @($upgradeCode)
  if ($null -ne $list) {
    $n = [int](Invoke-ComMember $list 'Count' 'GetProperty' $null)
    for ($i = 0; $i -lt $n; $i++) {
      $codes += ([string](Invoke-ComMember $list 'Item' 'GetProperty' @($i))).ToUpper()
    }
    Release-Com $list
  }
  Release-Com $inst
  return $codes
}

function Get-ProductVersion([string]$code) {
  try {
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $v = [string](Invoke-ComMember $inst 'ProductInfo' 'GetProperty' @($code, 'VersionString'))
    Release-Com $inst
    return $v
  } catch { return '?' }
}

# msiexec com log detalhado em C:\ProgramData; devolve o codigo de saida.
function Invoke-Msiexec([string]$argLine) {
  $full = '{0} /qn /norestart /l*v "{1}"' -f $argLine, $MsiLog
  log ('msiexec {0}' -f $full)
  $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $full -PassThru
  $null = $p.Handle   # guarda o handle para o ExitCode existir depois do WaitForExit
  if (-not $p.WaitForExit(15 * 60 * 1000)) { throw 'msiexec nao terminou em 15 minutos' }
  return $p.ExitCode
}

function Test-MsiOk([int]$rc) { return ($rc -eq 0 -or $rc -eq 3010) }

function Get-MsiErrorHint([int]$rc) {
  switch ($rc) {
    1603 { return 'erro fatal na instalacao' }
    1618 { return 'outra instalacao esta em andamento (Windows Update?); tente de novo depois' }
    1638 { return 'outra versao do produto ja esta instalada' }
    default { return 'veja o log do msiexec' }
  }
}

# Baixa o selfdesk.msi da Release mais recente e confere o sha256 com o SHA256SUMS dela.
function Get-VerifiedMsi {
  Initialize-WorkDir
  $script:TmpDir = Join-Path $WorkDir ('msi-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
  $msi = Join-Path $script:TmpDir 'selfdesk.msi'
  $sums = Join-Path $script:TmpDir 'SHA256SUMS'
  log ('baixando {0}/selfdesk.msi' -f $ReleaseUrl)
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 -Uri "$ReleaseUrl/selfdesk.msi" -OutFile $msi }
  catch { die ('download do MSI falhou ({0}); nada foi alterado' -f $_.Exception.Message) }
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri "$ReleaseUrl/SHA256SUMS" -OutFile $sums }
  catch { die ('download do SHA256SUMS falhou ({0}); nada foi alterado' -f $_.Exception.Message) }
  $line = Get-Content -LiteralPath $sums | Where-Object { $_ -match '^\s*[0-9a-fA-F]{64}\s+\*?selfdesk\.msi\s*$' } | Select-Object -First 1
  if (-not $line) { die 'o SHA256SUMS da Release nao tem linha do selfdesk.msi; nada foi alterado' }
  $want = ([regex]::Match($line, '[0-9a-fA-F]{64}')).Value
  $got = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
  if ($got -ne $want) { die 'sha256 do MSI nao confere com o SHA256SUMS da Release; nada foi alterado' }
  log 'sha256 do MSI confere'
  return $msi
}

# ------------------------------------------------------------------ desacoplar do console

function Show-LogFrom([long]$pos) {
  if (-not (Test-Path -LiteralPath $LogFile)) { return $pos }
  $fs = [IO.File]::Open($LogFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
  try {
    if ($fs.Length -le $pos) { return $pos }
    [void]$fs.Seek($pos, [IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] ([int]($fs.Length - $pos))
    $n = $fs.Read($buf, 0, $buf.Length)
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
    $last = $text.LastIndexOf("`n")
    if ($last -lt 0) { return $pos }   # so linhas completas
    $chunk = $text.Substring(0, $last + 1)
    Write-Host -NoNewline $chunk
    return $pos + [Text.Encoding]::UTF8.GetByteCount($chunk)
  } finally { $fs.Dispose() }
}

# Uma migracao digitada dentro de uma sessao RustDesk perde a sessao quando o servico do RustDesk
# para, e uma pelo SSH morre se o tunel cair. Aqui o trabalho roda numa tarefa agendada como
# SYSTEM, fora do console, e o console so acompanha o log.
function Invoke-Detached {
  if (-not $PSCommandPath) { die 'rode com: powershell -NoProfile -ExecutionPolicy Bypass -File <caminho>\migrate-selfdesk.ps1' }
  $old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($old -and $old.State -eq 'Running') {
    die ('ja ha uma execucao rodando (tarefa {0}); acompanhe {1}' -f $TaskName, $LogFile)
  }
  Initialize-WorkDir
  Remove-Item -LiteralPath $DoneFile -Force -ErrorAction SilentlyContinue
  Write-WorkFile $LogFile ''
  # A tarefa SYSTEM roda a copia na pasta protegida, nunca o arquivo baixado pelo usuario.
  Write-WorkFile $WorkScript $ScriptText

  $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Detached' -f $WorkScript
  if ($Update) { $argLine += ' -Update' }
  $action = New-ScheduledTaskAction -Execute $PsExe -Argument $argLine
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  # Notebook na bateria: sem estes dois a tarefa nem comeca.
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Write-Host ('rodando desacoplado como SYSTEM (tarefa {0}); log em {1}' -f $TaskName, $LogFile)
  Write-Host '(pode cair a conexao: ele termina sozinho)'

  $started = Get-Date
  $pos = [long]0
  $rc = 1
  while ($true) {
    $pos = Show-LogFrom $pos
    if (Test-Path -LiteralPath $DoneFile) {
      # O marcador pode existir ainda vazio por um instante: vazio nao vira codigo 0.
      $txt = ''
      for ($i = 0; $i -lt 10 -and $txt -notmatch '^\d+$'; $i++) {
        Start-Sleep -Milliseconds 500
        try { $txt = ([string](Get-Content -LiteralPath $DoneFile -Raw)).Trim() } catch { $txt = '' }
      }
      $pos = Show-LogFrom $pos
      if ($txt -match '^\d+$') { $rc = [int]$txt } else { $rc = 1 }
      break
    }
    $elapsed = (Get-Date) - $started
    if ($elapsed.TotalSeconds -gt 15) {
      $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
      if (-not $t -or ($t.State -ne 'Running' -and $t.State -ne 'Queued')) {
        $pos = Show-LogFrom $pos
        $rc = [int](Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue).LastTaskResult
        Write-Host ('a tarefa terminou sem o marcador de fim (codigo {0})' -f $rc)
        if ($rc -eq 0) { $rc = 1 }
        break
      }
    }
    if ($elapsed.TotalMinutes -gt 35) {
      Write-Host ('passou de 35 minutos; a tarefa {0} continua registrada, confira {1}' -f $TaskName, $LogFile)
      exit 1
    }
    Start-Sleep -Seconds 1
  }
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $DoneFile -Force -ErrorAction SilentlyContinue
  exit $rc
}

# ------------------------------------------------------------------ estado

function Show-App([string]$label, $info) {
  if (-not $info) { log ('{0}: ausente (nenhum servico do cliente)' -f $label); return }
  log ('{0}: instalado, versao {1}, servico ''{2}'' {3}/{4}, {5}' -f $label, (Get-ExeVersion $info.Exe), $info.Service, $info.State, $info.StartMode, $info.Exe)
  log ('ID do {0}: {1}' -f $label, (Format-Obtained (Get-AppId $info.Exe)))
}

function Show-State {
  $rd = Get-RustDeskInfo
  $sd = Get-SelfDeskInfo
  Show-App 'RustDesk' $rd
  Show-App 'SelfDesk' $sd
  $app = $DefaultApp
  if ($sd) { $app = $sd.App }
  $files = @($RdToml, $RdToml2, (Get-AppToml $SvcRoaming $app))
  foreach ($r in @(Get-UserRoamings)) {
    $files += Join-Path $r 'RustDesk\config\RustDesk.toml'
    $files += Get-AppToml $r $app
  }
  foreach ($f in $files) {
    if (Test-Path -LiteralPath $f) { log ('config: {0} ({1} bytes)' -f $f, (Get-Item -LiteralPath $f).Length) }
  }
  if (-not (Test-Path -LiteralPath $RdToml)) { log ('config: {0} ausente' -f $RdToml) }
  else {
    $pw = 'nao'
    if (Test-PermanentPassword $RdToml) { $pw = 'sim' }
    log ('senha permanente no RustDesk.toml do servico: {0}' -f $pw)
  }
  foreach ($s in @(Get-NssmServices)) { log ('servico NSSM (nunca tocado): {0} {1}' -f $s.Name, $s.State) }
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    warn ('a tarefa agendada {0} ficou registrada (execucao interrompida?); log em {1}' -f $TaskName, $LogFile)
  }
}

# ------------------------------------------------------------------ rollback

function Invoke-Rollback {
  warn 'voltando para o RustDesk'
  $sd = Get-SelfDeskInfo
  if ($sd) {
    try { Set-Service -Name $sd.Service -StartupType Disabled } catch { warn ('nao desabilitei o {0}: {1}' -f $sd.Service, $_.Exception.Message) }
    try { Stop-AppService $sd } catch { warn ('nao parei o {0}: {1}' -f $sd.Service, $_.Exception.Message) }
  }
  $rd = Get-RustDeskInfo
  if (-not $rd) { warn 'servico do RustDesk nao encontrado: nada para religar'; return }
  try {
    Set-Service -Name $rd.Service -StartupType Automatic
    Start-AppService $rd
  } catch { warn ('nao religuei o {0}: {1}' -f $rd.Service, $_.Exception.Message); return }
  Start-Sleep -Seconds 8
  log ('RustDesk de volta, ID {0}. O SelfDesk ficou instalado e desabilitado.' -f (Format-Obtained (Get-AppId $rd.Exe)))
}

# ------------------------------------------------------------------ update

# Por cima de um SelfDesk instalado: o MSI nao toca na identidade (o <App>.toml mora no perfil
# do LocalService e no Roaming de cada usuario). Mesmo ProductCode ja instalado: um /i simples so
# entra em manutencao e nao troca nada, entao vai REINSTALL=ALL REINSTALLMODE=vomus (pacote
# refeito com o mesmo numero de versao, ou upgrade menor). ProductCode novo: /i normal (upgrade maior).
function Get-InstallArgLine([string]$msi, $mi, [string[]]$related) {
  foreach ($c in $related) { log ('instalado: {0} versao {1}' -f $c, (Get-ProductVersion $c)) }
  if ($related -contains $mi.ProductCode.ToUpper()) {
    log 'mesmo ProductCode ja instalado: reinstalando por cima (REINSTALL=ALL REINSTALLMODE=vomus)'
    return ('/i "{0}" REINSTALL=ALL REINSTALLMODE=vomus' -f $msi)
  }
  foreach ($c in $related) {
    if ((Get-ProductVersion $c) -eq $mi.ProductVersion) {
      warn ('{0} tem a mesma versao {1} com outro ProductCode: o /i pode instalar lado a lado' -f $c, $mi.ProductVersion)
    }
  }
  return ('/i "{0}"' -f $msi)
}

function Invoke-Update {
  $sd = Get-SelfDeskInfo
  if (-not $sd) { die 'o SelfDesk nao esta instalado: rode sem opcao para migrar do RustDesk' }
  $rd = Get-RustDeskInfo
  if ($sd.StartMode -eq 'Disabled' -or ($rd -and $rd.State -eq 'Running')) {
    die 'rollback ativo (SelfDesk desabilitado ou RustDesk rodando): rode sem opcao para migrar de novo'
  }
  $oldId = Get-AppId $sd.Exe
  if ($oldId -notmatch '^\d{6,}$') { die ('nao consegui ler o ID do SelfDesk (obtido: ''{0}'')' -f (Format-Obtained $oldId)) }
  log ('ID do SelfDesk: {0}, versao instalada {1}' -f $oldId, (Get-ExeVersion $sd.Exe))
  $msi = Get-VerifiedMsi
  $mi = $null
  try { $mi = Get-MsiInfo $msi } catch { die ('nao consegui ler as propriedades do MSI ({0}); nada foi alterado' -f $_.Exception.Message) }
  log ('MSI: {0} {1}, ProductCode {2}' -f $mi.ProductName, $mi.ProductVersion, $mi.ProductCode)
  $related = @()
  try { $related = @(Get-RelatedProducts $mi.UpgradeCode) } catch { warn ('nao consegui listar os produtos instalados ({0})' -f $_.Exception.Message) }
  if ($related.Count -eq 0) { warn 'nenhum produto MSI do SelfDesk registrado (instalado pelo .exe?): /i normal' }
  $rc = Invoke-Msiexec (Get-InstallArgLine $msi $mi $related)
  if (-not (Test-MsiOk $rc)) { die ('msiexec terminou com codigo {0}: {1} (log: {2})' -f $rc, (Get-MsiErrorHint $rc), $MsiLog) }
  if ($rc -eq 3010) { warn 'o Windows pede reinicio para terminar a atualizacao (codigo 3010); nao reiniciei' }

  $sd = Wait-SelfDeskInfo 30
  if (-not $sd) { die 'o servico do SelfDesk sumiu depois da atualizacao; rode com -Check' }
  try { $after = @(Get-RelatedProducts $mi.UpgradeCode) } catch { $after = @() }
  if ($after.Count -gt 1) { warn ('{0} produtos SelfDesk registrados: {1}' -f $after.Count, ($after -join ', ')) }

  log ('reiniciando o servico {0}' -f $sd.Service)
  Stop-AppService $sd
  Start-AppService $sd
  $newId = Wait-AppId $sd.Exe $oldId
  if ($newId -ne $oldId) {
    die ('o SelfDesk voltou com o ID ''{0}'', esperado ''{1}'': confira {2}' -f (Format-Obtained $newId), $oldId, (Get-AppToml $SvcRoaming $sd.App))
  }
  log ('OK: SelfDesk {0} com o mesmo ID ({1})' -f (Get-ExeVersion $sd.Exe), $newId)
  Show-State
}

# ------------------------------------------------------------------ finalize

function Invoke-Finalize {
  $sd = Get-SelfDeskInfo
  if (-not $sd -or $sd.State -ne 'Running') { die 'o SelfDesk nao esta rodando; nao removo o RustDesk' }
  $entries = @(Get-RustDeskUninstallEntries)
  $codes = @(Get-RustDeskProductCodes)
  if ($entries.Count -eq 0) {
    if (Get-RustDeskInfo) { die 'o servico do RustDesk existe mas nao ha entrada de desinstalacao ''RustDesk''; remova pelo Painel de Controle' }
    log 'RustDesk ja removido'
    return
  }
  if ($codes.Count -eq 0) {
    die 'o RustDesk desta maquina nao foi instalado por MSI (sem ProductCode); remova pelo Painel de Controle'
  }
  $before = @{}
  foreach ($s in @(Get-NssmServices)) { $before[$s.Name] = $s.State }
  foreach ($c in $codes) {
    log ('removendo o RustDesk {0}' -f $c)
    $rc = Invoke-Msiexec ('/x {0}' -f $c)
    if ($rc -eq 1605) { log ('{0} ja nao estava instalado' -f $c); continue }
    if (-not (Test-MsiOk $rc)) { die ('msiexec /x terminou com codigo {0}: {1} (log: {2})' -f $rc, (Get-MsiErrorHint $rc), $MsiLog) }
  }
  foreach ($s in @(Get-NssmServices)) {
    if ($before.ContainsKey($s.Name) -and $before[$s.Name] -ne $s.State) {
      warn ('o servico NSSM {0} mudou de {1} para {2} durante a remocao: confira' -f $s.Name, $before[$s.Name], $s.State)
    }
  }
  foreach ($n in $before.Keys) {
    if (-not (Get-Service -Name $n -ErrorAction SilentlyContinue)) { warn ('o servico NSSM {0} sumiu durante a remocao: confira' -f $n) }
  }
  if (Get-RustDeskInfo) { warn 'o servico do RustDesk ainda existe depois do msiexec /x' }
  else { log 'RustDesk removido' }
  Show-State
}

# ------------------------------------------------------------------ migracao

function Copy-Toml([string]$src, [string]$dst) {
  $d = Split-Path -Parent $dst
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  Copy-Item -LiteralPath $src -Destination $dst -Force
  log ('copiado {0} -> {1}' -f $src, $dst)
}

function Invoke-Migrate {
  $rd = Get-RustDeskInfo
  if (-not $rd) { die 'o RustDesk (cliente) nao esta instalado: para maquina nova instale o SelfDesk direto, sem migracao' }
  if (-not (Test-Path -LiteralPath $RdToml)) { die ('sem {0}' -f $RdToml) }
  # O SelfDesk so aceita a senha permanente: sem ela, o ID migra certo e ninguem conecta.
  # Confere so a presenca do campo, nunca o valor.
  if (-not (Test-PermanentPassword $RdToml)) {
    die 'o RustDesk desta maquina nao tem senha permanente; defina nas configuracoes de seguranca dele (nada foi alterado)'
  }

  $oldId = Get-AppId $rd.Exe
  if ($oldId -notmatch '^\d{6,}$') { die ('nao consegui ler o ID do RustDesk (obtido: ''{0}'')' -f (Format-Obtained $oldId)) }
  log ('ID do RustDesk: {0} (servico ''{1}'', {2})' -f $oldId, $rd.Service, $rd.Exe)

  $sd = Get-SelfDeskInfo
  if ($sd -and $sd.State -eq 'Running' -and (Get-AppId $sd.Exe) -eq $oldId) {
    log ('SelfDesk ja esta com o ID {0}: nada a migrar' -f $oldId)
    Show-State
    return
  }

  $msi = Get-VerifiedMsi
  $mi = $null
  try { $mi = Get-MsiInfo $msi } catch { die ('nao consegui ler as propriedades do MSI ({0}); nada foi alterado' -f $_.Exception.Message) }
  log ('MSI: {0} {1}, ProductCode {2}' -f $mi.ProductName, $mi.ProductVersion, $mi.ProductCode)
  # Se o MSI do SelfDesk fosse um upgrade do RustDesk, instalar removeria o RustDesk e o rollback.
  $rdCodes = @(Get-RustDeskProductCodes)
  $related = @()
  try { $related = @(Get-RelatedProducts $mi.UpgradeCode) }
  catch { die ('nao consegui conferir o UpgradeCode do MSI ({0}); nada foi alterado' -f $_.Exception.Message) }
  foreach ($c in $rdCodes) {
    if ($related -contains $c -or $c -eq $mi.ProductCode.ToUpper()) {
      die 'o MSI do SelfDesk tem o mesmo UpgradeCode/ProductCode do RustDesk: instalar removeria o RustDesk e o rollback; nada foi alterado'
    }
  }

  # A partir daqui qualquer erro desfaz a troca.
  $failure = $null
  try {
    log 'parando e desabilitando o RustDesk (continua instalado)'
    Set-Service -Name $rd.Service -StartupType Disabled
    Stop-AppService $rd

    log 'instalando o SelfDesk'
    # Depois de um -Rollback o SelfDesk ja esta instalado: mesmo ProductCode vai por REINSTALL.
    $rc = Invoke-Msiexec (Get-InstallArgLine $msi $mi $related)
    if (-not (Test-MsiOk $rc)) { throw ('msiexec terminou com codigo {0}: {1} (log: {2})' -f $rc, (Get-MsiErrorHint $rc), $MsiLog) }
    if ($rc -eq 3010) { warn 'o Windows pede reinicio para terminar a instalacao (codigo 3010); nao reiniciei' }
    if (-not (Get-RustDeskInfo)) { warn 'o servico do RustDesk sumiu depois de instalar o SelfDesk: o rollback nao tera para onde voltar' }

    $sd = Wait-SelfDeskInfo 30
    if (-not $sd) { throw 'nenhum servico do SelfDesk (selfdesk.exe --service) apareceu depois da instalacao' }
    log ('SelfDesk: servico ''{0}'', exe {1}, pasta ''{2}'', nome do app ''{3}''' -f $sd.Service, $sd.Exe, $sd.Folder, $sd.App)
    if ($sd.App -ne $sd.Folder) { warn ('o nome do servico ''{0}'' difere da pasta ''{1}''; uso o do servico para a config' -f $sd.App, $sd.Folder) }

    log 'copiando a identidade do RustDesk com o SelfDesk parado'
    Stop-AppService $sd
    # So a config do servico: no Windows o --server roda como SYSTEM com ela, e a interface de cada
    # usuario recebe a config do servico. Copiar como SYSTEM para dentro dos perfis seguiria links
    # que o proprio usuario pode criar (escrita em qualquer pasta, ou a chave do servico exposta).
    Copy-Toml $RdToml (Get-AppToml $SvcRoaming $sd.App)

    # O -Rollback deixa o SelfDesk Disabled, e o MSI em manutencao nao muda isso.
    Set-Service -Name $sd.Service -StartupType Automatic
    Start-AppService $sd
    $newId = Wait-AppId $sd.Exe $oldId
    if ($newId -ne $oldId) {
      Show-ServiceConfigDirs
      $failure = 'o SelfDesk subiu com o ID ''{0}'', esperado ''{1}''' -f (Format-Obtained $newId), $oldId
    }
  } catch {
    $failure = 'falhou na linha {0}: {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message
  }
  if ($failure) {
    warn $failure
    Invoke-Rollback
    Exit-Script 1
  }

  log ('OK: SelfDesk ativo com o mesmo ID ({0}) e a mesma senha permanente' -f $newId)
  Show-State
  $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
  say ''
  say 'Proximos passos:'
  say ('  1. conecte de outro computador no ID {0} com a senha permanente de antes' -f $newId)
  say '  2. com o SelfDesk confirmado (de preferencia depois de um reboot), remova o RustDesk:'
  say ('       {0} -Finalize' -f $cmd)
  say '  Para voltar atras a qualquer momento antes do passo 2:'
  say ('       {0} -Rollback' -f $cmd)
}

# ------------------------------------------------------------------ principal

function Invoke-Main {
  $n = [int]$Check.IsPresent + [int]$Update.IsPresent + [int]$Rollback.IsPresent + [int]$Finalize.IsPresent
  if ($n -gt 1) { die 'use so uma opcao: -Check, -Update, -Rollback ou -Finalize' }

  $me = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    die 'rode num PowerShell como Administrador'
  }
  if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    die 'rode no PowerShell de 64 bits (nao o da pasta SysWOW64)'
  }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $wantsDetach = $Update -or ($n -eq 0)
  if ($wantsDetach -and -not $Detached -and -not $env:MIGRATE_SELFDESK_DETACHED) { Invoke-Detached }

  if ($Detached) {
    $mode = 'migracao'
    if ($Update) { $mode = 'update' }
    log ('inicio {0}, modo {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $mode)
  }

  if ($Check)        { Show-State }
  elseif ($Update)   { Invoke-Update }
  elseif ($Rollback) {
    if (-not (Get-RustDeskInfo)) { die 'o RustDesk nao esta mais instalado' }
    Invoke-Rollback
    Show-State
  }
  elseif ($Finalize) { Invoke-Finalize }
  else               { Invoke-Migrate }
}

try {
  Invoke-Main
} catch {
  Write-LogLine ('[selfdesk] ERRO: inesperado na linha {0}: {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message) Red
  Exit-Script 1
}
Exit-Script 0
