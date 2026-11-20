$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$assetDir = Join-Path $PSScriptRoot 'App/Assets'
$macResources = Join-Path $PSScriptRoot '../Mac/App/Resources'
$null = New-Item -ItemType Directory -Force -Path $assetDir,$macResources

# The app mark and the tray glyph have different optical requirements.
$cloud = [System.Drawing.Drawing2D.GraphicsPath]::new()
$cloud.StartFigure()
$cloud.AddBezier(61,198,33,198,16,179,16,155)
$cloud.AddBezier(16,155,16,131,32,112,55,109)
$cloud.AddBezier(55,109,59,71,89,46,124,46)
$cloud.AddBezier(124,46,160,46,188,69,196,101)
$cloud.AddBezier(196,101,222,102,242,122,242,149)
$cloud.AddBezier(242,149,242,178,222,198,194,198)
$cloud.CloseFigure()
$letters = [System.Drawing.Drawing2D.GraphicsPath]::new()
$family = [System.Drawing.FontFamily]::new('Segoe UI')
$letters.AddString('my',$family,[int][System.Drawing.FontStyle]::Bold,100,[System.Drawing.PointF]::new(0,0),[System.Drawing.StringFormat]::GenericTypographic)
$bounds=$letters.GetBounds();$matrix=[System.Drawing.Drawing2D.Matrix]::new()
$scale=[Math]::Min(136/$bounds.Width,73/$bounds.Height)
$matrix.Translate([single](128-($bounds.X+$bounds.Width/2)*$scale),[single](144-($bounds.Y+$bounds.Height/2)*$scale))
$matrix.Scale([single]$scale,[single]$scale);$letters.Transform($matrix);$matrix.Dispose();$family.Dispose()

function Get-SvgPath($path) {
    $points=$path.PathPoints;$types=$path.PathTypes;$parts=[System.Collections.Generic.List[string]]::new()
    function Point($p){$p.X.ToString('0.###',[Globalization.CultureInfo]::InvariantCulture)+','+$p.Y.ToString('0.###',[Globalization.CultureInfo]::InvariantCulture)}
    for($i=0;$i -lt $points.Length;$i++) {
        switch($types[$i] -band 7) {
            0 {$parts.Add('M'+(Point $points[$i]))}
            1 {$parts.Add('L'+(Point $points[$i]))}
            3 {$parts.Add('C'+(Point $points[$i])+' '+(Point $points[$i+1])+' '+(Point $points[$i+2]));$i+=2}
        }
        if($types[$i] -band 128){$parts.Add('Z')}
    }
    return $parts -join ' '
}
$cloudSvg=Get-SvgPath $cloud;$lettersSvg=Get-SvgPath $letters
[IO.File]::WriteAllText((Join-Path $assetDir 'myDrive.svg'),'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" role="img" aria-label="myDrive"><path fill="#2f68e0" d="'+$cloudSvg+'"/><path fill="#fff" fill-rule="evenodd" d="'+$lettersSvg+'"/></svg>')
[IO.File]::WriteAllText((Join-Path $assetDir 'tray.svg'),'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="currentColor" d="M4.5 12.5 C2.8 12.5 1.5 11.2 1.5 9.5 C1.5 7.8 2.8 6.5 4.5 6.5 C4.5 4.3 6.1 2.5 8.3 2.5 C10.5 2.5 12.2 4.3 12.2 6.5 C13.6 6.8 14.5 8 14.5 9.5 C14.5 11.2 13.2 12.5 11.5 12.5 Z"/></svg>')

function New-TrayPath([int]$size) {
    # Hint the straight bottom edge to physical pixels at each Windows DPI.
    $scale=$size/16.0
    $offset=[Math]::Round(12.5*$scale,[MidpointRounding]::AwayFromZero)-12.5*$scale
    $path=[System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddBezier(4.5,12.5,2.8,12.5,1.5,11.2,1.5,9.5)
    $path.AddBezier(1.5,9.5,1.5,7.8,2.8,6.5,4.5,6.5)
    $path.AddBezier(4.5,6.5,4.5,4.3,6.1,2.5,8.3,2.5)
    $path.AddBezier(8.3,2.5,10.5,2.5,12.2,4.3,12.2,6.5)
    $path.AddBezier(12.2,6.5,13.6,6.8,14.5,8,14.5,9.5)
    $path.AddBezier(14.5,9.5,14.5,11.2,13.2,12.5,11.5,12.5)
    $path.CloseFigure()
    $transform=[System.Drawing.Drawing2D.Matrix]::new()
    $transform.Translate(0,[single]$offset)
    $transform.Scale([single]$scale,[single]$scale)
    $path.Transform($transform);$transform.Dispose()
    return ,$path
}

function New-Frame([int]$size,[string]$kind) {
    $bitmap=[System.Drawing.Bitmap]::new($size,$size)
    $g=[System.Drawing.Graphics]::FromImage($bitmap)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    if($kind -eq 'logo') {
        $g.PixelOffsetMode=[System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.ScaleTransform([single]($size/256.0),[single]($size/256.0))
        $blue=[System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(47,104,224))
        $g.FillPath($blue,$cloud);$g.FillPath([System.Drawing.Brushes]::White,$letters);$blue.Dispose()
    } else {
        $color=if($kind -eq 'white'){[System.Drawing.Color]::White}else{[System.Drawing.Color]::FromArgb(30,30,30)}
        $g.PixelOffsetMode=[System.Drawing.Drawing2D.PixelOffsetMode]::None
        $path=New-TrayPath $size
        $brush=[System.Drawing.SolidBrush]::new($color)
        $g.FillPath($brush,$path);$brush.Dispose();$path.Dispose()
    }
    $g.Dispose();return ,$bitmap
}
function Write-Icon([string]$path,[string]$kind) {
    $sizes=@(16,20,24,32,40,48,64,256);$frames=@()
    foreach($size in $sizes){$bitmap=New-Frame $size $kind;$memory=[IO.MemoryStream]::new();$bitmap.Save($memory,[System.Drawing.Imaging.ImageFormat]::Png);$frames+=,$memory.ToArray();$memory.Dispose();$bitmap.Dispose()}
    $writer=[IO.BinaryWriter]::new([IO.File]::Create($path))
    try {
        $writer.Write([UInt16]0);$writer.Write([UInt16]1);$writer.Write([UInt16]$sizes.Count)
        $offset=6+16*$sizes.Count
        for($i=0;$i -lt $sizes.Count;$i++) {
            $dimension=if($sizes[$i] -eq 256){0}else{$sizes[$i]}
            $writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0)
            $writer.Write([UInt16]1);$writer.Write([UInt16]32);$writer.Write([UInt32]$frames[$i].Length);$writer.Write([UInt32]$offset);$offset+=$frames[$i].Length
        }
        foreach($frame in $frames){$writer.Write([byte[]]$frame)}
    } finally {$writer.Dispose()}
}
Write-Icon (Join-Path $assetDir 'myDrive.ico') 'logo'
Write-Icon (Join-Path $assetDir 'tray-white.ico') 'white'
Write-Icon (Join-Path $assetDir 'tray-dark.ico') 'dark'
foreach($target in @(@((Join-Path $assetDir 'myDrive.png'),256),@((Join-Path $assetDir 'myDrive-logo.png'),1024),@((Join-Path $macResources 'myDrive.png'),1024))) {
    $bitmap=New-Frame $target[1] 'logo';$bitmap.Save($target[0],[System.Drawing.Imaging.ImageFormat]::Png);$bitmap.Dispose()
}
$cloud.Dispose();$letters.Dispose()
