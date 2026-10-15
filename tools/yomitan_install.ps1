<#
Converts Yomitan dictionaries and copies them, with plugins/yomitan.koplugin, to
KOReader on a Kindle connected over USB as an MTP device:

  powershell -ExecutionPolicy Bypass -File tools\yomitan_install.ps1 [-DryRun] [dict.zip ...]

With no dictionaries given, asks for them (Enter alone = only update the plugin).
Lands in <KOReader>/plugins/yomitan.koplugin and <KOReader>/data/yomitan/<dictionary>.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
	# Matched against the device name under This PC, e.g. "Kindle Scribe".
	[string]$Device = 'Kindle',
	# The KOReader folder in the Kindle's storage root.
	[string]$KOReader = 'koreader-tategaki',
	[switch]$DryRun,
	[Parameter(ValueFromRemainingArguments = $true)][string[]]$Dictionaries
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$shell = New-Object -ComObject Shell.Application

# ---- MTP helpers (same approach as kindle_kanji/deploy-mtp.ps1) ----

# Display names can hide extensions ("dict" for dict.sqlite3), so match on the real file name.
function Get-ItemFileName($item)
{
	$name = $null
	try { $name = $item.ExtendedProperty('System.FileName') } catch { }
	if ([string]::IsNullOrEmpty($name)) { $name = $item.Name }
	return $name
}

function Find-Child($folder, [string]$name)
{
	foreach ($item in $folder.Items())
	{
		if ((Get-ItemFileName $item) -eq $name) { return $item }
	}
	return $null
}

# Shell copies and moves are asynchronous; poll until they have visibly landed.
function Wait-Until([scriptblock]$condition, [string]$what, [int]$timeoutSec = 60)
{
	$deadline = (Get-Date).AddSeconds($timeoutSec)
	while (-not (& $condition))
	{
		if ((Get-Date) -gt $deadline) { throw "Timed out waiting for $what" }
		Start-Sleep -Milliseconds 200
	}
}

function Get-OrCreateFolder($parent, [string]$name, [string]$label)
{
	$item = if ($parent) { Find-Child $parent $name } else { $null }
	if ($item) { return $item.GetFolder }
	Write-Host "    mkdir   $label"
	if ($DryRun) { return $null }
	$parent.NewFolder($name)
	Wait-Until { Find-Child $parent $name } "folder $label"
	return (Find-Child $parent $name).GetFolder
}

# MTP ignores "overwrite without asking", so an existing file is first moved off the
# device into a local temp folder -- a move into an empty folder never prompts.
$script:trash = $null
$script:trashCount = 0

function Remove-FromDevice($item, $folder, [string]$name, [string]$label)
{
	if (-not $script:trash)
	{
		$script:trash = Join-Path ([IO.Path]::GetTempPath()) ("yomitan-replaced-" + [guid]::NewGuid())
		New-Item -ItemType Directory -Path $script:trash | Out-Null
	}
	$slot = Join-Path $script:trash ([string]$script:trashCount)
	$script:trashCount++
	New-Item -ItemType Directory -Path $slot | Out-Null
	$shell.Namespace($slot).MoveHere($item, 0x14)
	Wait-Until { -not (Find-Child $folder $name) } "removal of the old $label" 300
}

function Copy-ToDevice([IO.FileInfo]$file, $folder, [string]$label)
{
	$existing = if ($folder) { Find-Child $folder $file.Name } else { $null }
	$verb = if ($existing) { 'replace' } else { 'add    ' }
	Write-Host ("    {0} {1} ({2:N0} KB)" -f $verb, $label, ($file.Length / 1KB))
	if ($DryRun) { return }

	if ($existing) { Remove-FromDevice $existing $folder $file.Name $label }
	$folder.CopyHere($file.FullName, 0x14)
	# FolderItem.Size is always 0 over MTP; the System.Size property has the real size.
	Wait-Until {
		$copied = Find-Child $folder $file.Name
		$copied -and ([long]$copied.ExtendedProperty('System.Size') -eq $file.Length)
	} "the copy of $label" (300 + [int]($file.Length / 1MB) * 10)
}

function Sync-Folder([string]$sourceDir, $folder, [string]$label)
{
	foreach ($file in Get-ChildItem -LiteralPath $sourceDir -File)
	{
		Copy-ToDevice $file $folder "$label/$($file.Name)"
	}
	foreach ($dir in Get-ChildItem -LiteralPath $sourceDir -Directory)
	{
		$sub = Get-OrCreateFolder $folder $dir.Name "$label/$($dir.Name)"
		Sync-Folder $dir.FullName $sub "$label/$($dir.Name)"
	}
}

# ---- Find KOReader on the Kindle ----

$kindle = $null
foreach ($item in $shell.Namespace(17).Items()) # 17 = This PC
{
	if ($item.Name -like "*$Device*") { $kindle = $item; break }
}
if (-not $kindle) { throw "No device named like '*$Device*' under This PC. Plug the Kindle in over USB and unlock it." }

$storage = $null
foreach ($item in $kindle.GetFolder.Items()) { $storage = $item; break }
if (-not $storage) { throw "'$($kindle.Name)' shows no storage. Unlock the Kindle and try again." }

$ko = Find-Child $storage.GetFolder $KOReader
if (-not $ko) { throw "No '$KOReader' folder in '$($kindle.Name)\$($storage.Name)'. Pass -KOReader <folder name>." }
$ko = $ko.GetFolder
Write-Host "==> KOReader: $($kindle.Name)\$($storage.Name)\$KOReader"

# ---- Convert the dictionaries ----

if (-not $Dictionaries)
{
	$Dictionaries = @()
	while ($true)
	{
		$answer = (Read-Host 'Dictionary .zip (drag and drop; Enter when done)').Trim().Trim('"')
		if (-not $answer) { break }
		$Dictionaries += $answer
	}
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ("yomitan-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stage | Out-Null
try
{
	if ($Dictionaries)
	{
		Write-Host "==> Converting"
		$python = if (Get-Command py -ErrorAction SilentlyContinue) { @('py', '-3') } else { @('python') }
		& $python[0] @($python | Select-Object -Skip 1) (Join-Path $PSScriptRoot 'yomitan_convert.py') -o $stage @Dictionaries
		if ($LASTEXITCODE -ne 0) { throw "Conversion failed (see above)." }
	}

	Write-Host "==> Copying"
	$plugin = Get-OrCreateFolder (Get-OrCreateFolder $ko 'plugins' 'plugins') 'yomitan.koplugin' 'plugins/yomitan.koplugin'
	Sync-Folder (Join-Path $repo 'plugins\yomitan.koplugin') $plugin 'plugins/yomitan.koplugin'
	if ($Dictionaries)
	{
		$data = Get-OrCreateFolder (Get-OrCreateFolder $ko 'data' 'data') 'yomitan' 'data/yomitan'
		foreach ($dir in Get-ChildItem -LiteralPath $stage -Directory)
		{
			Sync-Folder $dir.FullName (Get-OrCreateFolder $data $dir.Name "data/yomitan/$($dir.Name)") "data/yomitan/$($dir.Name)"
		}
	}
}
finally
{
	Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
	if ($script:trash) { Remove-Item -LiteralPath $script:trash -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not $DryRun) { Write-Host "==> Done. Unplug the Kindle, restart KOReader, and enable the dictionaries in Search settings > Yomitan dictionaries." }
