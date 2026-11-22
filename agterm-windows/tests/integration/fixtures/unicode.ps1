[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Write-Output ("smoke-" + (-join [char[]](0x043F, 0x0440, 0x0438, 0x0432, 0x0456, 0x0442)) + " " + [char]0x2713)
