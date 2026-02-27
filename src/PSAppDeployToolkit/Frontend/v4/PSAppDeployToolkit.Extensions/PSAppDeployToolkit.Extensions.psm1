<#

.SYNOPSIS
PSAppDeployToolkit.Extensions - Provides the ability to extend and customize the toolkit by adding your own functions that can be re-used.

.DESCRIPTION
This module is a template that allows you to extend the toolkit with your own custom functions.

This module is imported by the Invoke-AppDeployToolkit.ps1 script which is used when installing or uninstalling an application.

#>

##*===============================================
##* MARK: MODULE GLOBAL SETUP
##*===============================================

# Set strict error handling across entire module.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1


##*===============================================
##* MARK: FUNCTION LISTINGS
##*===============================================
#Region DSM-Funktionen
function Write-FIRMADSMErrorMessage {
    # Lese Fehlerobjekt aus
    $errobj = $_
    $msg = ($errobj.Exception.message) 
    $line  = ($errobj.InvocationInfo.ScriptLineNumber) 
    $cmd   = ($errobj.InvocationInfo.MyCommand).name 

    # Begrenze String auf 255 - PSADT Zeile: $line CMD: $CMD Message: $msg -> 255 - 29(andere Zeichen) - 5($line) - 20($CMD)= 201 ($msg)
    if ($msg.Length -gt 201) { $msg = $msg.Substring(0,200)} # 201 Zeichen möglich
    if ($line.Length -gt 5) { $line = $line.Substring(0,4)} # 99999 Zeilen möglich
    if ($cmd.Length -gt 20) { $cmd = $cmd.Substring(0,19)} # 20 Zeilen möglich

    $ErrorMessage = "PSADT Zeile: $line CMD: $CMD Message: $msg"
    Write-ADTLogEntry -Message "An DSM zurückgegebene Fehlermeldung: $ErrorMessage" -Severity Info
    # Schreibe die Fehlermeldung in der Registry zur Übergabe an DSM (Klären, ob wir später auch unter ConfigMgr davon Gebrauch machen können)
	Set-ADTRegistryKey -Key "HKLM\SOFTWARE\InstalledApps\$PkgLongNameRev" -Name "ExitMessage" -Value $ErrorMessage -Type String -ErrorAction SilentlyContinue
}
#Endregion DSM-Funktionen
#Region Funktionen zur Behandlung von SWRP-Ausnahmen 
function Get-FIRMASwrpException {
	<#
	.SYNOPSIS
		Ermittelt eine Liste der SWRP-Ausnahmen
	.DESCRIPTION
		Ermittelt eine Liste der unter 'HKLM:\SOFTWARE\FIRMA\swrp' eingetragenen Ausnahmen von den Software Restrictions
	.EXAMPLE
		$SWRPListe = Get-FIRMASWRPException
	#>	
    $SWRPRegPath = 'HKLM:\SOFTWARE\FIRMA\swrp'
    $NummernListe = @{}
    if (Test-Path -Path $SWRPRegPath ) {
        $RegKey = (Get-ItemProperty $SWRPRegPath)
            $RegKey.PSObject.Properties | ForEach-Object {
            If($_.Name -like 'AddPath*'){
                $NummernListe.Add($_.Name, $_.Value)
                Write-ADTLogEntry -Message "$_.Name ' = ' $_.Value" -Severity Info
            }
        }
    }
    return $NummernListe
}
function New-FIRMASwrpException {
	<#
	.SYNOPSIS
		Fügt eine neue Ausnahme von den Software Restrictions hinzu
	.DESCRIPTION
		Fügt eine neue Ausnahme unter 'HKLM:\SOFTWARE\FIRMA\swrp' von den Software Restrictions hinzu
	.PARAMETER Pfad
		Der Dateipfad, der von den Software Restrictions ausgenommen werden soll.
	.EXAMPLE
		New-FIRMASWRPException -Pfad "D:\Programme"
	#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]  [String] $Pfad,
        [Parameter(Mandatory=$false)] [switch] $silent
    )
    $FIRMA = 'HKLM:\SOFTWARE\FIRMA'
    $SWRPRegPath = Join-Path -Path $FIRMA -ChildPath 'swrp'
    if ( -not (Test-Path -Path $SWRPRegPath) ) {
        New-Item -Path $FIRMA -Name 'swrp' -Force
    }
    $VorhandeneAusnahmen = Get-FIRMASWRPException
    # Prüfung, ob nicht schon vorhanden, fehlt noch
    $Key = $VorhandeneAusnahmen.GetEnumerator().Where({($_.Value).ToLower() -contains $Pfad.ToLower()})
    if (-not $Key) {
        $NeuerSWRPKey = "AddPath" + '{0:d2}' -f [int]($VorhandeneAusnahmen.Count + 1)
        try {
            New-ItemProperty -Path $SWRPRegPath -Name $NeuerSWRPKey -Value $Pfad | Out-Null
            if (-not $silent) {
                Write-ADTLogEntry -Message "Die SWRP-Ausnahme $NeuerSWRPKey`: $Pfad wurde erfolgreich angelegt." -Severity Info
            } 
        }
        catch {
            Write-ADTLogEntry -Message "Die SWRP-Ausnahme $NeuerSWRPKey`: $Pfad  konnte nicht angelegt werden." -Severity Warning 
        }
    }
    else {
        if (-not $silent) {
            Write-ADTLogEntry -Message "Die SWRP-Ausnahme $($Key.Name)`: $($Key.Value) war bereits vorhanden." -Severity Info
        }
    }
}
function Remove-FIRMASwrpException {
	<#
	.SYNOPSIS
		Löscht eine Ausnahme von den Software Restrictions hinzu
	.DESCRIPTION
		Löscht eine Ausnahme von den Software Restrictions unter 'HKLM:\SOFTWARE\FIRMA\swrp' 
	.PARAMETER Pfad
		Der Dateipfad, der von den Ausnahmen zu den Software Restrictions gelöscht werden soll.
	.EXAMPLE
		Remove-FIRMASWRPException -Pfad "D:\Programme"
	#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [String] $Pfad
    )
    $Ausnahmeliste = Get-FIRMASWRPException
	Write-ADTLogEntry "Entferne alle anfänglich vorhandene Ausnahmen:"
	$Ausnahmeliste.GetEnumerator()
    $Key = $Ausnahmeliste.GetEnumerator().Where({($_.Value).ToLower() -contains $Pfad.ToLower()})
    if ($Key) {
		try {
            if (Test-Path -Path 'HKLM:\SOFTWARE\FIRMA\swrp' ) {
                Remove-ItemProperty -Path 'HKLM:\SOFTWARE\FIRMA\swrp' -Name * 
            }         
        }
        catch {
			Write-ADTLogEntry -Message "Fehler beim Löschen der SWRP-Ausnahmen" -Severity Warning
            return "Fehler beim Löschen der SWRP-Ausnahmen" 
        }	
		$Ausnahmeliste.Remove($Key.Name)
        try {
			foreach ($Ausnahme in $Ausnahmeliste.GetEnumerator()) {
				New-FIRMASWRPException -Pfad $($Ausnahme.Value) -Silent
			}          
        }
        catch {
            Write-ADTLogEntry -Message "Fehler beim Löschen der SWRP-Ausnahme $($Key.Name)`: $($Key.Value). Die neue Liste konnte nicht angelegt werden." -Severity Warning
        }
    } 
    else {
        Write-ADTLogEntry -Message "Die SWRP-Ausnahme $Pfad war nicht vorhanden." -Severity Info
    }
    $Ausnahmeliste = Get-FIRMASWRPException
    Write-ADTLogEntry -Message "Ermittle die jetzt vorhandene Ausnahmen..." -Severity Info
    foreach ($Eintrag in ($Ausnahmeliste.GetEnumerator())) {
        Write-ADTLogEntry -Message "Name: $($Eintrag.Name) - Value: $($Eintrag.Value)" -Severity Info
    }
}
#Endregion Funktionen zur Behandlung von SWRP-Ausnahmen 
#Region Funktionen zur Installation und Deinstallation von Schriftfonts 
function Install-FIRMAFont {  
    param (
        [Parameter(Mandatory=$true)]
        [string]$FontPath,
        [Parameter(Mandatory=$true)]
        [string]$FontName # Anzeigename wie in der Registry: z.B. "My Font (TrueType)"
    )
    $fontsDir = "$env:SystemRoot\Fonts"
    $fontFileName = Split-Path $FontPath -Leaf
    $destFontPath = Join-Path $fontsDir $fontFileName
    # Schriftdatei kopieren
    Copy-ADTFile -Path $FontPath -Destination $destFontPath
    # Schrift in der Registry registrieren
    Set-ADTRegistryKey -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" -Name $FontName -Value $fontFileName
}
function Uninstall-FIRMAFont {  
    param (
        [Parameter(Mandatory=$true)]
        [string]$FontFileName, # Nur Dateiname, z.B. "myfont.ttf"
        [Parameter(Mandatory=$true)]
        [string]$FontName # Anzeigename wie in Registry: z.B. "My Font (TrueType)"
    )
    $fontsDir = "$env:SystemRoot\Fonts"
    $destFontPath = Join-Path $fontsDir $FontFileName
    # Registry-Eintrag entfernen
    Remove-ADTRegistryKey -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" -Name $FontName
    # Schriftdatei löschen  
    Remove-ADTFile -Path $destFontPath   
}  
#Endregion Funktionen zur Installation und Deinstallation von Schriftfonts
#Region Funktion zur Deinstallation von Anwendungen 
function Remove-FIRMAAllVersions {
    param (
        [Parameter(Mandatory)]
        [string]$AnwendungsSuchString,
        [Parameter(Mandatory)]
        [ValidateSet('Exact','Contains','Wildcard','Regex')]
        [string]$NameMatch
    )
    Write-ADTLogEntry "Prüfe anhand des Suchstrings `'$AnwendungsSuchString`', ob alte Versionen der Anwendung $AppFriendlyName installiert sind und deinstalliere diese..."
    [PSADT.Types.InstalledApplication[]]$AlleAnwendungen = Get-ADTApplication -Name $AnwendungsSuchString -NameMatch $NameMatch
    if ( ($null -ne $AlleAnwendungen) -and ($AlleAnwendungen.Count -gt 0)) {
        ForEach ($Anwendung in $AlleAnwendungen) {
            Write-ADTLogEntry "Deinstalliere $($Anwendung.DisplayName)..."
            if (Test-Path -Path $Anwendung.UninstallStringFilePath ) {
                Uninstall-ADTApplication -InstalledApplication $Anwendung
            }
            else {
                Write-ADTLogEntry -Message "$($Anwendung.DisplayName) kann nicht deinstalliert werden." -Severity Warning
            }
        }
    }
    else {
        Write-ADTLogEntry "Keine vorhandene Installation von $($Anwendung.DisplayName) mit dem Suchstring `'$AnwendungsSuchString`' gefunden."		
    }
} 
#Endregion Funktion zur Deinstallation von Anwendungen 

##*===============================================
##* MARK: SCRIPT BODY
##*===============================================

# Announce successful importation of module.
Write-ADTLogEntry -Message "Module [$($MyInvocation.MyCommand.ScriptBlock.Module.Name)] imported successfully." -ScriptSection Initialization
