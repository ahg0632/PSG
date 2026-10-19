function Check-Admin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        Exit
    }
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ContinueOrExit {
    $title = "Perform Cleanup Operations"
    $message = "Do you want to continue?"
    $options = [System.Management.Automation.Host.ChoiceDescription[]]@(
        [System.Management.Automation.Host.ChoiceDescription]::new("&Yes", "Continue with the script"),
        [System.Management.Automation.Host.ChoiceDescription]::new("&No", "Exit the script")
    )
    $result = $host.ui.PromptForChoice($title, $message, $options, 1)
    return [bool]$result
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
        Write-Host "`nRunning SFC Scan..." -ForegroundColor Blue
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
            Write-Host "CheckDisk successfully scheduled to run on next reboot..." -ForegroundColor Green
        } else {
            Write-Warning "CheckDisk scheduling could not be verified. Check manually or rerun separately..."
        }
        [CleanFactory]::RestartRequired = $true
    }
}
[CleanFactory]::Register(2, { return [DiskCheck]::new() })

class GPUpdate : CleanMethod {
    [void] CleanOption() {
        Write-Host "`nForcing GPUpdate..." -ForegroundColor Blue
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
        Write-Host "Found $($ProfliesToDelete.Count) profiles older than $DaysOld days to delete" -ForegroundColor Yellow
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
                Write-Host "CCM Cache cleared safely" -ForegroundColor Green
            } else {
                Write-Host "CCM Cache is already empty" -ForegroundColor Magenta
            }
        } catch {
            Write-Warning "Failed to clear SCCM Cache: $_"
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
            } else {
                Write-Host "No .ost files were found in the directory..." -ForegroundColor Magenta
            }
        } else {
            Write-Host "Outlook data directory not found at $OSTFolder" -ForegroundColor Magenta
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
    $msgText = "Computer requires a restart to finish health checks. Restart Now?"
    $msgTitle = "System Restart Notice"
    $msgButton = [System.Windows.MessageBoxButton]::YesNo
    $msgIcon = [System.Windows.MessageBoxImage]::Warning

    $response = [System.Windows.MessageBox]::Show($msgText, $msgTitle, $msgButton, $msgIcon)
    return $response
}

function Invoke-UserIntegerInput {
    # [CleanFactory]::CleanMethods.GetEnumerator() | ForEach-Object {
    #     Write-Host "$($_.Key): $($_.Value.Method)" -ForegroundColor Cyan
    # }
    foreach ($key in [System.Linq.Enumerable]::Reverse([object[]][CleanFactory]::CleanMethods.Keys)) {
        $scriptBlock = [CleanFactory]::CleanMethods[$key]
        $cmdAst = $scriptBlock.Ast.Find({ param($ast) $ast -is [System.Management.Automation.Language.CommandAst] }, $true)
        $name = if ($cmdAst) { $cmdAst.CommandElements[1].Value } else { "Unknown" }
        # Write-Host "$key : $([CleanFactory]::CleanMethods[$key].Value.Method)" -ForegroundColor Cyan
        Write-Host "$key : $name" -ForegroundColor Cyan
    }
    
    $IsValid = $false
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
    # if(Invoke-ContinueOrExit) {
    #     Write-Host "Exiting script..." -ForegroundColor DarkCyan
    #     return
    # }

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