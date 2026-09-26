$ErrorActionPreference = 'Stop'

$equations = [ordered]@{
    thermal_balance = @'
\begin{aligned}
C_{\mathrm{die}}\frac{dT_{\mathrm{die}}}{dt}
&= P_{\mathrm{IT}}(t) - \frac{T_{\mathrm{die}}-T_{\mathrm{fluid}}}{R_{\mathrm{th}}}, \\
C_{\mathrm{fluid}}\frac{dT_{\mathrm{fluid}}}{dt}
&= \frac{T_{\mathrm{die}}-T_{\mathrm{fluid}}}{R_{\mathrm{th}}}
- \dot m(t) C_p (T_{\mathrm{fluid}}-T_{\mathrm{inlet}}).
\end{aligned}
'@
    pid_control = @'
\begin{aligned}
e(t) &= T_{\mathrm{die}}(t)-T_{\mathrm{set}},\\
\dot m(t) &= \operatorname{clamp}\!\left(
\dot m_{\mathrm{nom}}+K_p e+K_i\int_0^t e(\tau)\,d\tau
+K_d\frac{dT_{\mathrm{die}}}{dt},\,
\dot m_{\min},\dot m_{\max}\right).
\end{aligned}
'@
    pump_power = @'
P_{\mathrm{pump}}=P_{\mathrm{pump,max}}
\left(\frac{\dot m}{\dot m_{\max}}\right)^3.
'@
}

$root = Split-Path -Parent $PSScriptRoot
$outputDir = Join-Path $root 'docs\equations'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    foreach ($theme in @(
        @{ Name = 'light'; Color = '1F2328'; Background = 'FFFFFF'; Muted = '57606A'; NodeFill = 'F6F8FA'; NodeBorder = '57606A'; LoadFill = 'FFF8F0'; Heat = 'C2410C'; CoolantFill = 'ECFEFF'; Coolant = '0E7490'; Flow = '0969DA'; ControlFill = 'F6F8FA'; Control = '8250DF'; Feedback = 'CF222E'; Command = '1A7F37' },
        @{ Name = 'dark'; Color = 'F0F6FC'; Background = '0D1117'; Muted = '8B949E'; NodeFill = '161B22'; NodeBorder = '8B949E'; LoadFill = '2D1B12'; Heat = 'FF7B72'; CoolantFill = '102A2A'; Coolant = '39C5CF'; Flow = '58A6FF'; ControlFill = '161B22'; Control = 'BC8CFF'; Feedback = 'FF7B72'; Command = '3FB950' }
    )) {
        foreach ($entry in $equations.GetEnumerator()) {
            $job = "$($entry.Key)_$($theme.Name)"
            $texPath = Join-Path $tempDir "$job.tex"
            $dviPath = Join-Path $tempDir "$job.dvi"
            $svgPath = Join-Path $outputDir "$($entry.Key).$($theme.Name).svg"
            $document = @"
\documentclass{article}
\usepackage{amsmath}
\usepackage{xcolor}
\pagestyle{empty}
\definecolor{equationcolor}{HTML}{$($theme.Color)}
\begin{document}
\color{equationcolor}
\Large
\setlength{\jot}{9pt}
\[
$($entry.Value)
\]
\end{document}
"@
            [System.IO.File]::WriteAllText($texPath, $document, [System.Text.Encoding]::UTF8)
            & latex -interaction=nonstopmode -halt-on-error "-output-directory=$tempDir" $texPath | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $logPath = Join-Path $tempDir "$job.log"
                $detail = if (Test-Path $logPath) { (Get-Content -Tail 30 $logPath) -join "`n" } else { 'No TeX log was produced.' }
                throw "latex failed while rendering ${job}: $detail"
            }
            & dvisvgm --no-fonts --exact --bbox=min -o $svgPath $dviPath | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "dvisvgm failed while rendering $job" }
        }
    }

    $schematicSource = Get-Content -LiteralPath (Join-Path $root 'docs\system_schematic.tex') -Raw -Encoding utf8
    foreach ($theme in @(
        @{ Name = 'light'; Background = 'FFFFFF'; Text = '24292F'; Muted = '57606A'; NodeFill = 'F6F8FA'; NodeBorder = '57606A'; LoadFill = 'FFF8F0'; Heat = 'C2410C'; CoolantFill = 'ECFEFF'; Coolant = '0E7490'; Flow = '0969DA'; ControlFill = 'F6F8FA'; Control = '8250DF'; Feedback = 'CF222E'; Command = '1A7F37' },
        @{ Name = 'dark'; Background = '0D1117'; Text = 'F0F6FC'; Muted = '8B949E'; NodeFill = '161B22'; NodeBorder = '8B949E'; LoadFill = '2D1B12'; Heat = 'FF7B72'; CoolantFill = '102A2A'; Coolant = '39C5CF'; Flow = '58A6FF'; ControlFill = '161B22'; Control = 'BC8CFF'; Feedback = 'FF7B72'; Command = '3FB950' }
    )) {
        $schematic = $schematicSource
        $palette = @{
            'SCHEME_BG' = $theme.Background; 'SCHEME_TEXT' = $theme.Text; 'SCHEME_MUTED' = $theme.Muted
            'SCHEME_NODE_FILL' = $theme.NodeFill; 'SCHEME_NODE_BORDER' = $theme.NodeBorder
            'SCHEME_LOAD_FILL' = $theme.LoadFill; 'SCHEME_HEAT' = $theme.Heat
            'SCHEME_COOLANT_FILL' = $theme.CoolantFill; 'SCHEME_COOLANT' = $theme.Coolant
            'SCHEME_FLOW' = $theme.Flow; 'SCHEME_CONTROL_FILL' = $theme.ControlFill
            'SCHEME_CONTROL' = $theme.Control; 'SCHEME_FEEDBACK' = $theme.Feedback
            'SCHEME_COMMAND' = $theme.Command
        }
        foreach ($token in ($palette.Keys | Sort-Object { $_.Length } -Descending)) {
            $schematic = $schematic.Replace($token, $palette[$token])
        }

        $job = "system_schematic_$($theme.Name)"
        $texPath = Join-Path $tempDir "$job.tex"
        $dviPath = Join-Path $tempDir "$job.dvi"
        $svgPath = Join-Path $root "docs\system_schematic.$($theme.Name).svg"
        [System.IO.File]::WriteAllText($texPath, $schematic, [System.Text.Encoding]::UTF8)
        & latex -interaction=nonstopmode -halt-on-error "-output-directory=$tempDir" $texPath | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $logPath = Join-Path $tempDir "$job.log"
            $detail = if (Test-Path $logPath) { (Get-Content -Tail 30 $logPath) -join "`n" } else { 'No TeX log was produced.' }
            throw "latex failed while rendering ${job}: $detail"
        }
        & dvisvgm --no-fonts --exact --bbox=min -o $svgPath $dviPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "dvisvgm failed while rendering $job" }
    }
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}

Write-Host "Rendered light/dark equation SVGs to $outputDir and the matching system schematics to docs."
