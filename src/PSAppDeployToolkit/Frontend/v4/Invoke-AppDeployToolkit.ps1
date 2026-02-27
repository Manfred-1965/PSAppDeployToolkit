<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- The script is provided as a template to perform an install, uninstall, or repair of an application(s).
- The script either performs an "Install", "Uninstall", or "Repair" deployment type.
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

.PARAMETER DeploymentType
The type of deployment to perform.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive (shows dialogs), Silent (no dialogs), NonInteractive (dialogs without prompts) mode, or Auto (shows dialogs if a user is logged on, device is not in the OOBE, and there's no running apps to close).

Silent mode is automatically set if it is detected that the process is not user interactive, no users are logged on, the device is in Autopilot mode, or there's specified processes to close that are currently running.

.PARAMETER SuppressRebootPassThru
Suppresses the 3010 return code (requires restart) from being passed back to the parent process (e.g. SCCM) if detected from an installation. If 3010 is passed back to SCCM, a reboot prompt will be triggered.

.PARAMETER TerminalServerMode
Changes to "user install mode" and back to "user execute mode" for installing/uninstalling applications for Remote Desktop Session Hosts/Citrix servers.

.PARAMETER DisableLogging
Disables logging to file for the script.

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1 -DeployMode Silent

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1 -DeploymentType Uninstall

.EXAMPLE
Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent

.INPUTS
None. You cannot pipe objects to this script.

.OUTPUTS
None. This script does not generate any output.

.NOTES
Toolkit Exit Code Ranges:
- 60000 - 68999: Reserved for built-in exit codes in Invoke-AppDeployToolkit.ps1, and Invoke-AppDeployToolkit.exe
- 69000 - 69999: Recommended for user customized exit codes in Invoke-AppDeployToolkit.ps1
- 70000 - 79999: Recommended for user customized exit codes in PSAppDeployToolkit.Extensions module.

.LINK
https://psappdeploytoolkit.com

#>

[CmdletBinding()]
param
(
    # Default is 'Install'.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    # Default is 'Auto'. Don't hard-code this unless required.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)

##================================================
## MARK: Variables
##================================================

$adtSession = @{
    # App variables.
    AppVendor = ''
    AppName = ''
    AppVersion = ''
    AppArch = ''
    AppLang = ''
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @() # Example: @('excel', @{ Name = 'winword'; Description = 'Microsoft Word' })
    AppScriptVersion = '1.0.0'
    AppScriptDate = '' # 'MM/dd/YYYY'
    AppScriptAuthor = ''
    AppInstallationsanleitung = '' # Soll über die Eingabemaske mit dem Confluence-Kurzlink befüllt werden
    RequireAdmin = $true

    # Install Titles (Only set here to override defaults set by the toolkit).
    InstallName = ''
    InstallTitle = ''

    # Script variables.
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.7'
}
#================================================================================================
#Region FIRMA-Variablen
#================================================================================================
# FIRMA: Globale Variablen, die bei Installation, Reparatur und Deinstallation verwendet werden
#================================================================================================
$AppFriendlyName = "$($adtSession.AppVendor) $($adtSession.AppName)"
$ActiveSetupKey = $AppFriendlyName
# FIRMA: Zusammengesetzter Paketname (wird für Detection verwendet)
$PkgLongNameRev = "$($adtSession.AppVendor)_$($adtSession.AppName)_$($adtSession.AppVersion)_$($adtSession.AppArch)_$($adtSession.AppLang)_$($adtSession.AppRevision)"
$InstalledAppRegKey = "HKLM\SOFTWARE\InstalledApps\$PkgLongNameRev"
#================================================================================================
# FIRMA: Variablen zur Steuerung des Paketverhaltens
#================================================================================================
# FIRMA: Zusätzliche Parameter für MSI-Installation bei Bedarf erweitern z.B. MSIRESTARTMANAGERCONTROL=Disable MSIDISABLERMRESTART=1
#       ('REBOOT=ReallySuppress /QN' bereits in config.psd1 definiert )
$msiFIRMAAdditionalArgumentList = "ALLUSERS=1"
# FIRMA: Meldungs- und Fortschrittsbalken anzeigen? Yes/No
$ShowMessages = "Yes"
# FIRMA: ActiveSetup erneut ausführen, wenn es schon mal z.B. in der Vorgängerversion gelaufen ist? Yes/No
# "No" entspricht dem Verhalten in DSM, wenn ein Software-Set revisioniert wurde, die USR Komponente jedoch unverändert bleibt.
$ActiveSetupRunAgain = "Yes"
#Endregion FIRMA-Variablen
#================================================================================================
#Region Anwendungen beenden
function Get-FIRMAAppsToClose {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [String] $Pfad,
        [String] $BeschreibungsPrefix
    )
    $AppProcessesToClose = New-Object -TypeName "System.Collections.ArrayList"
    $Programme = Get-ChildItem -Path $Pfad -Filter "*.exe" -Recurse
    foreach ($Programm in $Programme) {
        $FullName = $Programm.FullName
        $Name = "$(($Programm.Name).TrimEnd(",.exe"))"
        $Beschreibung = "$BeschreibungsPrefix $Name"
        $AppProcessesToClose.Add( @{ Name = $FullName; Description = $Beschreibung })
    }
    return $AppProcessesToClose
}
#Endregion Anwendungen beenden
function Install-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Install
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    # Entferne letzte gespeicherte Fehlermeldung aus der Registry
    if ( Test-ADTRegistryValue -Key $InstalledAppRegKey -Name "ExitMessage" ) {
        Remove-ADTRegistryKey -Key $InstalledAppRegKey -Name "ExitMessage"
    }
    # FIRMA: Pfad zum Setup-Protokoll (gilt für setup.exe etc., nicht für MSI )
    $InstLogPath =   "`"$((Get-ADTConfig).Toolkit.LogPath)\$($adtSession.InstallName)-Install.log`""

    ## Show Welcome Message, close processes if specified, allow up to 3 deferrals, verify there is enough disk space to complete the install, and persist the prompt.
    # FIRMA: Subtitle hinzugefügt
    $saiwParams = @{
        AllowDefer = $true
        DeferTimes = 3
		CloseProcessesCountdown = 7200 # 120 Minuten
        CheckDiskSpace = $true
        PersistPrompt = $true
        Subtitle = "FIRMA Softwareverteilung - Installation"
    }
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
    }
    # FIRMA: Protokollierung der Voreinstellungen zur Benutzerinteraktion
    Write-ADTLogEntry -Message "Anzeige von Benutzermeldungen: $ShowMessages" -Severity Info  
	# Zeige das Willkommensfenster nur an, wenn wirklich Prozesse zu beenden sind
    if ( $adtSession.AppProcessesToClose -and ($null -ne (Get-ADTRunningProcesses -ProcessObjects $adtSession.AppProcessesToClose))) {
        Show-ADTInstallationWelcome @saiwParams
    }
	else {
        Write-ADTLogEntry -Message "Welcome-Meldung wird nicht angezeigt, weil keine Prozesse zu beenden wird." -Severity Info
    }	  
    # FIRMA: Fortschrittsbenachrichtigung anzeigen, falls gewünscht
    if ($ShowMessages -eq "Yes") {
        Show-ADTInstallationProgress -Subtitle $saiwParams.Subtitle -StatusMessageDetail "Dieses Fenster wird automatisch geschlossen, wenn die Installation von $($adtSession.AppName) abgeschlossen ist."
    }
    ## <Perform Pre-Installation tasks here>

    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## <Perform Installation tasks here>

    #================================================================================================
    #Region FIRMA: Benutzerteil (Active Setup)
    #================================================================================================
	$InvokeAppDeployToolkitUser = "$PSScriptRoot\User\Invoke-AppDeployToolkit.ps1"
    # Wenn Benutzerteil vorhanden, dann Active Setup einrichten und ausführen
    if (Test-Path "$InvokeAppDeployToolkitUser") {
        Write-ADTLogEntry -Message "Benutzerteil vorhanden - Dateien für ActiveSetup werden kopiert..." -Severity Info
        $ActiveSetupFolder = "$env:programfiles\FIRMA\ActiveSetup\$ActiveSetupKey"
        New-ADTFolder -Path $ActiveSetupFolder
	    # PSAppDeploy Toolkit und  Inhalt des Ordners User kopieren
        Copy-ADTFile -Path "$PSScriptRoot\Assets" -Destination "$ActiveSetupFolder" -Recurse
        Copy-ADTFile -Path "$PSScriptRoot\Config" -Destination "$ActiveSetupFolder" -Recurse
        Copy-ADTFile -Path "$PSScriptRoot\PSAppDeployToolkit" -Destination "$ActiveSetupFolder" -Recurse
        Copy-ADTFile -Path "$PSScriptRoot\PSAppDeployToolkit.Extensions" -Destination "$ActiveSetupFolder" -Recurse
        Copy-ADTFile -Path "$PSScriptRoot\Invoke-AppDeployToolkit.exe" -Destination "$ActiveSetupFolder"
        Copy-ADTFile -Path "$PSScriptRoot\User\Invoke-AppDeployToolkit.ps1" -Destination "$ActiveSetupFolder"
        if ( Test-Path -Path "$PSScriptRoot\User\Files" ) {
            Copy-ADTFile -Path "$PSScriptRoot\User\Files" -Destination "$ActiveSetupFolder" -Recurse    
        }
        # Active Setup einrichten
        Write-ADTLogEntry -Message "ActiveSetup wird eingerichtet..." -Severity Info
        $StubArguments = "/c start `"`" `"$ActiveSetupFolder\Invoke-AppDeployToolkit.exe`" `"-DeployMode Interactive`" "
        # Ist Active Setup bereits gelaufen?
        if (Test-ADTRegistryValue -Key "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Active Setup\Installed Components\$ActiveSetupKey" -Name "Version") {
            # dann Active Setup nur erneut ausführen, wenn dies so gewollt ist
            Write-ADTLogEntry -Message "ActiveSetup erneut ausführen: $ActiveSetupRunAgain" -Severity Info
            If ($ActiveSetupRunAgain -eq "Yes") {
                Set-ADTActiveSetup -StubExePath "$envWindir\System32\cmd.exe" -Key $ActiveSetupKey -Arguments "$StubArguments" -NoExecuteForCurrentUser
                # Wenn aktuell ein Benutzer angemeldet ist, dann Active Setup sofort ausführen
                if ($RunAsActiveUser) {
                    Start-ADTProcessAsUser -FilePath "$envWindir\System32\runonce.exe" -ArgumentList " /AlternateShellStartup"
                    Start-Sleep -Seconds 10
                }
            } else {
                # Sonst Meldungsfenster ausgeben
                if ($ShowMessages -eq "Yes") {
                    Show-ADTInstallationPrompt -Message "Aktualisierung von $AppFriendlyName abgeschlossen." -ButtonMiddleText 'Ok' -NoWait -Subtitle "FIRMA Softwareverteilung - Aktualisierung der Anwendung"
                }
            } 
        } else {
            # Active Setup erstmalig einrichten
            Write-ADTLogEntry -Message "ActiveSetup wird erstmalig eingerichtet..." -Severity Info
            Set-ADTActiveSetup -StubExePath "$envWindir\System32\cmd.exe" -Key $ActiveSetupKey -Arguments "$StubArguments" -NoExecuteForCurrentUser
            # Wenn aktuell ein Benutzer angemeldet ist, dann Active Setup sofort ausführen
            if ($RunAsActiveUser) {
                Write-ADTLogEntry -Message "ActiveSetup wird für den angemeldeten Benutzer sofort ausgeführt..." -Severity Info
                Start-ADTProcessAsUser -FilePath "$envWindir\System32\runonce.exe" -ArgumentList " /AlternateShellStartup"
                Start-Sleep -Seconds 10
            }
        }
    } else {
	    # Sonst Meldungsfenster ausgeben
        Write-ADTLogEntry -Message "Kein Benutzerteil vorhanden." -Severity Info
        if ($ShowMessages -eq "Yes") {
            Show-ADTInstallationPrompt -Message "Installation von $AppFriendlyName abgeschlossen." -ButtonMiddleText 'Ok' -NoWait -Subtitle "FIRMA Softwareverteilung - Installation der Anwendung"
        }
    }
    #Endregion FIRMA: Benutzerteil (Active Setup)
    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Installation tasks here>
    # FIRMA: Registry-Eintrag zur Anwendungserkennung
	Set-ADTRegistryKey -Key $InstalledAppRegKey -Name "Status" -Value "installiert" -Type String

    ## Display a message at the end of the install.
    if (!$adtSession.UseDefaultMsi)
    {
        #FIRMA: Anzeige einer Message steht oben am Ende des Install-Teils (bzw. bei vorhandenem Benutzteil am Ende dessen)
        #Show-ADTInstallationPrompt -Message 'You can customize text to appear at the end of an install or remove it completely for unattended installations.' -ButtonRightText 'OK' -Icon Information -NoWait
    }
}

function Uninstall-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    # Entferne letzte gespeicherte Fehlermeldung aus der Registry
    if ( Test-ADTRegistryValue -Key $InstalledAppRegKey -Name "ExitMessage" ) {
        Remove-ADTRegistryKey -Key $InstalledAppRegKey -Name "ExitMessage"
    }

    # FIRMA: Pfad zum Setup-Protokoll (gilt für setup.exe etc., nicht für MSI )
    $UninstLogPath = "`"$((Get-ADTConfig).Toolkit.LogPath)\$($adtSession.InstallName)-Uninstall.log`""
    $saiwParams = @{
        AllowDefer = $false
		CloseProcessesCountdown = 300 # 5 Minuten
        PersistPrompt = $true
        Subtitle = "FIRMA Softwareverteilung - Deinstallation"
    }
    ## If there are processes to close, show Welcome Message with a 60 second countdown before automatically closing.
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
        Show-ADTInstallationWelcome @saiwParams
    }
    # FIRMA: Fortschrittsbenachrichtigung anzeigen, falls gewünscht
    if ($ShowMessages -eq "Yes") {
        Show-ADTInstallationProgress -Subtitle $saiwParams.Subtitle -StatusMessageDetail "Dieses Fenster wird automatisch geschlossen, wenn die Deinstallation von $($adtSession.AppName) abgeschlossen ist."
    }

    ## <Perform Pre-Uninstallation tasks here>

    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## <Perform Uninstallation tasks here>

    ##================================================
    ## FIRMA: ActiveSetup vollständig entfernen
    ##================================================
    Write-ADTLogEntry -Message "ActiveSetup wird für alle User entfernt..." -Severity Info
	$InvokeAppDeployToolkitUser = "$PSScriptRoot\User\Invoke-AppDeployToolkit.ps1"
    if (Test-Path "$InvokeAppDeployToolkitUser") {
	    # ActiveSetup entfernen
        $ActiveSetupFolder = "$env:programfiles\FIRMA\ActiveSetup\$ActiveSetupKey"
        Remove-ADTFolder -Path "$ActiveSetupFolder"
        Set-ADTActiveSetup -Key $ActiveSetupKey -PurgeActiveSetupKey
    }
    else {
        Write-ADTLogEntry -Message "$InvokeAppDeployToolkitUser nicht vorhanden" -Severity Warning    
    }

    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
    ## <Perform Post-Uninstallation tasks here>
    # FIRMA: Registry-Eintrag zur Anwendungserkennung
    Set-ADTRegistryKey -Key $InstalledAppRegKey -Name "Status" -Value "deinstalliert" -Type String									
}

function Repair-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Repair
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    # Entferne letzte gespeicherte Fehlermeldung aus der Registry
    if ( Test-ADTRegistryValue -Key $InstalledAppRegKey -Name "ExitMessage" ) {
        Remove-ADTRegistryKey -Key $InstalledAppRegKey -Name "ExitMessage"
    }

    # FIRMA: Pfad zum Setup-Protokoll (gilt für setup.exe etc., nicht für MSI )
    $UninstLogPath = "`"$((Get-ADTConfig).Toolkit.LogPath)\$($adtSession.InstallName)-Uninstall.log`""	
    $InstLogPath =   "`"$((Get-ADTConfig).Toolkit.LogPath)\$($adtSession.InstallName)-Install.log`""
	
    $saiwParams = @{
        AllowDefer = $false
		CloseProcessesCountdown = 300 # 5 Minuten
        PersistPrompt = $true
        Subtitle = "FIRMA Softwareverteilung - Reparatur"
    }
    ## If there are processes to close, show Welcome Message with a 60 second countdown before automatically closing.
    # FIRMA: Protokollierung der Voreinstellungen zur Benutzerinteraktion
    Write-ADTLogEntry -Message "Anzeige von Benutzermeldungen: $ShowMessages" -Severity Info  
	# Zeige das Willkommensfenster nur an, wenn wirklich Prozesse zu beenden sind
    if ( $adtSession.AppProcessesToClose -and ($null -ne (Get-ADTRunningProcesses -ProcessObjects $adtSession.AppProcessesToClose))) {
        Show-ADTInstallationWelcome @saiwParams
    }
	else {
        Write-ADTLogEntry -Message "Welcome-Meldung wird nicht angezeigt, weil keine Prozesse zu beenden wird." -Severity Info
    }	  
    # FIRMA: Fortschrittsbenachrichtigung anzeigen, falls gewünscht	
    if ($ShowMessages -eq "Yes") {
        Show-ADTInstallationProgress -Subtitle $saiwParams.Subtitle -StatusMessageDetail "Dieses Fenster wird automatisch geschlossen, wenn die Reparatur von $($adtSession.AppName) abgeschlossen ist."
    }
    ## <Perform Pre-Repair tasks here>

    ##================================================
    ## MARK: Repair
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## <Perform Repair tasks here>

    ##================================================
    ## MARK: Post-Repair
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Repair tasks here>
    # FIRMA: Registry-Eintrag zur Anwendungserkennung
    Set-ADTRegistryKey -Key $InstalledAppRegKey -Name "Status" -Value "installiert" -Type String									
}

##================================================
## MARK: Initialization
##================================================

# Set strict error handling across entire operation.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Import the module and instantiate a new session.
try
{
    # Import the module locally if available, otherwise try to find it from PSModulePath.
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.7' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.7' } -Force
    }

    # Open a new deployment session, replacing $adtSession with a DeploymentSession.
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    <# FIRMA: Option -NoProcessDetection hinzugefügt, damit die Session nicht in den Silent-Mode umschaltet, wenn keine zu beendenden
       Prozesse gefunden werden. #>
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru -NoProcessDetection
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

# Commence the actual deployment operation.
try
{
    # Import any found extensions before proceeding with the deployment.
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process
        {
            if ($_.Name -match 'PSAppDeployToolkit\..+$')
            {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name $_.FullName -Force
            }
        }
    }

    # Invoke the deployment and close out the session.
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    # An unhandled error has been caught.
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3

    ## Error details hidden from the user by default. Show a simple dialog with full stack trace:
    # Show-ADTDialogBox -Text $mainErrorMessage -Icon Stop -NoWait

    ## Or, a themed dialog with basic error message:
    # Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) failed at line $($_.InvocationInfo.ScriptLineNumber), char $($_.InvocationInfo.OffsetInLine):`n$($_.InvocationInfo.Line.Trim())`n`nMessage:`n$($_.Exception.Message)" -MessageAlignment Left -ButtonRightText OK -Icon Error -NoWait

    # FIRMA: Schreibe die Fehlermeldung in der Registry zur Übergabe an DSM
    Write-FIRMADSMErrorMessage
    Close-ADTSession -ExitCode 60001
}

