```
.\Invoke-SftpTransfer.ps1 `
    -SftpHost "sftp.meudominio.com.br" `
    -SftpUser "svc-sre-batch" `
    -IdentityFilePath "C:\Keys\sftp_rsa.id" `
    -LocalFilePath "D:\Backups\dump_20261006.tar.gz" `
    -RemoteDirectory "/data/incoming" `
    -Port 22
```    