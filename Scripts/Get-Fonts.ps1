<#
    .SYNOPSIS
    Retrieves registered fonts

    .DESCRIPTION
    Enumerates all registered fonts, performs basic consistency checks, and returns the font name and associated file for each font.

    A font is registered and passes consistency checks if it is listed in the registry and the referenced font file is valid.

    Warnings are printed for registered fonts missing their associated font file and font files missing an associated registration.

    .PARAMETER Scope
    Specifies whether to enumerate system fonts or per-user fonts.

    Support for per-user fonts is only available from Windows 10 1809 and Windows Server 2019.

    The default is system fonts.

    .EXAMPLE
    Get-Fonts

    Retrieves all registered fonts in the system scope and outputs warnings for any inconsistencies.

    .NOTES
    Only OpenType (.otf) and TrueType (.ttf) fonts are supported.

    Per-user fonts are only enumerated in the context of the user executing the function.

    .LINK
    https://github.com/ralish/PSWinGlue
#>

#Requires -Version 3.0

[CmdletBinding()]
[OutputType([PSCustomObject[]])]
Param(
    [ValidateSet('System', 'User')]
    [String]$Scope = 'System'
)

$PowerShellCore = New-Object -TypeName Version -ArgumentList 6, 0
if ($PSVersionTable.PSVersion -ge $PowerShellCore -and $PSVersionTable.Platform -ne 'Win32NT') {
    throw '{0} is only compatible with Windows.' -f $MyInvocation.MyCommand.Name
}

# Supported font extensions
$ValidExts = @('.otf', '.ttf')
$ValidExtsRegex = '\.(otf|ttf)$'

Function Get-Fonts {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    Param(
        [ValidateSet('System', 'User')]
        [String]$Scope = 'System'
    )

    switch ($Scope) {
        'System' {
            $FontsFolder = [Environment]::GetFolderPath('Fonts')
            $FontsRegKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        }

        'User' {
            $FontsFolder = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'Microsoft\Windows\Fonts'
            $FontsRegKey = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        }
    }

    try {
        $FontFiles = @(Get-ChildItem -Path $FontsFolder -ErrorAction Stop | Where-Object Extension -In $ValidExts)
    } catch {
        throw 'Unable to enumerate {0} fonts folder: {1}' -f $Scope.ToLower(), $FontsFolder
    }

    try {
        $FontsReg = Get-Item -Path $FontsRegKey -ErrorAction Stop
    } catch {
        throw 'Unable to open {0} fonts registry key: {1}' -f $Scope.ToLower(), $FontsRegKey
    }

    $Fonts = New-Object -TypeName 'Collections.Generic.List[PSCustomObject]'
    $FontsRegFileNames = New-Object -TypeName 'Collections.Generic.List[String]'
    foreach ($FontRegName in ($FontsReg.Property | Sort-Object)) {
        $FontRegValue = $FontsReg.GetValue($FontRegName)

        if ($Scope -eq 'User') {
            $FontRegFileName = [IO.Path]::GetFileName($FontRegValue)
        } else {
            $FontRegFileName = $FontRegValue
        }

        if ($FontRegFileName -notmatch $ValidExtsRegex) {
            Write-Debug -Message ('Ignoring font with unsupported extension: {0} -> {1}' -f $FontRegName, $FontRegFileName)
            continue
        } elseif ($FontFiles.Name -notcontains $FontRegFileName) {
            Write-Warning -Message ('Font file for registered font does not exist: {0} -> {1}' -f $FontRegName, $FontRegFileName)
            continue
        }

        $Font = [PSCustomObject]@{
            Name = $FontRegName
            File = $FontFiles | Where-Object Name -EQ $FontRegFileName
        }

        $Fonts.Add($Font)
        $FontsRegFileNames.Add($FontRegFileName)
    }

    foreach ($FontFileName in $FontFiles.Name) {
        if ($FontFileName -notin $FontsRegFileNames) {
            Write-Warning -Message ('Font file not registered for {0}: {1}' -f $Scope.ToLower(), $FontFileName)
        }
    }

    return $Fonts.ToArray()
}

# Windows 10 1809 and Windows Server 2019 introduced support for installing
# fonts per-user. The corresponding Windows release build number is 17763.
Function Test-PerUserFontsSupported {
    [CmdletBinding()]
    [OutputType([Boolean])]
    Param()

    $BuildNumber = [Int](Get-CimInstance -ClassName 'Win32_OperatingSystem' -Verbose:$false).BuildNumber
    if ($BuildNumber -ge 17763) {
        return $true
    }

    return $false
}

if ($Scope -eq 'User' -and !(Test-PerUserFontsSupported)) {
    throw 'Per-user fonts are only supported from Windows 10 1809 and Windows Server 2019.'
}

Get-Fonts @PSBoundParameters
