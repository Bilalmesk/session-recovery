#requires -Version 5.1
<#
    New-BrandAssets.ps1
    Regenerates the Session Recovery icon and installer artwork.

    The visual language follows the clean, editorial REA style: ink and white,
    one restrained blue accent, Segoe UI for text and Consolas for metadata.

    Examples
      powershell -NoProfile -ExecutionPolicy Bypass -File .\assets\New-BrandAssets.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$ink = [System.Drawing.Color]::FromArgb(32, 37, 43)
$muted = [System.Drawing.Color]::FromArgb(91, 101, 112)
$line = [System.Drawing.Color]::FromArgb(224, 229, 233)
$soft = [System.Drawing.Color]::FromArgb(244, 246, 248)
$accent = [System.Drawing.Color]::FromArgb(41, 79, 130)
$accentLight = [System.Drawing.Color]::FromArgb(141, 180, 226)
$white = [System.Drawing.Color]::White

function New-RoundRectPath {
    param(
        [System.Drawing.RectangleF]$Rectangle,
        [float]$Radius
    )
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = $Radius * 2
    if ($Radius -le 0) {
        $path.AddRectangle($Rectangle)
        return $path
    }
    $path.AddArc($Rectangle.X, $Rectangle.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Rectangle.X, $Rectangle.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function New-LogoBitmap {
    param([int]$Size)

    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    try {
        $inset = [Math]::Max(1.0, $Size * 0.035)
        $innerSize = $Size - (2.0 * $inset)
        $bounds = New-Object System.Drawing.RectangleF -ArgumentList $inset, $inset, $innerSize, $innerSize
        $backgroundPath = New-RoundRectPath -Rectangle $bounds -Radius ($Size * 0.22)
        $backgroundBrush = New-Object System.Drawing.SolidBrush($ink)
        try {
            $graphics.FillPath($backgroundBrush, $backgroundPath)
        } finally {
            $backgroundBrush.Dispose()
            $backgroundPath.Dispose()
        }

        $center = $Size / 2.0
        $radius = $Size * 0.255
        $ringRect = New-Object System.Drawing.RectangleF -ArgumentList ($center - $radius), ($center - $radius), (2.0 * $radius), (2.0 * $radius)
        $penWidth = [Math]::Max(1.4, $Size * 0.072)
        $ringPen = New-Object System.Drawing.Pen($white, $penWidth)
        try {
            $ringPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $ringPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $ringPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
            $graphics.DrawArc($ringPen, $ringRect, 42, 276)
        } finally {
            $ringPen.Dispose()
        }

        # Arrowhead at the open end of the ring.
        $endAngle = 42 + 276
        $radians = $endAngle * [Math]::PI / 180.0
        $endX = $center + ($radius * [Math]::Cos($radians))
        $endY = $center + ($radius * [Math]::Sin($radians))
        $tangentX = -[Math]::Sin($radians)
        $tangentY = [Math]::Cos($radians)
        $perpendicularX = -$tangentY
        $perpendicularY = $tangentX
        $arrowSize = [Math]::Max(2.0, $Size * 0.115)
        $tipX = $endX + ($tangentX * $arrowSize * 0.45)
        $tipY = $endY + ($tangentY * $arrowSize * 0.45)
        $baseX = $endX - ($tangentX * $arrowSize * 0.55)
        $baseY = $endY - ($tangentY * $arrowSize * 0.55)
        $halfWidth = $arrowSize * 0.55
        $arrowPoints = @(
            (New-Object System.Drawing.PointF -ArgumentList $tipX, $tipY),
            (New-Object System.Drawing.PointF -ArgumentList ($baseX + ($perpendicularX * $halfWidth)), ($baseY + ($perpendicularY * $halfWidth))),
            (New-Object System.Drawing.PointF -ArgumentList ($baseX - ($perpendicularX * $halfWidth)), ($baseY - ($perpendicularY * $halfWidth)))
        )
        $arrowBrush = New-Object System.Drawing.SolidBrush($white)
        try {
            $graphics.FillPolygon($arrowBrush, $arrowPoints)
        } finally {
            $arrowBrush.Dispose()
        }

        $dotSize = [Math]::Max(1.4, $Size * 0.075)
        $dotBrush = New-Object System.Drawing.SolidBrush($accentLight)
        try {
            $graphics.FillEllipse($dotBrush, ($center - ($dotSize / 2.0)), ($center - ($dotSize / 2.0)), $dotSize, $dotSize)
        } finally {
            $dotBrush.Dispose()
        }
    } finally {
        $graphics.Dispose()
    }

    return $bitmap
}

function Write-IcoFile {
    param(
        [string]$Path,
        [int[]]$Sizes
    )

    $images = New-Object System.Collections.Generic.List[byte[]]
    foreach ($size in $Sizes) {
        $bitmap = New-LogoBitmap -Size $size
        $stream = New-Object System.IO.MemoryStream
        $writer = New-Object System.IO.BinaryWriter($stream)
        try {
            # Classic 32-bit DIB icon entry. This is more portable with
            # System.Drawing than PNG-compressed icon entries.
            $maskStride = [int]([Math]::Ceiling($size / 32.0) * 4)
            $maskSize = $maskStride * $size
            $pixelBytes = $size * $size * 4
            $writer.Write([UInt32]40)
            $writer.Write([Int32]$size)
            $writer.Write([Int32]($size * 2))
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]32)
            $writer.Write([UInt32]0)
            $writer.Write([UInt32]$pixelBytes)
            $writer.Write([Int32]0)
            $writer.Write([Int32]0)
            $writer.Write([UInt32]0)
            $writer.Write([UInt32]0)

            $rect = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $size, $size
            $data = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                $row = New-Object byte[] ($size * 4)
                for ($y = $size - 1; $y -ge 0; $y--) {
                    $source = [IntPtr]::Add($data.Scan0, ($y * $data.Stride))
                    [System.Runtime.InteropServices.Marshal]::Copy($source, $row, 0, $row.Length)
                    $writer.Write($row)
                }
            } finally {
                $bitmap.UnlockBits($data)
            }
            $writer.Write((New-Object byte[] $maskSize))
            $images.Add($stream.ToArray())
        } finally {
            $writer.Dispose()
            $stream.Dispose()
            $bitmap.Dispose()
        }
    }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $writer = New-Object System.IO.BinaryWriter($stream)
    try {
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]$Sizes.Count)
        $offset = 6 + (16 * $Sizes.Count)
        for ($i = 0; $i -lt $Sizes.Count; $i++) {
            $size = $Sizes[$i]
            $bytes = $images[$i]
            $dimension = if ($size -ge 256) { 0 } else { $size }
            $writer.Write([byte]$dimension)
            $writer.Write([byte]$dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]32)
            $writer.Write([UInt32]$bytes.Length)
            $writer.Write([UInt32]$offset)
            $offset += $bytes.Length
        }
        foreach ($bytes in $images) {
            $writer.Write($bytes)
        }
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Draw-BrandText {
    param(
        [System.Drawing.Graphics]$Graphics,
        [string]$Text,
        [System.Drawing.Font]$Font,
        [System.Drawing.Brush]$Brush,
        [float]$X,
        [float]$Y
    )
    $Graphics.DrawString($Text, $Font, $Brush, $X, $Y)
}

function New-BannerBitmap {
    $bitmap = New-Object System.Drawing.Bitmap(493, 58, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $logo = $null
    $inkBrush = $null
    $mutedBrush = $null
    $accentBrush = $null
    $font = $null
    $mono = $null
    $linePen = $null
    try {
        $graphics.Clear($white)
        $accentBrush = New-Object System.Drawing.SolidBrush($accent)
        $graphics.FillRectangle($accentBrush, 0, 0, 493, 3)
        $linePen = New-Object System.Drawing.Pen($line)
        $graphics.DrawLine($linePen, 0, 57, 493, 57)
        $logo = New-LogoBitmap -Size 36
        $graphics.DrawImage($logo, 443, 11, 36, 36)
        $inkBrush = New-Object System.Drawing.SolidBrush($ink)
        $mutedBrush = New-Object System.Drawing.SolidBrush($muted)
        $font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
        $mono = New-Object System.Drawing.Font('Consolas', 7, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
        Draw-BrandText -Graphics $graphics -Text 'SESSION RECOVERY' -Font $font -Brush $inkBrush -X 326 -Y 13
        Draw-BrandText -Graphics $graphics -Text 'LOCAL SNAPSHOTS' -Font $mono -Brush $mutedBrush -X 326 -Y 29
    } finally {
        if ($linePen) { $linePen.Dispose() }
        if ($font) { $font.Dispose() }
        if ($mono) { $mono.Dispose() }
        if ($inkBrush) { $inkBrush.Dispose() }
        if ($mutedBrush) { $mutedBrush.Dispose() }
        if ($accentBrush) { $accentBrush.Dispose() }
        if ($logo) { $logo.Dispose() }
        $graphics.Dispose()
    }
    return $bitmap
}

function New-DialogBitmap {
    $bitmap = New-Object System.Drawing.Bitmap(493, 312, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $logo = $null
    $panelBrush = $null
    $whiteBrush = $null
    $accentBrush = $null
    $titleFont = $null
    $mono = $null
    try {
        $graphics.Clear($white)
        $panelBrush = New-Object System.Drawing.SolidBrush($ink)
        $graphics.FillRectangle($panelBrush, 0, 0, 154, 312)
        $accentBrush = New-Object System.Drawing.SolidBrush($accent)
        $graphics.FillRectangle($accentBrush, 154, 0, 3, 312)
        $logo = New-LogoBitmap -Size 68
        $graphics.DrawImage($logo, 43, 76, 68, 68)
        $whiteBrush = New-Object System.Drawing.SolidBrush($white)
        $titleFont = New-Object System.Drawing.Font('Segoe UI Semibold', 14, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
        Draw-BrandText -Graphics $graphics -Text 'SESSION' -Font $titleFont -Brush $whiteBrush -X 24 -Y 162
        Draw-BrandText -Graphics $graphics -Text 'RECOVERY' -Font $titleFont -Brush $whiteBrush -X 24 -Y 184
        $mono = New-Object System.Drawing.Font('Consolas', 6.5, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
        Draw-BrandText -Graphics $graphics -Text 'LOCAL SNAPSHOTS' -Font $mono -Brush $whiteBrush -X 24 -Y 224
        $accentBrush.Dispose()
        $accentBrush = New-Object System.Drawing.SolidBrush($accentLight)
        $graphics.FillRectangle($accentBrush, 24, 244, 42, 3)
    } finally {
        if ($titleFont) { $titleFont.Dispose() }
        if ($mono) { $mono.Dispose() }
        if ($whiteBrush) { $whiteBrush.Dispose() }
        if ($accentBrush) { $accentBrush.Dispose() }
        if ($panelBrush) { $panelBrush.Dispose() }
        if ($logo) { $logo.Dispose() }
        $graphics.Dispose()
    }
    return $bitmap
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$iconPath = Join-Path $OutputDirectory 'SessionRecovery.ico'
$bannerPath = Join-Path $OutputDirectory 'installer-banner.bmp'
$dialogPath = Join-Path $OutputDirectory 'installer-dialog.bmp'

Write-Host "Writing $iconPath"
Write-IcoFile -Path $iconPath -Sizes @(16, 24, 32, 48, 64, 128, 256)

Write-Host "Writing $bannerPath"
$banner = New-BannerBitmap
try {
    $banner.Save($bannerPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
} finally {
    $banner.Dispose()
}

Write-Host "Writing $dialogPath"
$dialog = New-DialogBitmap
try {
    $dialog.Save($dialogPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
} finally {
    $dialog.Dispose()
}

Write-Host 'Brand assets generated.'
