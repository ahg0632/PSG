Add-Type -AssemblyName PresentationFramework
function Invoke-CheckAdmin {
    if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return $true
    } else {
        return $false
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
    }

    static [CleanMethod] Create([int]$option) {
        if (-not ([CleanFactory]::CleanMethods.ContainsKey($option))) {
            throw [System.NotImplementedException]::new("Clean method for option $option is not implemented or does not exist.")
        }
        return & ([CleanFactory]::CleanMethods[$option])
    }
}

class SFCScan : CleanMethod {
    [void] CleanOption() {
        Write-Host "`nRunning SFC Scan...`n" -ForegroundColor Blue
        $SFCStart = Start-Job -ScriptBlock { sfc /scannow } -Name "SFC Scan" -ErrorAction SilentlyContinue
        $SFCResult = Receive-Job -Job $SFCStart -Wait -AutoRemoveJob
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
            Write-Host "CheckDisk successfully scheduled to run on next reboot...`n" -ForegroundColor Green
        } else {
            Write-Warning "CheckDisk scheduling could not be verified. Check manually or rerun separately...`n"
        }
        [CleanFactory]::RestartRequired = $true
    }
}
[CleanFactory]::Register(2, { return [DiskCheck]::new() })

class GPUpdate : CleanMethod {
    [void] CleanOption() {
        Write-Host "`nForcing GPUpdate...`n" -ForegroundColor Blue
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
        Write-Host "Currently whitelisted profiles: $($WhiteList -join ", ")" -ForegroundColor DarkGray
        
        $DaysOld = 45
        $CutDate = (Get-Date).AddDays(-$DaysOld[0])
        
        $ProfliesToDelete = Get-CimInstance -ClassName Win32_UserProfile | Where-Object {
            $_.Special -eq $false -and
            ($_.LocalPath | Split-Path -Leaf) -notin $WhiteList -and
            $_.LastUseTime -lt $CutDate
        }
        Write-Host "Found $($ProfliesToDelete.Count) profiles older than $DaysOld days to delete" -ForegroundColor Yellow
        foreach($ProfileInstance in $ProfliesToDelete) {
            Write-Host "Deleting profile: $($ProfileInstance.LocalPath)" -ForegroundColor Green
            Remove-CimInstance -InputObject $ProfileInstance
        }
        Write-Host "Profile cleanup completed.`n" -ForegroundColor Blue
    }
}
[CleanFactory]::Register(4, { return [DeleteExcessProfiles]::new() })

class DeleteCacheInstances : CleanMethod {
    [void] CleanOption() {
        Write-Host "`nDeleting multiple cache instances..." -ForegroundColor Blue
        $DriveTemp = "C:\Temp"
        $SystemTemp = $env:SystemRoot + $DriveTemp.Substring(2)
        $UserTemp = $env:TEMP
        
        Format-List @($SystemTemp, $UserTemp, $DriveTemp) | ForEach-Object {
            if(Test-Path $_) {
                Write-Host "Clearing: $_"
                Remove-Item -Path "$_\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        
        # Clear SCCM Cache
        try {
            $CCMCache = New-Object -ComObject UIResource.UIResourceMgr
            $CacheInfo = $CCMCache.GetCacheInfo()
            $Elements = $CacheInfo.GetCacheElements()
        
            if($Elements) {
                Write-Host "Found $($Elements.Count) items in CCM Cache. Deleting..."
                foreach ($Element in $Elements) {
                    $CacheInfo.DeleteCacheElement($Element.CacheElementID)
                }
                Write-Host "CCM Cache cleared safely`n" -ForegroundColor Green
            } else {
                Write-Host "CCM Cache is already empty`n" -ForegroundColor Magenta
            }
        } catch {
            Write-Warning "Failed to clear SCCM Cache: $_`n"
        }
    }
}
[CleanFactory]::Register(5, { return [DeleteCacheInstances]::new() })

class DeleteOutlookCache : CleanMethod {
    [void] CleanOption() {
        Write-Host "`nClearing Outlook Cache..." -ForegroundColor Blue
        $OutlookProcess = Get-Process -Name "outlook" -ErrorAction SilentlyContinue
        
        if($OutlookProcess) {
            $OutlookProcess.CloseMainWindow() | Out-Null
            if(-not $OutlookProcess.WaitForExit(5000)) {
                Write-Host "Outlook failed to close gracefully. Force Teminating..." -ForegroundColor Red
                Stop-Process -Name "outlook" -Force
                Start-Sleep -Seconds 2
            } else {
                Write-Host "Outlook successfully terminated" -ForegroundColor Green
            }
        }
        
        try {
            $OSTFolder = Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\Outlook"
            if(Test-Path -Path $OSTFolder) {
                $OSTFiles = Get-ChildItem -Path $OSTFolder -Filter "*.ost" -File
                if($OSTFiles) {
                    foreach($File in $OSTFiles) {
                        try {
                            Write-Host "Attempting to delete: $($File.FullName)"
                            Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop
                            Write-Host "Successfully deleted: $($File.Name)" -ForegroundColor Green
                        } catch {
                            Write-Error "Failed to delete $($File.Name)"
                        }
                    }
                    Write-Host "Outlook cache cleared successfully.`n" -ForegroundColor Blue
                } else {
                    Write-Host "No .ost files were found in the directory..." -ForegroundColor Magenta
                }
            } else {
                Write-Host "Outlook data directory not found at $OSTFolder" -ForegroundColor Magenta
            }
        } catch {
            Write-Warning "An error occurred while attempting to clear the Outlook cache: $_`n"
        }
    }
}
[CleanFactory]::Register(6, { return [DeleteOutlookCache]::new() })


#New Methods added above this one
#Increment number that is 7 lines below to push "Exit Application" lowest
class ExitApplication : CleanMethod {
    [void] CleanOption() {
        [CleanFactory]::ExitApplication = $true
        Write-Host "Exiting Application...`n" -ForegroundColor Blue
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
    $msgText = "Computer requires a restart to finish health checks. Restart Now?"
    $msgTitle = "System Restart Notice"
    $msgButton = [System.Windows.MessageBoxButton]::YesNo
    $msgIcon = [System.Windows.MessageBoxImage]::Warning

    $response = [System.Windows.MessageBox]::Show($msgText, $msgTitle, $msgButton, $msgIcon)
    return $response
}

function Invoke-UserIntegerInput {
    foreach ($key in [System.Linq.Enumerable]::Reverse([object[]][CleanFactory]::CleanMethods.Keys)) {
        $cmdAst = [CleanFactory]::CleanMethods[$key].Ast.Find({
            param($ast) $ast -is [System.Management.Automation.Language.TypeExpressionAst]
        }, $true)
        $name = if ($cmdAst) { $cmdAst.TypeName } else { "Unknown" }
        Write-Host "$($key): $name" -ForegroundColor Cyan
    }
    
    $IsValid = $false
    do {
        $UserInput = Read-Host -Prompt "Please select an option"
        $ConvertedInput = $UserInput -as [int]
        if($null -ne $ConvertedInput -and [CleanFactory]::CleanMethods.ContainsKey($ConvertedInput)) {
            $IsValid = $true
            return $ConvertedInput
        } else {
            Write-Host "Invalid input. Please enter a valid option."
        }
    } while (-not $IsValid)
}


function Invoke-Main {
    if(-not (Invoke-CheckAdmin)) {
        Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        return
    }

    do {
        $MainInput = Invoke-UserIntegerInput
        Invoke-CleanOptions -Controller $MainInput
        if([CleanFactory]::RestartRequired) {
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