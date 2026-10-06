<#
.SYNOPSIS
    Realiza transferência segura via SFTP nativo medindo latência e tempo total de execução.
.DESCRIPTION
    Desenvolvido com foco em observabilidade (SRE):
    - Medição de tempo de alta resolução via Stopwatch.
    - Autenticação passwordless via SSH Key.
    - Saída de telemetria estruturada em JSON (stdout) e logs de execução (stderr/arquivo).
    - Códigos de saída semânticos (0 = Sucesso, 1 = Falha).
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$SftpHost,

    [Parameter(Mandatory = $true)]
    [string]$SftpUser,

    [Parameter(Mandatory = $true)]
    [string]$IdentityFilePath,

    [Parameter(Mandatory = $true)]
    [string]$LocalFilePath,

    [Parameter(Mandatory = $true)]
    [string]$RemoteDirectory,

    [Parameter(Mandatory = $false)]
    [int]$Port = 22,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\sftp_transfer.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-StructuredLog {
    param (
        [string]$Level,
        [string]$Message,
        [hashtable]$Context = @{}
    )
    $logEntry = [PSCustomObject]@{
        timestamp = (Get-Date -Format "o")
        level     = $Level
        message   = $Message
        context   = $Context
    }
    $json =$logEntry | ConvertTo-Json -Compress
    Add-Content -Path $LogPath -Value$json
    Write-Output $json
}

# 1. Validação de pré-requisitos locais
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if (-not (Test-Path -Path $IdentityFilePath)) {
    Write-StructuredLog -Level "FATAL" -Message "Chave de identidade SSH não encontrada." -Context @{ path = $IdentityFilePath }
    exit 1
}

if (-not (Test-Path -Path $LocalFilePath)) {
    Write-StructuredLog -Level "FATAL" -Message "Arquivo de origem não encontrado." -Context @{ path = $LocalFilePath }
    exit 1
}

$fileSizeMb = [math]::Round(((Get-Item -Path $LocalFilePath).Length / 1MB), 3)$batchFile = [System.IO.Path]::GetTempFileName()

try {
    Write-StructuredLog -Level "INFO" -Message "Iniciando transferência SFTP" -Context @{
        host         = $SftpHost
        user         = $SftpUser
        file_path    = $LocalFilePath
        file_size_mb = $fileSizeMb
    }

    # 2. Monta arquivo de lote temporário para o cliente sftp
    # 'put -P' preserva permissões e timestamps
    $batchCommands = @"
cd $RemoteDirectory
put "$LocalFilePath"
bye
"@
    Set-Content -Path $batchFile -Value$batchCommands -Encoding ASCII

    # 3. Execução do sftp nativo com captura de stdout/stderr
    $sftpArgs = @(
        "-i", "`"$IdentityFilePath`"",
        "-P", $Port,
        "-b", "`"$batchFile`"",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=15",
        "$SftpUser@$SftpHost"
    )

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = "sftp.exe"
    $processInfo.Arguments =$sftpArgs -join " "
    $processInfo.RedirectStandardOutput =$true
    $processInfo.RedirectStandardError =$true
    $processInfo.UseShellExecute =$false
    $processInfo.CreateNoWindow =$true

    $process = [System.Diagnostics.Process]::Start($processInfo)$stdout = $process.StandardOutput.ReadToEnd()$stderr = $process.StandardError.ReadToEnd()$process.WaitForExit()

    $stopwatch.Stop()
    $elapsedMs =$stopwatch.ElapsedMilliseconds
    $elapsedSec = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    $throughputMbSec = if ($elapsedSec -gt 0) { [math]::Round(($fileSizeMb / $elapsedSec), 2) } else { 0 }

    # 4. Avaliação do resultado
    if ($process.ExitCode -ne 0) {
        Write-StructuredLog -Level "ERROR" -Message "Falha na execução do processo SFTP" -Context @{
            exit_code   = $process.ExitCode
            stderr      = $stderr.Trim()
            duration_ms = $elapsedMs
        }
        exit $process.ExitCode
    }

    Write-StructuredLog -Level "INFO" -Message "Transferência concluída com sucesso" -Context @{
        status             = "SUCCESS"
        duration_ms        = $elapsedMs
        duration_sec       = $elapsedSec
        file_size_mb       = $fileSizeMb
        throughput_mb_sec  = $throughputMbSec
    }

    exit 0

}
catch {
    $stopwatch.Stop()
    Write-StructuredLog -Level "FATAL" -Message "Exceção não tratada durante o pipeline" -Context @{
        error_message = $_.Exception.Message
        duration_ms   = $stopwatch.ElapsedMilliseconds
    }
    exit 1
}
finally {
    # Limpeza defensiva do arquivo temporário com comandos de lote
    if (Test-Path -Path $batchFile) {
        Remove-Item -Path $batchFile -Force -ErrorAction SilentlyContinue
    }
}