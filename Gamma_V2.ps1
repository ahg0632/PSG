if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Write-Host "`nThis script executes the following:
- SFC Scan
- Check Disk
- GP Update
- Profile deletions
- Cache Deletion
- Outlook Cache delete
If you would like to only remove a specific profile you will need to do it manually or use the other script in here.
(Read the word/readme file for instructions)`n" -ForegroundColor Blue

function Invoke-ContinueOrExit {
    while($true) {
        $choice = Read-Host -Prompt "Do you want to continue? (Y/N)"

        switch($choice.Trim().ToUpper()) {
            {$_ -in 'Y', 'YES'} {
                return $true
            }
            {$_ -in 'N', 'NO'} {
                return $false
            }
            Default {
                Write-Host "Invalid input. Please enter 'Y' or 'N'" -ForegroundColor Yellow
            }
        }
    }
}

#New Registry Pattern
class CleanMethod {
    CleanMethod() {}
    [void] CleanOption() {
        throw [System.NotImplementedException]::new()
    }
}

class CleanFactory {
    static [hashtable]$CleanMethods = @{}
    static [bool]$RestartRequired = $false
    static [bool]$ExitApplication = $false

    static [void] Register([int]$option, [scriptblock]$method) {
        [CleanFactory]::CleanMethods[$option] = $method
        Write-Host "Registered clean method for option $option" -ForegroundColor DarkGray
    }

    static [CleanMethod] Create([string]$option) {
        $key = $option.ToUInt32()
        if ([CleanFactory]::CleanMethods.ContainsKey($key)) {
            throw [System.NotImplementedException]::new("Clean method for option $option is not implemented or does not exist.")
        }
        return & [CleanFactory]::CleanMethods[$key]
    }
}

class SFCScan : CleanMethod {
    [void] CleanOption() {
        Write-Host "`nRunning System File Checker (SFC Scan Now)..." -ForegroundColor Blue
        $SFCResult = sfc /scannow
        Write-Output $SFCResult
    }
}
[CleanFactory]::Register(1, { return [SFCScan]::new() })

class DiskCheck : CleanMethod {
    [void] CleanOption() {
        Write-Host "`nRunning CheckDisk..." -ForegroundColor Blue
        Write-Output Y | chkdsk C: /f /r /x | Out-Null
        $BootExecute = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "BootExecute"
        if($BootExecute.BootExecute -match "autocheck chkntfs") {
            Write-Host "CHKDSK successfully scheduled to run on next reboot..." -ForegroundColor Green
        } else {
            Write-Warning "CHDSK scheduling could not be verified. Check manually or rerun separately..."
        }
        [CleanFactory]::RestartRequired = $true
    }
}
[CleanFactory]::Register(2, { return [DiskCheck]::new() })

class GPUpdate : CleanMethod {
    [void] CleanOption() {
        Write-Host "`nForcing Group Policy Update..." -ForegroundColor Blue
        gpupdate /force /Logon /Boot
        [CleanFactory]::RestartRequired = $true
    }
}
[CleanFactory]::Register(3, { return [GPUpdate]::new() })

class DeleteExcessProfiles : CleanMethod {
    [void] CleanOption() {
        Write-Host "`nDeleting excess profiles..." -ForegroundColor Blue
        $WhiteList = @("Administrator", "Public", "All Users", "Default")
        $CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name.Split('\')[-1]
        if($CurrentUser -notin $WhiteList) {
            $WhiteList += $CurrentUser
            Write-Host "Added '$CurrentUser' to the whitelist" -ForegroundColor DarkGray
        }
        Write-Host "Currently whitelisted profiles: $($WhiteList -join ", ")`n" -ForegroundColor DarkGray
        $DaysOld = 45
        $CutDate = (Get-Date).AddDays(-$DaysOld[0])

        write-Host cutdate is $CutDate
        
        $ProfliesToDelete = Get-CimInstance -ClassName Win32_UserProfile | Where-Object {
            $_.Special -eq $false -and
            ($_.LocalPath | Split-Path -Leaf) -notin $WhiteList -and
            $_.LastUseTime -lt $CutDate
        }
        Write-Host "Found $($ProfliesToDelete.Count) profiles older than $DaysOld days that are not whitelisted." -ForegroundColor Yellow
        foreach($ProfileInstance in $ProfliesToDelete) {
            Write-Host "Deleting profile: $($ProfileInstance.LocalPath)" -ForegroundColor Green
            Remove-CimInstance -InputObject $ProfileInstance
        }
    }
}
[CleanFactory]::Register(4, { return [DeleteExcessProfiles]::new() })

class DeleteCacheInstances : CleanMethod {
    [void] CleanOption() {
        Write-Host "`nDeleting multiple cache instances..." -ForegroundColor Blue
        $SystemTemp = $env:SystemRoot + "C:\Temp"
        $UserTemp = $env:TEMP
        $DriveTemp = "C:\Temp"
        
        Format-List @($SystemTemp, $UserTemp, $DriveTemp) | ForEach-Object {
            if(Test-Path $_) {
                Write-Output "Clearing: $_"
                Remove-Item -Path "$_\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        
        try {
            $CCMCache = New-Object -ComObject UIResource.UIResourceMgr
            $CacheInfo = $CCMCache.GetCacheInfo()
            $Elements = $CacheInfo.GetCacheElements()
        
            if($Elements) {
                Write-Output "Found $($Elements.Count) items in CCM Cache. Deleting..."
                foreach ($Element in $Elements) {
                    $CacheInfo.DeleteCacheElement($Element.CacheElementID)
                }
                Write-Output "CCM Cache cleared safely" -ForegroundColor Green
            } else {
                Write-Output "CCM Cache is already empty" -ForegroundColor Magenta
            }
        } catch {
            Write-Warning "Failed to clear SCCM Cache: $_"
        }
    }
}
[CleanFactory]::Register(5, { return [DeleteCacheInstances]::new() })

class DeleteOutlookCache : CleanMethod {
    [void] CleanOption() {
        Write-Output "`nClearing Outlook Cache..." -ForegroundColor Blue
        $OutlookProcess = Get-Process -Name "outlook" -ErrorAction SilentlyContinue
        
        if($OutlookProcess) {
            $OutlookProcess.CloseMainWindow() | Out-Null
            $Timeout = 10
            $Counter = 0
            while((Get-Process -Name "outlook" -ErrorAction SilentlyContinue) -and ($Counter -lt $Timeout)) {
                Start-Sleep -Seconds 1
                $Counter++
            }
            if(Get-Process -Name "outlook" -ErrorAction SilentlyContinue) {
                Write-Output "Outlook failed to close gracefully. Force Teminating..." -ForegroundColor Red
                Stop-Process -Name "outlook" -Force
                Start-Sleep -Seconds 2
            } else {
                Write-Output "Outlook successfully terminated" -ForegroundColor Green
            }
        }
        
        $OSTFolder = Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\Outlook"
        if(Test-Path -Path $OSTFolder) {
            $OSTFiles = Get-ChildItem -Path $OSTFolder -Filter "*.ost" -File
            if($OSTFiles) {
                foreach($File in $OSTFiles) {
                    try {
                        Write-Output "Attempting to delete: $($File.FullName)"
                        Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop
                        Write-Output "Successfully deleted: $($File.Name)" -ForegroundColor Green
                    } catch {
                        Write-Error "Failed to delete $($File.Name)"
                    }
                }
            } else {
                Write-Output "No .ost files were found in the directory..." -ForegroundColor Magenta
            }
        } else {
            Write-Output "Outlook data directory not found at $OSTFolder" -ForegroundColor Magenta
        }
    }
}
[CleanFactory]::Register(6, { return [DeleteOutlookCache]::new() })


#New Methods added above this one
#Increment number that is 7 lines below to push "Exit Application" lowest
class ExitApplication : CleanMethod {
    [void] CleanOption() {
        [CleanFactory]::ExitApplication = $true
        Write-Host "Exiting Application..." -ForegroundColor Blue
        return
    }
}
[CleanFactory]::Register(7, { return [ExitApplication]::new() })



function Invoke-CleanOptions {
    Param (
        $Controller
    )
    $selectedMethod = [CleanFactory]::Create($Controller)
    $selectedMethod.CleanOption()
}

function Invoke-Restart {
    $msgText = "Computer requires a restart to finish updates. Restart Now?"
    $msgTitle = "System Restart Notice"
    $msgButton = [System.Windows.MessageBoxButton]::YesNo
    $msgIcon = [System.Windows.MessageBoxImage]::Warning

    $response = [System.Windows.MessageBox]::Show($msgText, $msgTitle, $msgButton, $msgIcon)
    return $response
}

function Invoke-UserIntegerInput {
    $IsValid = $false

    [CleanFactory]::CleanMethods.GetEnumerator() | ForEach-Object {
        Write-Host "$($_.Key): $($_.Value.Method.Name)"
    }

    do {
        $UserInput = Read-Host -Prompt "Please select an option"
        $ConvertedInput = $UserInput -as [uint32]
        if($null -ne $ConvertedInput -and [CleanFactory]::CleanMethods.ContainsKey($ConvertedInput)) {
            $IsValid = $true
            return $ConvertedInput
        } else {
            Write-Host "Invalid input. Please enter a valid option."
        }
    } while (-not $IsValid)
}


function Invoke-Main {
    Invoke-ContinueOrExit
    do {
        $MainInput = Invoke-UserIntegerInput
        Invoke-CleanOptions -Controller $MainInput
        if ([CleanFactory]::RestartRequired) {
            $UserResponse = Invoke-Restart
            if($UserResponse -eq 'Yes') {
                try {
                    Restart-Computer -Force -ErrorAction Stop
                } catch {
                    Write-Warning "Failed to initiate restart: $_"
                }
            }
        }
    } while (-not [CleanFactory]::ExitApplication)
}

#Main Start
Invoke-Main