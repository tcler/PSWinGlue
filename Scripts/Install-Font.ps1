<#
    .SYNOPSIS
    Installs a specific font or all fonts from a directory

    .DESCRIPTION
    Provides support for installation of fonts using either the Windows shell or an emulated approach without shell dependencies.

    The two supported methods of font installation each have their own benefits and drawbacks. See the parameter help for more details.

    .PARAMETER Path
    The path to an individual font to install, or a directory containing fonts to install.

    .PARAMETER Scope
    Specifies whether to install fonts system-wide or per-user.

    Support for per-user fonts is only available from Windows 10 1809 and Windows Server 2019.

    Installing system-wide fonts requires Administrator privileges.

    The default is system-wide.

    .PARAMETER Method
    Specifies the method to use for installation of fonts.

    Two methods are currently supported:
    - Manual:   An approach which emulates the behaviour of the Windows shell (default)
    - Shell:    Directly use the Windows shell facilities for installing fonts

    The Manual approach is the default and should be safe to use in unattended scenarios. Although untested, it should be compatible with Server Core installations.

    The Shell approach is not safe to use in unattended scenarios as in some instances it may present interactive prompts (e.g. overwriting an existing font).

    .EXAMPLE
    Install-Fonts -Path C:\Fonts

    Installs all fonts from the "C:\Fonts" directory. Fonts will be installed system-wide using the "Manual" method.

    .EXAMPLE
    Install-Fonts -Path "$HOME\Fonts" -Scope User -Method Shell

    Installs all fonts from the "Fonts" folder in the user's home directory. Fonts will be installed only for the running user using the "Shell" method.

    .NOTES
    Only OpenType (.otf) and TrueType (.ttf) fonts are supported.

    Per-user fonts are only installed in the context of the user executing the function.

    .LINK
    https://github.com/ralish/PSWinGlue
#>

# Get-FileHash shipped with PowerShell 4.0
#Requires -Version 4.0

[CmdletBinding(SupportsShouldProcess)]
[OutputType([Void])]
Param(
    [ValidateNotNullOrEmpty()]
    [String]$Path,

    [ValidateSet('System', 'User')]
    [String]$Scope = 'System',

    [ValidateSet('Manual', 'Shell')]
    [String]$Method = 'Manual'
)

$PowerShellMin = New-Object -TypeName Version -ArgumentList 4, 0
if ($PSVersionTable.PSVersion -lt $PowerShellMin) {
    throw '{0} requires at least PowerShell {1}.' -f $MyInvocation.MyCommand.Name, $PowerShellMin
}

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

Function Install-FontManual {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([Void])]
    Param(
        [Parameter(Mandatory)]
        [Collections.Generic.List[IO.FileInfo]]$Fonts,

        [ValidateSet('System', 'User')]
        [String]$Scope = 'System'
    )

    Begin {
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

        if ($Scope -eq 'User') {
            $null = New-Item -Path $FontsFolder -ItemType Directory -ErrorAction Ignore
            $null = New-Item -Path $FontsRegKey -ErrorAction Ignore
        }

        try {
            $FontsReg = Get-Item -Path $FontsRegKey -ErrorAction Stop
        } catch {
            throw 'Unable to open {0} fonts registry key: {1}' -f $Scope.ToLower(), $FontsRegKey
        }

        Add-Type -AssemblyName 'PresentationCore' -ErrorAction Stop
    }

    Process {
        foreach ($Font in $Fonts) {
            $FontUri = New-Object -TypeName 'Uri' -ArgumentList $Font.FullName
            try {
                $GlyphTypeface = New-Object -TypeName 'Windows.Media.GlyphTypeface' -ArgumentList $FontUri
            } catch {
                Write-Error -Message ('Unable to import font: {0}' -f $Font.Name)
                continue
            }

            $FontCulture = 'en-US'
            if ($GlyphTypeface.Win32FamilyNames.ContainsKey($FontCulture) -and $GlyphTypeface.Win32FaceNames.ContainsKey($FontCulture)) {
                $FontFamilyName = $GlyphTypeface.Win32FamilyNames[$FontCulture]
                $FontFaceName = $GlyphTypeface.Win32FaceNames[$FontCulture]
            } else {
                Write-Error -Message ('Font does not contain metadata for {0} culture: {1}' -f $FontCulture, $Font.Name)
                continue
            }

            # Matches the convention used by the Explorer shell
            $FontInstallPath = Join-Path -Path $FontsFolder -ChildPath $Font.Name
            $FontInstallSuffixNum = -1
            while (Test-Path -Path $FontInstallPath) {
                $FontInstallSuffixNum++
                $FontInstallName = '{0}_{1}{2}' -f $Font.BaseName, $FontInstallSuffixNum, $Font.Extension
                $FontInstallPath = Join-Path -Path $FontsFolder -ChildPath $FontInstallName
            }
            Write-Debug -Message ('[{0}] Font install path: {1}' -f $Font.Name, $FontInstallPath)

            # Matches the convention used by the Explorer shell
            if ($FontFaceName -eq 'Regular') {
                $FontRegName = '{0} (TrueType)' -f $FontFamilyName
            } else {
                $FontRegName = '{0} {1} (TrueType)' -f $FontFamilyName, $FontFaceName
            }
            Write-Debug -Message ('[{0}] Font registry name: {1}' -f $Font.Name, $FontRegName)

            if ($Scope -eq 'User') {
                $FontRegValue = $FontInstallPath
            } else {
                $FontRegValue = [IO.Path]::GetFileName($FontInstallPath)
            }

            if ($FontsReg.Property.Contains($FontRegName)) {
                Write-Error -Message ('Font registry name already exists: {0}' -f $FontRegName)
                continue
            }

            if ($PSCmdlet.ShouldProcess($Font.Name, 'Install font manually')) {
                Write-Verbose -Message ('Installing font manually: {0}' -f $Font.Name)
                Copy-Item -Path $Font.FullName -Destination $FontInstallPath
                $null = New-ItemProperty -Path $FontsRegKey -Name $FontRegName -PropertyType String -Value $FontRegValue
            }
        }
    }
}

Function Install-FontShell {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([Void])]
    Param(
        [Parameter(Mandatory)]
        [Collections.Generic.List[IO.FileInfo]]$Fonts
    )

    Begin {
        # ShellSpecialFolderConstants enumeration
        # https://docs.microsoft.com/en-us/windows/desktop/api/Shldisp/ne-shldisp-shellspecialfolderconstants
        $ssfFONTS = 20

        # _SHFILEOPSTRUCTA structure
        # https://docs.microsoft.com/en-us/windows/desktop/api/shellapi/ns-shellapi-_shfileopstructa
        $FOF_SILENT = 4
        $FOF_NOCONFIRMATION = 16
        $FOF_NOERRORUI = 1024
        $FOF_NOCOPYSECURITYATTRIBS = 2048
        $CopyOptions = $FOF_SILENT + $FOF_NOCONFIRMATION + $FOF_NOERRORUI + $FOF_NOCOPYSECURITYATTRIBS

        $ShellApp = $null
        $FontsFolder = $null

        try {
            $ShellApp = New-Object -ComObject 'Shell.Application'
            $FontsFolder = $ShellApp.NameSpace($ssfFONTS)
        } catch {
            if ($ShellApp) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($ShellApp) }
            throw $_
        }
    }

    Process {
        foreach ($Font in $Fonts) {
            if ($PSCmdlet.ShouldProcess($Font.Name, 'Install font via shell')) {
                Write-Verbose -Message ('Installing font via shell: {0}' -f $Font.Name)
                $FontsFolder.CopyHere($Font.FullName, $CopyOptions)
            }
        }
    }

    End {
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($FontsFolder)
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($ShellApp)
    }
}

Function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([Boolean])]
    Param()

    $User = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($User.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return $true
    }

    return $false
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

# Validate the install scope and method
if ($Scope -eq 'System') {
    if (!(Test-IsAdministrator) -and !$WhatIfPreference) {
        throw 'Administrator privileges are required to install system-wide fonts.'
    } elseif ($Method -eq 'Shell' -and (Test-PerUserFontsSupported)) {
        throw 'Installing fonts system-wide via the Shell API is unsupported from Windows 10 1809.'
    }
} elseif (!(Test-PerUserFontsSupported)) {
    throw 'Per-user fonts are only supported from Windows 10 1809 and Windows Server 2019.'
}

# Use script location if no path provided
if (!$Path) {
    $Path = $PSScriptRoot
}

# Validate the source font path
try {
    $SourceFontPath = Get-Item -Path $Path -ErrorAction Stop
} catch {
    throw 'Provided path is invalid: {0}' -f $Path
}

# Enumerate fonts to be installed
if ($SourceFontPath -is [IO.DirectoryInfo]) {
    $SourceFonts = @(Get-ChildItem -Path $SourceFontPath | Where-Object Extension -In $ValidExts)

    if (!$SourceFonts) {
        throw 'Unable to locate any fonts in provided directory: {0}' -f $SourceFontPath
    }
} elseif ($SourceFontPath -is [IO.FileInfo]) {
    if ($SourceFontPath.Extension -notin $ValidExts) {
        throw 'Provided file does not appear to be a valid font: {0}' -f $SourceFontPath
    }

    $SourceFonts = @($SourceFontPath)
} else {
    throw 'Expected directory or file but received: {0}' -f $SourceFontPath.GetType().Name
}

# Retrieve installed fonts
$InstalledFonts = Get-Fonts -Scope $Scope

# Calculate the hash of each installed font
foreach ($Font in $InstalledFonts) {
    $FontHash = Get-FileHash -Path $Font.File.FullName
    $Font | Add-Member -MemberType NoteProperty -Name 'Hash' -Value $FontHash.Hash
}

# Filter out any already installed fonts
$InstallFonts = New-Object -TypeName 'Collections.Generic.List[IO.FileInfo]'
foreach ($Font in $SourceFonts) {
    $FontHash = Get-FileHash -Path $Font.FullName

    if ($FontHash.Hash -notin $InstalledFonts.Hash) {
        $InstallFonts.Add($Font)
    } else {
        Write-Verbose -Message ('Font is already installed: {0}' -f $Font.Name)
    }
}

# Install fonts using selected method
if ($InstallFonts) {
    switch ($Method) {
        'Manual' { Install-FontManual -Fonts $InstallFonts -Scope $Scope }
        'Shell' { Install-FontShell -Fonts $InstallFonts }
    }
}
