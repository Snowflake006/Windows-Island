param([string]$Directory)
# Rasterize the Windows-owned glyphs locally; the system font is never bundled.
Add-Type -AssemblyName PresentationCore,WindowsBase
$fontPath=Join-Path $env:windir 'SystemResources\Windows.UI.BioFeedback\Fonts\NUIMDL2.ttf'
if(!(Test-Path $fontPath)){return}
$font=[Windows.Media.GlyphTypeface]::new([uri]$fontPath)
$codes=@(0xE757..0xE75D)+@(0xE770..0xE776)
$i=0
foreach($code in $codes){
 $outline=$font.GetGlyphOutline($font.CharacterToGlyphMap[[int]$code],48,48)
 $bounds=$outline.Bounds;$scale=52/[math]::Max($bounds.Width,$bounds.Height)
 $visual=[Windows.Media.DrawingVisual]::new();$dc=$visual.RenderOpen()
 $dc.PushTransform([Windows.Media.TranslateTransform]::new(32-($bounds.X+$bounds.Width/2)*$scale,32-($bounds.Y+$bounds.Height/2)*$scale))
 $dc.PushTransform([Windows.Media.ScaleTransform]::new($scale,$scale))
 $dc.DrawGeometry([Windows.Media.BrushConverter]::new().ConvertFromString('#57A6FF'),$null,$outline)
 $dc.Pop();$dc.Pop();$dc.Close()
 $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(64,64,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($visual)
 $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $stream=[IO.File]::Create((Join-Path $Directory "hello-$i.png"));try{$encoder.Save($stream)}finally{$stream.Dispose()};$i++
}
