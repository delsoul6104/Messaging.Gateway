<#
.SYNOPSIS
    自動掃描專案並產生 Central Package Management (CPM) 必備的 Directory.Packages.props 檔案。

.DESCRIPTION
    此腳本會遞迴掃描目標目錄下的所有 .csproj 檔案，萃取所有 NuGet 套件與其版本號。
    若同一個套件有不同版本，將自動採用最高版本。
    
.PARAMETER TargetPath
    要掃描的根目錄路徑。預設為當前目錄 (".\")。

.PARAMETER UpdateProjects
    加上此開關 (Switch) 時，腳本不僅會產生設定檔，還會將所有 .csproj 內的 Version 屬性刪除，完成 CPM 轉換。
#>

param (
    [string]$TargetPath = ".\",
    [switch]$UpdateProjects
)

$ErrorActionPreference = "Stop"

# 確保路徑存在
if (-not (Test-Path $TargetPath)) {
    Write-Error "找不到目標路徑: $TargetPath"
    exit
}

$propsFile = Join-Path $TargetPath "Directory.Packages.props"
$csprojFiles = Get-ChildItem -Path $TargetPath -Filter *.csproj -Recurse

if ($csprojFiles.Count -eq 0) {
    Write-Warning "在 $TargetPath 找不到任何 .csproj 檔案。"
    exit
}

Write-Host "🔍 開始掃描 $($csprojFiles.Count) 個專案..." -ForegroundColor Cyan

$packages = @{}
$usedPackages = @{}

# 1. 掃描所有專案，收集套件與最高版本；同時記錄所有用到的套件名稱（含未標版本者）
foreach ($proj in $csprojFiles) {
    $content = Get-Content $proj.FullName -Raw
    # 收集所有 PackageReference 名稱（無論是否有 Version）
    $allRefs = [regex]::Matches($content, '(?i)<PackageReference\s+Include="([^"]+)"')
    foreach ($ref in $allRefs) {
        $usedPackages[$ref.Groups[1].Value] = $true
    }

    # 支援單行或多行格式的 PackageReference（含 Version）
    $matches = [regex]::Matches($content, '(?i)<PackageReference\s+Include="([^"]+)"\s+Version="([^"]+)"')
    
    foreach ($match in $matches) {
        $pkgName = $match.Groups[1].Value
        $version = $match.Groups[2].Value
        
        # 版本衝突解決：保留版本號較大的
        if (-not $packages.ContainsKey($pkgName)) {
            $packages[$pkgName] = $version
        } else {
            # 簡易的版本比對邏輯
            try {
                $currentVer = [System.Version]($packages[$pkgName] -replace '[A-Za-z\-].*', '')
                $newVer = [System.Version]($version -replace '[A-Za-z\-].*', '')
                if ($newVer -gt $currentVer) {
                    $packages[$pkgName] = $version
                }
            } catch {
                # 若包含複雜的 pre-release 標籤無法直接轉 Version，改用語法比對
                if ($version -gt $packages[$pkgName]) {
                    $packages[$pkgName] = $version
                }
            }
        }
    }
}

# 1b. 追蹤 ProjectReference 找出外部 Directory.Packages.props，補齊版本資訊
$externalPropsSet = @{}
foreach ($proj in $csprojFiles) {
    $content = Get-Content $proj.FullName -Raw
    $projDir = Split-Path $proj.FullName
    $projRefs = [regex]::Matches($content, '(?i)<ProjectReference\s+Include="([^"]+)"')
    foreach ($ref in $projRefs) {
        $refRelPath = $ref.Groups[1].Value -replace '/', '\'
        $refFullPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($projDir, $refRelPath))
        $searchDir = Split-Path $refFullPath
        # 向上尋找 Directory.Packages.props
        while ($searchDir) {
            $candidateProps = Join-Path $searchDir "Directory.Packages.props"
            if (Test-Path $candidateProps) {
                $resolvedCandidate = [System.IO.Path]::GetFullPath($candidateProps)
                $resolvedLocal     = [System.IO.Path]::GetFullPath($propsFile)
                if ($resolvedCandidate -ne $resolvedLocal) {
                    $externalPropsSet[$resolvedCandidate] = $true
                }
                break
            }
            $parent = Split-Path $searchDir
            if ($parent -eq $searchDir) { break }
            $searchDir = $parent
        }
    }
}

if ($externalPropsSet.Count -gt 0) {
    Write-Host "📦 從外部 Directory.Packages.props 補充版本資訊..." -ForegroundColor Cyan
    foreach ($extProps in $externalPropsSet.Keys) {
        Write-Host "   -> $extProps"
        $extContent = Get-Content $extProps -Raw
        $pkgVerMatches = [regex]::Matches($extContent, '(?i)<PackageVersion\s+Include="([^"]+)"\s+Version="([^"]+)"')
        foreach ($match in $pkgVerMatches) {
            $pkgName = $match.Groups[1].Value
            $version = $match.Groups[2].Value
            # 只納入本地專案實際有用到的套件
            if (-not $usedPackages.ContainsKey($pkgName)) { continue }
            if (-not $packages.ContainsKey($pkgName)) {
                $packages[$pkgName] = $version
            } else {
                try {
                    $currentVer = [System.Version]($packages[$pkgName] -replace '[A-Za-z\-].*', '')
                    $newVer = [System.Version]($version -replace '[A-Za-z\-].*', '')
                    if ($newVer -gt $currentVer) { $packages[$pkgName] = $version }
                } catch {
                    if ($version -gt $packages[$pkgName]) { $packages[$pkgName] = $version }
                }
            }
        }
    }
}

# 1c. 讀取現有本地 Directory.Packages.props（若存在），補充尚未有版本的套件
if (Test-Path $propsFile) {
    $existingContent = Get-Content $propsFile -Raw
    $existingMatches = [regex]::Matches($existingContent, '(?i)<PackageVersion\s+Include="([^"]+)"\s+Version="([^"]+)"')
    foreach ($match in $existingMatches) {
        $pkgName = $match.Groups[1].Value
        $version = $match.Groups[2].Value
        if (-not $packages.ContainsKey($pkgName)) {
            $packages[$pkgName] = $version
        }
    }
}

# 1d. 對仍缺版本的套件查詢 NuGet API 取得最新穩定版
$missingPackages = $usedPackages.Keys | Where-Object { -not $packages.ContainsKey($_) }
if ($missingPackages) {
    Write-Host "🌐 向 NuGet 查詢 $($missingPackages.Count | Measure-Object | Select-Object -ExpandProperty Count) 個未知版本的套件..." -ForegroundColor Cyan
    # 使用 PowerShell 7+ HttpClient；若不可用則退回 Invoke-RestMethod
    foreach ($pkg in $missingPackages) {
        try {
            $uri = "https://api.nuget.org/v3-flatcontainer/$($pkg.ToLower())/index.json"
            $resp = Invoke-RestMethod -Uri $uri -ErrorAction Stop
            # 過濾掉 pre-release 版本
            $stable = $resp.versions | Where-Object { $_ -notmatch '-' } | Select-Object -Last 1
            if ($stable) {
                $packages[$pkg] = $stable
                Write-Host "   ✔ $pkg = $stable"
            } else {
                # 若沒有穩定版，取最新版
                $latest = $resp.versions | Select-Object -Last 1
                $packages[$pkg] = $latest
                Write-Host "   ⚠ $pkg = $latest (pre-release)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "   ✖ $pkg：查詢失敗，請手動補充版本" -ForegroundColor Red
        }
    }
}

# 2. 產生 Directory.Packages.props 檔案內容
$propsContent = @"
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
    <CentralPackageTransitivePinningEnabled>true</CentralPackageTransitivePinningEnabled>
  </PropertyGroup>
  <ItemGroup>
"@

# 將收集到的套件按字母排序並加入
foreach ($pkg in ($packages.Keys | Sort-Object)) {
    $ver = $packages[$pkg]
    $propsContent += "`n    <PackageVersion Include=`"$pkg`" Version=`"$ver`" />"
}

$propsContent += "`n  </ItemGroup>`n</Project>"

# 寫入檔案 (使用 UTF8 編碼)
$propsContent | Out-File -FilePath $propsFile -Encoding UTF8
Write-Host "✅ 已成功建立 $($propsFile) ！共收集了 $($packages.Count) 個不同的套件。" -ForegroundColor Green


# 3. 根據參數決定是否修改 .csproj
if ($UpdateProjects) {
    Write-Host "🧹 正在清理各專案中的 Version 屬性..." -ForegroundColor Cyan

    foreach ($proj in $csprojFiles) {
        $originalContent = Get-Content $proj.FullName -Raw
        
        # 將包含 Version="..." 的 PackageReference 替換為不含 Version 的版本
        $newContent = [regex]::Replace($originalContent, '(?i)(<PackageReference\s+Include="[^"]+")\s+Version="[^"]+"', '$1')
        
        if ($originalContent -ne $newContent) {
            $newContent | Out-File -FilePath $proj.FullName -Encoding UTF8
            Write-Host "  👉 已更新: $($proj.Name)"
        }
    }
    Write-Host "🎉 CPM 專案轉換完成！請開啟 Visual Studio 重新建置並測試。" -ForegroundColor Green
} else {
    Write-Host "⚠️ 目前為安全模式。僅產生了 Directory.Packages.props，未修改任何 .csproj 檔案。" -ForegroundColor Yellow
    Write-Host "   若要一併清理 .csproj 中的版本號，請在執行時加上 -UpdateProjects 參數。" -ForegroundColor Yellow
}