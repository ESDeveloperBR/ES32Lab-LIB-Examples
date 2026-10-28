@echo off
setlocal EnableExtensions
set "ES32LAB_SELF=%~f0"
set "ES32LAB_SCRIPT_DIR=%~dp0"
set "ES32LAB_TMPPS=%TEMP%\es32lab_release_%RANDOM%_%RANDOM%.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$p=$env:ES32LAB_SELF;$t=$env:ES32LAB_TMPPS;$l=[IO.File]::ReadAllLines($p);$m=[Array]::IndexOf($l,'#===ES32LAB_POWERSHELL===');if($m-lt 0){exit 99};[IO.File]::WriteAllLines($t,$l[($m+1)..($l.Length-1)],(New-Object Text.UTF8Encoding($true)))"
if errorlevel 1 (
  echo ERRO: nao foi possivel iniciar o preparador de release.
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%ES32LAB_TMPPS%"
set "RC=%ERRORLEVEL%"
del /q "%ES32LAB_TMPPS%" >nul 2>nul
exit /b %RC%

#===ES32LAB_POWERSHELL===
$ErrorActionPreference="Stop"
Set-StrictMode -Version 2.0

function Title($t){Write-Host "";Write-Host "============================================================";Write-Host " $t";Write-Host "============================================================"}
function Cancel($v){if($null-ne $v -and $v.Trim().ToUpperInvariant()-eq "CANCELAR"){throw [OperationCanceledException]::new("Cancelado")}}
function Ask($key,$label,$current,$required,$example){
  if($null-ne $current -and $current.Trim()){return $current.Trim()}
  while($true){
    Write-Host "";Write-Host "Campo: $key";Write-Host $label
    if($example){Write-Host "Exemplo: $example"}
    if($required){Write-Host "Obrigatorio. Digite CANCELAR para encerrar."}
    else{Write-Host "Opcional. Enter para pular ou CANCELAR para encerrar."}
    $v=Read-Host ">";Cancel $v;$v=$v.Trim()
    if($v){return $v}
    if(-not $required){return ""}
    Write-Host "[ATENCAO] O campo '$key' e obrigatorio."
  }
}
function YesNo($q,$defaultYes=$true){
  while($true){
    $s=if($defaultYes){"[S/n]"}else{"[s/N]"}
    $v=Read-Host "$q $s (ou CANCELAR)";Cancel $v;$v=$v.Trim().ToLowerInvariant()
    if($v-eq ""){return $defaultYes}
    if($v-eq "s"-or$v-eq "sim"){return $true}
    if($v-eq "n"-or$v-eq "nao"-or$v-eq "não"){return $false}
    Write-Host "Use S, N, Enter ou CANCELAR."
  }
}
function ReadIni($path){
  $ini=@{};$sec=""
  if(-not(Test-Path -LiteralPath $path)){return $ini}
  foreach($raw in Get-Content -LiteralPath $path -Encoding UTF8){
    $l=$raw.Trim()
    if(-not$l -or $l.StartsWith(";") -or $l.StartsWith("#")){continue}
    if($l-match '^\[(.+)\]$'){$sec=$matches[1].Trim();if(-not$ini.ContainsKey($sec)){$ini[$sec]=@{}};continue}
    if($sec -and $l-match '^([^=]+)=(.*)$'){$ini[$sec][$matches[1].Trim()]=$matches[2].Trim()}
  }
  return $ini
}
function Exe($names){foreach($n in $names){$c=Get-Command $n -ErrorAction SilentlyContinue;if($c){return $c.Source}};return $null}

function FindPlatformIO {
  # 1) Primeiro tenta pelo PATH.
  $cmd=Exe @("pio","platformio")
  if($cmd){return $cmd}

  # 2) Caminho padrao usado pelo PlatformIO Core/VS Code no Windows.
  $candidates=@()

  if($env:PLATFORMIO_CORE_DIR){
    $candidates += (Join-Path $env:PLATFORMIO_CORE_DIR "penv\Scripts\platformio.exe")
    $candidates += (Join-Path $env:PLATFORMIO_CORE_DIR "penv\Scripts\pio.exe")
  }

  if($env:USERPROFILE){
    $candidates += (Join-Path $env:USERPROFILE ".platformio\penv\Scripts\platformio.exe")
    $candidates += (Join-Path $env:USERPROFILE ".platformio\penv\Scripts\pio.exe")
  }

  if($HOME){
    $candidates += (Join-Path $HOME ".platformio\penv\Scripts\platformio.exe")
    $candidates += (Join-Path $HOME ".platformio\penv\Scripts\pio.exe")
  }

  foreach($candidate in ($candidates | Select-Object -Unique)){
    if(Test-Path -LiteralPath $candidate -PathType Leaf){
      return [IO.Path]::GetFullPath($candidate)
    }
  }

  return $null
}
function Run($exe,$argumentList,$desc){
  Write-Host ""
  Write-Host "[EXEC] $desc"
  Write-Host ("       " + $exe + " " + ($argumentList -join " "))
  & $exe @argumentList
  if($LASTEXITCODE -ne 0){
    throw "Falha em '$desc' (codigo $LASTEXITCODE)."
  }
}
function Sha($p){return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function NoBomJson($p,$o){$j=$o|ConvertTo-Json -Depth 8;[IO.File]::WriteAllText($p,$j+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))}
function Num($v){$x=$v.Trim().ToLowerInvariant();if($x.StartsWith("0x")){return [Convert]::ToInt64($x.Substring(2),16)};if($x.EndsWith("k")){return [int64]([double]$x.TrimEnd("k")*1024)};if($x.EndsWith("m")){return [int64]([double]$x.TrimEnd("m")*1024*1024)};return [int64]$x}
function Hex($n){return ("0x{0:X}"-f$n)}
function BinName($v){
  $n=$v.Trim();while($n-match '(?i)\.bin$'){$n=$n.Substring(0,$n.Length-4).TrimEnd()}
  if(-not$n){throw "bin_name vazio."}
  foreach($c in [IO.Path]::GetInvalidFileNameChars()){if($n.Contains([string]$c)){throw "bin_name contem caractere invalido: $c"}}
  return $n
}
function Repo($v){
  $r=$v.Trim()-replace '^https?://github\.com/','' -replace '^git@github\.com:','' -replace '\.git$',''
  $r=$r.Trim("/")
  if($r-notmatch '^[^/\s]+/[^/\s]+$'){throw "repository deve usar ORGANIZACAO/REPOSITORIO."}
  return $r
}

function IsValidHttpsUrl($v){
  if($null-eq $v){return $false}
  $value=$v.Trim()
  if(-not$value){return $false}

  $uri=$null
  if(-not[Uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri)){return $false}
  if($uri.Scheme-ne"https"){return $false}
  if(-not$uri.Host){return $false}
  return $true
}

function DefaultManifestUrl($repo){
  return "https://github.com/$repo/releases/latest/download/manifest.json"
}

function SetReleaseIniValue($path,$key,$value){
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){
    throw "platformio.ini nao encontrado para atualizar '$key'."
  }

  $lines=[Collections.Generic.List[string]]::new()
  foreach($line in [IO.File]::ReadAllLines($path)){
    $lines.Add($line)
  }

  $releaseStart=-1
  $releaseEnd=$lines.Count

  for($i=0;$i-lt$lines.Count;$i++){
    $trim=$lines[$i].Trim()

    if($trim-match '^\[(.+)\]$'){
      $section=$matches[1].Trim()

      if($section-ieq"release"){
        $releaseStart=$i
        continue
      }

      if($releaseStart-ge 0 -and $i-gt$releaseStart){
        $releaseEnd=$i
        break
      }
    }
  }

  if($releaseStart-lt 0){
    throw "A secao [release] nao foi encontrada no platformio.ini."
  }

  $keyPattern='^\s*'+[regex]::Escape($key)+'\s*='
  $found=-1

  for($i=$releaseStart+1;$i-lt$releaseEnd;$i++){
    if($lines[$i]-match$keyPattern){
      $found=$i
      break
    }
  }

  $newLine="$key = $value"

  if($found-ge 0){
    $lines[$found]=$newLine
  }else{
    # Insere no final da secao [release], antes da proxima secao.
    # Remove apenas a posicao de linhas vazias finais para manter o bloco limpo.
    $insertAt=$releaseEnd
    while($insertAt-gt($releaseStart+1) -and -not$lines[$insertAt-1].Trim()){
      $insertAt--
    }
    $lines.Insert($insertAt,$newLine)
  }

  [IO.File]::WriteAllLines(
    $path,
    $lines,
    (New-Object Text.UTF8Encoding($false))
  )
}

function OptionalBool($key,$label,$current){
  $candidate=""
  if($null-ne$current){$candidate=$current.Trim()}

  while($true){
    if($candidate){
      $normalized=$candidate.ToLowerInvariant()
      if($normalized-eq"true"){return "true"}
      if($normalized-eq"false"){return "false"}

      Write-Host ""
      Write-Host "[ATENCAO] O campo '$key' deve ser somente true ou false."
      $candidate=""
    }

    Write-Host ""
    Write-Host "Campo: $key"
    Write-Host $label
    Write-Host "Opcional. Digite true, false, Enter para omitir ou CANCELAR para encerrar."

    $v=Read-Host ">"
    Cancel $v
    $v=$v.Trim()

    if(-not$v){return ""}

    $candidate=$v
  }
}
function Root(){
  $cur=(Get-Location).Path;$sd=$env:ES32LAB_SCRIPT_DIR.TrimEnd("\","/")
  $c=@($cur,$sd,(Split-Path -Parent $sd))|Where-Object{$_}|Select-Object -Unique
  foreach($x in $c){if(Test-Path -LiteralPath (Join-Path $x "platformio.ini")){return [IO.Path]::GetFullPath($x)}}
  if((Split-Path -Leaf $sd)-ieq "tools"){return [IO.Path]::GetFullPath((Split-Path -Parent $sd))}
  return [IO.Path]::GetFullPath($cur)
}
function ChooseEnv($ini){
  $e=@($ini.Keys|Where-Object{$_-like "env:*"}|Sort-Object)
  if($e.Count-eq 0){throw "Nenhum [env:...] encontrado."}
  if($e.Count-eq 1){return $e[0].Substring(4)}
  Write-Host "";Write-Host "Ambientes:"
  for($i=0;$i-lt$e.Count;$i++){Write-Host "$($i+1) - $($e[$i].Substring(4))"}
  while($true){$v=Read-Host "Numero (ou CANCELAR)";Cancel $v;$n=0;if([int]::TryParse($v,[ref]$n)-and$n-ge 1-and$n-le$e.Count){return $e[$n-1].Substring(4)};Write-Host "Opcao invalida."}
}
function FindFs($build,$fs){
  $a=@();if($fs){$a+=Join-Path $build ($fs.Trim()+".bin")}
  $a+=@("littlefs.bin","spiffs.bin","fatfs.bin","ffat.bin")|ForEach-Object{Join-Path $build $_}
  foreach($x in $a|Select-Object -Unique){if(Test-Path -LiteralPath $x){return $x}}
  return $null
}
function FirstFile($root,$filter,$hint){
  if(-not(Test-Path -LiteralPath $root)){return $null}
  $x=Get-ChildItem -LiteralPath $root -Filter $filter -File -Recurse -ErrorAction SilentlyContinue
  if($hint){$x=$x|Where-Object{$_.FullName-like "*$hint*"}}
  $f=$x|Select-Object -First 1;if($f){return $f.FullName};return $null
}

function FullImage($build,$fw,$data,$out){
  $boot=Join-Path $build "bootloader.bin";$part=Join-Path $build "partitions.bin"
  if(-not(Test-Path $boot)){throw "bootloader.bin nao encontrado."}
  if(-not(Test-Path $part)){throw "partitions.bin nao encontrado."}
  $core=if($env:PLATFORMIO_CORE_DIR){$env:PLATFORMIO_CORE_DIR}else{Join-Path $HOME ".platformio"}
  $packs=Join-Path $core "packages";$py=Join-Path $core "penv\Scripts\python.exe"
  if(-not(Test-Path $py)){$py=Exe @("python","py")}
  $esp=FirstFile $packs "esptool.py" "tool-esptoolpy"
  $gen=FirstFile $packs "gen_esp32part.py" "framework-arduinoespressif32"
  if(-not$py-or-not$esp-or-not$gen){throw "Ferramentas ESP32 do PlatformIO nao foram localizadas."}
  $csv=Join-Path $env:TEMP ("es32lab_part_"+[guid]::NewGuid().ToString("N")+".csv")
  try{
    Run $py @($gen,$part,$csv) "Interpretando tabela de particoes"
    $lines=@(Get-Content $csv -Encoding UTF8|Where-Object{$_.Trim()-and-not$_.Trim().StartsWith("#")})
    $rows=@($lines|ConvertFrom-Csv -Header Name,Type,SubType,Offset,Size,Flags)
    $app=$rows|Where-Object{$_.Type.Trim().ToLowerInvariant()-in @("app","0x00")}|Select-Object -First 1
    if(-not$app){throw "Particao da aplicacao nao identificada."}
    $fsp=$null
    if($data){
      $fsp=$rows|Where-Object{
        $t=$_.Type.Trim().ToLowerInvariant();$s=$_.SubType.Trim().ToLowerInvariant();$n=$_.Name.Trim().ToLowerInvariant()
        ($t-in @("data","0x01"))-and($s-match 'spiffs|fat|littlefs'-or$n-match 'spiffs|littlefs|fatfs|ffat|filesystem')
      }|Select-Object -First 1
      if(-not$fsp){throw "Imagem de dados existe, mas a particao de filesystem nao foi identificada."}
    }
    $ota=$rows|Where-Object{$_.Name.Trim().ToLowerInvariant()-eq"otadata"-or$_.SubType.Trim().ToLowerInvariant()-eq"ota"}|Select-Object -First 1
    $max=[int64]0
    foreach($r in $rows){try{$end=(Num $r.Offset)+(Num $r.Size);if($end-gt$max){$max=$end}}catch{}}
    $mb=1;while(($mb*1MB)-lt$max){$mb*=2}
    $pairs=@("0x1000",$boot,"0x8000",$part)
    if($ota){$ba=FirstFile $packs "boot_app0.bin" "framework-arduinoespressif32";if($ba){$pairs+=@((Hex (Num $ota.Offset)),$ba)}}
    $pairs+=@((Hex (Num $app.Offset)),$fw)
    if($data){$pairs+=@((Hex (Num $fsp.Offset)),$data)}
    Remove-Item $out -Force -ErrorAction SilentlyContinue
    Write-Host "";Write-Host "[EXEC] Gerando imagem FULL"
    $a4=@($esp,"--chip","esp32","merge_bin","-o",$out,"--fill-flash-size",($mb.ToString()+"MB"))+$pairs
    & $py @a4
    if($LASTEXITCODE-ne 0){
      Remove-Item $out -Force -ErrorAction SilentlyContinue
      $a5=@($esp,"--chip","esp32","merge-bin","-o",$out,"--pad-to-size",($mb.ToString()+"MB"))+$pairs
      & $py @a5
    }
    if($LASTEXITCODE-ne 0-or-not(Test-Path $out)){throw "Falha ao gerar imagem FULL."}
    Write-Host "Imagem FULL gerada com $mb MB."
  }finally{Remove-Item $csv -Force -ErrorAction SilentlyContinue}
}
function AssetUrl($repo,$name){return "https://github.com/$repo/releases/latest/download/"+[Uri]::EscapeDataString($name)}
function Optional($obj,$k,$v){if($v-and$v.Trim()){$obj[$k]=$v.Trim()}}
function ResolvePath($p,$base){if([IO.Path]::IsPathRooted($p)){return [IO.Path]::GetFullPath($p)};return [IO.Path]::GetFullPath((Join-Path $base $p))}


# ======================================================================
# ES32Lab Release v2.0 - RAMIFICACAO COMPOSTA
# A rotina original de Release Simples, abaixo, permanece sem alteracoes.
# Composite detectado somente quando existem secoes [release_<ambiente>].
# ======================================================================

function CRValue($section,$key){
  if($null-ne $section -and $section.ContainsKey($key)){return [string]$section[$key]}
  return ""
}
function CRSelectEnv($ini){
  $all=@($ini.Keys|Where-Object {$_ -match '^env:.+'}|Sort-Object)
  if($all.Count-eq 0){throw "Release composto: nenhum [env:...] encontrado."}
  $default=CRValue $ini["platformio"] "default_envs"
  $tokens=@($default -split '[,\s]+'|Where-Object{$_})
  if($tokens.Count-eq 1){
    if(-not $ini.ContainsKey("env:$($tokens[0])")){throw "default_envs '$($tokens[0])' nao corresponde a um ambiente."}
    return $tokens[0]
  }
  Write-Host ""
  Write-Host "Selecione o aplicativo (default_envs deve conter apenas um para selecao automatica):"
  for($i=0;$i-lt$all.Count;$i++){Write-Host ("{0} - {1}"-f($i+1),$all[$i].Substring(4))}
  while($true){
    $v=Read-Host "Numero (ou CANCELAR)";Cancel $v;$n=0
    if([int]::TryParse($v,[ref]$n)-and$n-ge 1-and$n-le$all.Count){return $all[$n-1].Substring(4)}
    Write-Host "Opcao invalida."
  }
}
function CRSourceDir($root,$envCfg,$envName){
  $filter=CRValue $envCfg "build_src_filter"
  $match=[regex]::Match($filter,'\+<([^<>*]+?)/\*\*>')
  if($match.Success){
    $sub=$match.Groups[1].Value.Trim().TrimEnd("/","\")
    if($sub -match '\.\.' -or [IO.Path]::IsPathRooted($sub)){throw "build_src_filter contem caminho de fonte inseguro."}
    $p=Join-Path (Join-Path $root "src") ($sub.Replace("/",[IO.Path]::DirectorySeparatorChar))
    if(Test-Path -LiteralPath $p -PathType Container){return [IO.Path]::GetFullPath($p)}
  }
  $fallback=Join-Path (Join-Path $root "src") $envName
  if(Test-Path -LiteralPath $fallback -PathType Container){return $fallback}
  throw "Nao consegui identificar a pasta de codigo do ambiente '$envName'. Confira build_src_filter."
}
function CRGetThumbnail($root,$src,$dist,$bn){
  $extensions=@(".png",".jpg",".jpeg")
  $found=$null
  foreach($e in $extensions){
    $p=Join-Path $src ($bn+"_thumb"+$e)
    if(Test-Path -LiteralPath $p -PathType Leaf){$found=$p;break}
  }
  if(-not $found){
    $candidates=@(Get-ChildItem -LiteralPath $src -File -ErrorAction SilentlyContinue |
       Where-Object {$_.Name -match '(?i)_thumb\.(png|jpe?g)$'})
    if($candidates.Count-eq 1){$found=$candidates[0].FullName}
  }
  if(-not $found){
    Write-Host ""
    Write-Host "[ATENCAO] Thumbnail nao encontrada na pasta do aplicativo."
    Write-Host "Nome recomendado: ${bn}_thumb.png (tambem aceita .jpg ou .jpeg)."
    if(YesNo "Deseja indicar uma imagem manualmente?" $false){
      while($true){
        $v=Read-Host "Caminho do PNG/JPG (Enter para pular, CANCELAR para sair)"
        Cancel $v
        if(-not $v.Trim()){break}
        $clean=$v.Trim().Trim('"')
        $p=ResolvePath $clean $root
        if((Test-Path -LiteralPath $p -PathType Leaf)-and ([IO.Path]::GetExtension($p).ToLowerInvariant() -in $extensions)){
          $found=$p;break
        }
        Write-Host "Arquivo invalido. Informe um PNG ou JPG existente."
      }
    }
  }
  if($found){
    $ext=[IO.Path]::GetExtension($found).ToLowerInvariant()
    $name=$bn+"_thumb"+$ext
    $target=Join-Path $dist $name
    $shouldCopy=$true
    if(Test-Path -LiteralPath $target){
      if((Sha $target) -ne (Sha $found)){
        Write-Host ""
        Write-Host "A imagem de dist/ e diferente da imagem do codigo:"
        Write-Host "  dist: $target"
        Write-Host "  fonte: $found"
        $shouldCopy=YesNo "Substituir a thumbnail de dist/ pela imagem encontrada?" $false
      }else{$shouldCopy=$false}
    }
    if($shouldCopy){Copy-Item -LiteralPath $found -Destination $target -Force}
    # Nao deixa duas thumbs da MESMA aplicacao com extensoes distintas.
    foreach($oldThumb in @(Get-ChildItem -LiteralPath $dist -File -ErrorAction SilentlyContinue |
        Where-Object {$_.Name -match ('(?i)^'+[regex]::Escape($bn)+'_thumb\.(png|jpe?g)$')})){
      if($oldThumb.Name -ine $name){
        Remove-Item -LiteralPath $oldThumb.FullName -Force
        Write-Host "Thumbnail obsoleta removida: $($oldThumb.Name)"
      }
    }
    return $name
  }
  $old=@(Get-ChildItem -LiteralPath $dist -File -ErrorAction SilentlyContinue |
      Where-Object {$_.Name -match ('(?i)^'+[regex]::Escape($bn)+'_thumb\.(png|jpe?g)$')})
  if($old.Count-eq 1){
    Write-Host "Mantendo thumbnail ja existente em dist/: $($old[0].Name)"
    return $old[0].Name
  }
  Write-Host "Sem thumbnail. Campo thumbnail_url sera omitido no manifesto gerado."
  return ""
}
function CRCheckManifest($path,$dist,$repo){
  try {$m=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}
  catch{throw "JSON invalido em '$([IO.Path]::GetFileName($path))': $($_.Exception.Message)"}
  foreach($key in @("name","developer","version","version_date","description")){
    if(-not ($m.PSObject.Properties.Name -contains $key) -or -not ([string]$m.$key).Trim()){
      throw "Manifesto $([IO.Path]::GetFileName($path)): campo obrigatorio '$key' ausente."
    }
  }
  if($m.PSObject.Properties.Name -contains "uses_wifi" -and $m.uses_wifi -isnot [bool]){
    throw "Manifesto $([IO.Path]::GetFileName($path)): uses_wifi deve ser booleano."
  }
  if($m.PSObject.Properties.Name -contains "manifest_url"){
    if(-not(IsValidHttpsUrl ([string]$m.manifest_url))){throw "manifest_url invalida em $path"}
    $expected=[IO.Path]::GetFileName($path)
    if($m.manifest_url -like "https://github.com/$repo/releases/latest/download/*" -and
       ([Uri]$m.manifest_url).AbsolutePath.Split("/")[-1] -ne $expected){
      throw "manifest_url aponta para outro arquivo em $path."
    }
  }
  $hasFirmware=$false;$hasFull=$false
  foreach($prefix in @("firmware","data","full")){
    $urlKey="${prefix}_url";$shaKey="${prefix}_sha256"
    $urlProp=($m.PSObject.Properties.Name -contains $urlKey)
    $shaProp=($m.PSObject.Properties.Name -contains $shaKey)
    if($shaProp -and -not $urlProp){throw "$shaKey existe sem $urlKey em $path"}
    if(-not $urlProp){continue}
    $url=[string]$m.$urlKey
    if(-not(IsValidHttpsUrl $url)){throw "URL invalida ($urlKey) em $path"}
    if($prefix-eq"firmware"){$hasFirmware=$true}
    if($prefix-eq"full"){$hasFull=$true}
    if($url.StartsWith("https://github.com/$repo/releases/latest/download/",[StringComparison]::OrdinalIgnoreCase)){
      $filename=[Uri]::UnescapeDataString(([Uri]$url).AbsolutePath.Split("/")[-1])
      $bin=Join-Path $dist $filename
      if(-not(Test-Path -LiteralPath $bin -PathType Leaf)){throw "$urlKey aponta para arquivo ausente em dist/: $filename"}
      if($shaProp){
        if(([string]$m.$shaKey) -notmatch '^[a-fA-F0-9]{64}$'){throw "Hash SHA-256 invalido em $shaKey ($path)"}
        if((Sha $bin) -ine ([string]$m.$shaKey)){throw "$shaKey nao corresponde ao arquivo $filename"}
      }
    }
  }
  if(-not $hasFirmware -and -not $hasFull){throw "Manifesto $path nao possui firmware_url nem full_url."}
  if($m.PSObject.Properties.Name -contains "thumbnail_url"){
    if(-not(IsValidHttpsUrl ([string]$m.thumbnail_url))){throw "thumbnail_url invalida: $path"}
    $u=[string]$m.thumbnail_url
    if($u.StartsWith("https://github.com/$repo/releases/latest/download/",[StringComparison]::OrdinalIgnoreCase)){
      $n=[Uri]::UnescapeDataString(([Uri]$u).AbsolutePath.Split("/")[-1])
      if(-not(Test-Path -LiteralPath (Join-Path $dist $n) -PathType Leaf)){throw "Thumbnail referenciada nao existe em dist/: $n"}
    }
  }
}
function CRCheckDist($dist,$repo){
  $subs=@(Get-ChildItem -LiteralPath $dist -Directory -ErrorAction SilentlyContinue)
  if($subs.Count){throw "dist/ deve conter somente arquivos, sem subpastas."}
  $files=@(Get-ChildItem -LiteralPath $dist -File -ErrorAction SilentlyContinue)
  if($files.Count-eq 0){Write-Host "[ATENCAO] dist/ esta vazia.";return $files}
  foreach($f in $files){
    if($f.Name -match '(?i)(^manifest\.json$|_manifest\.json$)'){CRCheckManifest $f.FullName $dist $repo}
  }
  return $files
}
function CRPrepare($root,$ini,$envName,$repo,$dist){
  $relSec="release_$envName"
  if(-not $ini.ContainsKey($relSec)){throw "Metadados [$relSec] nao encontrados."}
  $rel=$ini[$relSec];$envCfg=$ini["env:$envName"]
  $src=CRSourceDir $root $envCfg $envName
  if(@(Get-ChildItem -LiteralPath $src -Include @("*.cpp","*.c","*.ino") -File -Recurse).Count-eq 0){
    throw "Nao foram encontrados arquivos de codigo no exemplo: $src"
  }
  Title "Release composto - $envName"
  Write-Host "Fonte: $src"
  $name=Ask "name" "Nome publico." (CRValue $rel "name") $true "Tetris ES32Lab"
  $developer=Ask "developer" "Desenvolvedor." (CRValue $rel "developer") $true "ES Developer"
  $appVersion=Ask "version" "Versao deste aplicativo." (CRValue $rel "version") $true "1.0.0"
  $date=Ask "version_date" "Data AAAA-MM-DD." (CRValue $rel "version_date") $true "2026-10-28"
  while($true){
    $d=[datetime]::MinValue
    if([datetime]::TryParseExact($date,"yyyy-MM-dd",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$d)){break}
    $date=Ask "version_date" "Data invalida; use AAAA-MM-DD." "" $true "2026-10-28"
  }
  $description=Ask "description" "Descricao publica." (CRValue $rel "description") $true "Exemplo oficial da LIB ES32Lab."
  $kw=CRValue $rel "keywords"
  $video=CRValue $rel "video_url";$site=CRValue $rel "website"
  $srcRepo=CRValue $rel "repository"
  if(-not $srcRepo){
    $srcRepo=Ask "repository" "URL publica do codigo-fonte (diferente do [release] repository)." "" $false "https://github.com/organizacao/projeto/blob/main/exemplo.ino"
  }
  if($srcRepo -and -not(IsValidHttpsUrl $srcRepo)){throw "repository do aplicativo deve ser URL HTTPS."}
  while($true){
    try{$bn=BinName(Ask "bin_name" "Nome-base dos arquivos." (CRValue $rel "bin_name") $true "es32lab_tetris");break}
    catch{Write-Host "[ATENCAO] $($_.Exception.Message); tente novamente.";$rel.Remove("bin_name")}
  }
  if($bn -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$'){throw "Use somente letras, numeros, _, ponto e hifen em bin_name."}
  foreach($k in @($ini.Keys|Where-Object{$_ -match '^release_.+' -and $_ -ine $relSec})){
    $other=CRValue $ini[$k] "bin_name"
    if($other -and $other -ieq $bn){throw "bin_name '$bn' duplicado em [$k]."}
  }
  $wifi=OptionalBool "uses_wifi" "Aplicativo utiliza Wi-Fi? (independente do scanner de servico)." (CRValue $rel "uses_wifi")
  $manifestName="${bn}_manifest.json";$thumbName=""
  $manifestUrl=CRValue $rel "manifest_url"
  $calcManifest=AssetUrl $repo $manifestName
  if(-not $manifestUrl){$manifestUrl=$calcManifest;Write-Host "manifest_url sugerida: $manifestUrl"}
  if(-not(IsValidHttpsUrl $manifestUrl)){throw "manifest_url deve ser URL HTTPS valida."}
  if($manifestUrl -ine $calcManifest){
    Write-Host "[ATENCAO] manifest_url difere da URL calculada para o Release:"
    Write-Host "Configurada: $manifestUrl"
    Write-Host "Calculada:   $calcManifest"
    if(YesNo "Usar URL calculada para garantir que a loja encontre o manifesto?" $true){$manifestUrl=$calcManifest}
  }
  $pio=FindPlatformIO
  if(-not $pio){throw "PlatformIO CLI nao encontrado. Verifique instalacao do PlatformIO."}
  $stage=Join-Path $root (".pio\es32lab_release_stage\"+$envName)
  if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
  New-Item -ItemType Directory -Path $stage -Force|Out-Null
  $fwName="$bn.bin";$dataName="$bn-data.bin";$fullName="$bn-full.bin"
  $fwOut=Join-Path $stage $fwName;$dataOut=Join-Path $stage $dataName;$fullOut=Join-Path $stage $fullName
  $hasData=$false;$hasFull=$false
  Push-Location $root
  try{
    Title "Compilacao - $envName"
    Run $pio @("run","-e",$envName) "Compilando firmware"
    $build=Join-Path $root ".pio\build\$envName"
    $fwBuild=Join-Path $build "firmware.bin"
    if(-not(Test-Path -LiteralPath $fwBuild -PathType Leaf)){throw "firmware.bin nao encontrado em $build"}
    Copy-Item -LiteralPath $fwBuild -Destination $fwOut -Force
    $appData=Join-Path $src "data"
    if(Test-Path -LiteralPath $appData -PathType Container){
      Write-Host "Filesystem local do aplicativo: $appData"
      $previousDataEnv=$env:PLATFORMIO_DATA_DIR
      try{
        $env:PLATFORMIO_DATA_DIR=$appData
        Run $pio @("run","-e",$envName,"-t","buildfs") "Compilando filesystem"
      }finally{$env:PLATFORMIO_DATA_DIR=$previousDataEnv}
      $fs=CRValue $envCfg "board_build.filesystem"
      if(-not $fs){$fs=CRValue $ini["env"] "board_build.filesystem"}
      $img=FindFs $build $fs
      if(-not $img){throw "Filesystem da pasta data/ nao foi gerado."}
      Copy-Item -LiteralPath $img -Destination $dataOut -Force
      $hasData=$true
    }else{Write-Host "Sem pasta data/ neste aplicativo."}
    if(YesNo "Gerar imagem FULL?" $true){
      $extra=if($hasData){$dataOut}else{""}
      FullImage $build $fwBuild $extra $fullOut
      $hasFull=$true
    }
  }finally{Pop-Location}
  $thumbName=CRGetThumbnail $root $src $dist $bn
  $m=[ordered]@{
    name=$name;developer=$developer;version=$appVersion;version_date=$date
    description=$description;manifest_url=$manifestUrl
  }
  if($wifi){$m["uses_wifi"]=[bool]($wifi-eq"true")}
  if($kw){$m["keywords"]=@($kw.Split(",")|ForEach-Object{$_.Trim()}|Where-Object{$_}|Select-Object -Unique)}
  if($thumbName){
    $m["thumbnail_url"]=AssetUrl $repo $thumbName
    $configuredThumb=CRValue $rel "thumbnail_url"
    if($configuredThumb -and $configuredThumb -ine $m["thumbnail_url"]){
      Write-Host "[ATENCAO] thumbnail_url no INI difere do arquivo escolhido; URL real do asset sera usada."
    }
  }
  Optional $m "video_url" $video
  Optional $m "website" $site
  Optional $m "repository" $srcRepo
  $m["firmware_url"]=AssetUrl $repo $fwName;$m["firmware_sha256"]=Sha $fwOut
  if($hasData){$m["data_url"]=AssetUrl $repo $dataName;$m["data_sha256"]=Sha $dataOut}
  if($hasFull){$m["full_url"]=AssetUrl $repo $fullName;$m["full_sha256"]=Sha $fullOut}
  $stagedManifest=Join-Path $stage $manifestName
  NoBomJson $stagedManifest $m
  $existingManifest=Join-Path $dist $manifestName
  if((Test-Path -LiteralPath $existingManifest)-and (Sha $existingManifest) -ne (Sha $stagedManifest)){
    Write-Host ""
    Write-Host "[ATENCAO] O manifesto em dist/ sera substituido."
    Write-Host "Se tiver alteracoes manuais, escolha N e publique dist/ sem recompilar."
    if(-not(YesNo "Confirmar substituicao do manifesto?" $true)){
      throw [OperationCanceledException]::new("Preparacao cancelada para preservar manifesto manual.")
    }
  }
  # Copia binarios apenas DESTE aplicativo. Nao limpa dist/ global.
  foreach($f in @($fwName,$dataName,$fullName,$manifestName)){
    $source=Join-Path $stage $f;$target=Join-Path $dist $f
    if(Test-Path -LiteralPath $source -PathType Leaf){
      Copy-Item -LiteralPath $source -Destination $target -Force
    }elseif(Test-Path -LiteralPath $target -PathType Leaf){
      Remove-Item -LiteralPath $target -Force
      Write-Host "Artefato antigo deste aplicativo removido: $f"
    }
  }
  Write-Host ""
  Write-Host "Aplicativo preparado em dist/: $bn ($appVersion)"
  Write-Host "Manifesto: $manifestName"
}
function CRGetRelease($gh,$repo,$tag){
  $old=$ErrorActionPreference;$ErrorActionPreference="Continue"
  try{
    $json=(& $gh "release" "view" $tag "--repo" $repo "--json" "assets,isImmutable,tagName" 2>$null | Out-String)
    $code=$LASTEXITCODE
  }finally{$ErrorActionPreference=$old}
  if($code-ne 0){return $null}
  try{return ($json | ConvertFrom-Json -ErrorAction Stop)}
  catch{throw "Nao foi possivel interpretar dados do Release '$tag'."}
}
function CRGitReady($root,$repo,$version){
  $git=Exe @("git")
  $gh=Exe @("gh")
  if(-not $git -or -not $gh){throw "Instale Git e GitHub CLI (gh) antes de publicar."}
  Run $gh @("auth","status") "Verificando autenticacao GitHub"
  Push-Location $root
  try{
    & $git "rev-parse" "--is-inside-work-tree" *> $null
    if($LASTEXITCODE-ne 0){throw "Nao ha repositorio Git neste projeto."}
    $origin=(& $git "remote" "get-url" "origin" | Out-String).Trim()
    if((Repo $origin) -ine $repo){throw "origin ($origin) difere de [release] repository ($repo)."}
    $dirty=@()
    foreach($line in @(& $git "status" "--porcelain" "--untracked-files=all")){
      if($line.Length-lt 4){continue}
      $part=$line.Substring(3).Trim('"') -replace '\\','/'
      if($part-eq"dist" -or $part.StartsWith("dist/") -or $part-eq".pio" -or $part.StartsWith(".pio/")){continue}
      $dirty+=$line
    }
    if($dirty.Count){
      Write-Host "";Write-Host "[ATENCAO] Alteracoes no projeto:"
      $dirty|ForEach-Object{Write-Host $_}
      if(YesNo "Deseja criar um commit dessas alteracoes antes da publicacao?" $true){
        $message=Read-Host "Mensagem de commit (Enter = Release v$version)"
        Cancel $message
        if(-not $message.Trim()){$message="Release v$version"}
        Run $git @("add","-A","--",".") "Preparando commit"
        # A pasta dist nao pertence ao commit. Se ja rastreada, retira do stage.
        & $git "reset" "-q" "HEAD" "--" "dist" 2>$null
        & $git "reset" "-q" "HEAD" "--" ".pio" 2>$null
        & $git "diff" "--cached" "--quiet"
        if($LASTEXITCODE-ne 0){
          Run $git @("commit","-m",$message) "Criando commit"
        }else{
          Write-Host "Sem arquivos preparados para commit."
        }
      }else{
        Write-Host "Publicacao adiada; dist/ permanece intacta."
        throw [OperationCanceledException]::new("Existem alteracoes nao commitadas.")
      }
    }
    Run $gh @("repo","view",$repo,"--json","nameWithOwner") "Verificando repositorio de destino"
    Run $git @("push","origin","HEAD") "Enviando commits"
  }finally{Pop-Location}
  return @{ git=$git;gh=$gh }
}
function CRPublish($root,$repo,$version,$dist){
  Title "Validacao da pasta dist"
  $files=@(CRCheckDist $dist $repo)
  if($files.Count-eq 0 -and -not(YesNo "dist/ esta VAZIA. Deseja mesmo apagar todos os assets do Release?" $false)){
    throw [OperationCanceledException]::new("Sincronizacao vazia cancelada.")
  }
  $tag=if($version -match '^v\d'){$version}else{"v$version"}
  if($tag -notmatch '^v[A-Za-z0-9][A-Za-z0-9._-]*$'){throw "Versao geral invalida: $version"}
  Write-Host ""
  Write-Host "Destino: https://github.com/$repo"
  Write-Host "Tag do catalogo: $tag"
  Write-Host "Arquivos: $($files.Count) em dist/"
  $files|ForEach-Object{Write-Host ("  "+$_.Name)}
  if(-not(YesNo "Continuar para a verificacao Git/GitHub?" $true)){return}
  $gitTools=CRGitReady $root $repo $version
  $git=$gitTools.git;$gh=$gitTools.gh
  $remote=CRGetRelease $gh $repo $tag
  $newRelease=($null-eq $remote)
  if(-not $newRelease -and $remote.isImmutable){
    throw "O Release $tag e imutavel no GitHub. Nao e possivel sincronizar seus assets."
  }
  Write-Host ""
  if($newRelease){
    Write-Host "Release '$tag' nao existe. Todos os arquivos de dist/ serao enviados em novo Release."
    if(-not(YesNo "Criar novo Release $tag com este snapshot completo?" $true)){return}
    Push-Location $root
    try{
      Run $git @("fetch","--tags","origin") "Atualizando tags locais"
      & $git "rev-parse" "-q" "--verify" "refs/tags/$tag" *> $null
      if($LASTEXITCODE-ne 0){Run $git @("tag","-a",$tag,"-m","Release $tag") "Criando tag"}
      Run $git @("push","origin","refs/tags/$tag") "Enviando tag"
      $args=@("release","create",$tag)+@($files|ForEach-Object{$_.FullName})+@("--repo",$repo,"--title",$tag,"--notes","Catalogo ES32Lab - $tag","--latest","--verify-tag")
      Run $gh $args "Criando Release com o conteudo completo de dist/"
    }finally{Pop-Location}
  }else{
    # Comparacao precisa: baixa os assets presentes em ambos os lados e compara SHA-256.
    # Tambem preserva copia temporaria dos assets antigos alterados para recuperacao.
    $remoteNames=@{}
    foreach($a in @($remote.assets)){$remoteNames[[string]$a.name]=$a}
    $localNames=@{};foreach($f in $files){$localNames[$f.Name]=$true}
    $tmp=Join-Path $env:TEMP ("es32lab_release_backup_"+[guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp|Out-Null
    $toUpload=@();$toDelete=@();$backup=@{}
    try{
      foreach($f in $files){
        if(-not $remoteNames.ContainsKey($f.Name)){$toUpload+=$f;continue}
        $old=$ErrorActionPreference;$ErrorActionPreference="Continue"
        try{
          & $gh "release" "download" $tag "--repo" $repo "--pattern" $f.Name "--dir" $tmp 1>$null 2>$null
          $code=$LASTEXITCODE
        }finally{$ErrorActionPreference=$old}
        $remoteFile=Join-Path $tmp $f.Name
        if($code-ne 0 -or -not(Test-Path -LiteralPath $remoteFile -PathType Leaf)){
          throw "Falha ao obter o asset remoto $($f.Name) para comparacao e backup."
        }
        if((Sha $remoteFile) -ne (Sha $f.FullName)){
          $toUpload+=$f
          $backup[$f.Name]=$remoteFile
        }
      }
      foreach($a in @($remote.assets)){
        if(-not $localNames.ContainsKey([string]$a.name)){$toDelete+=[string]$a.name}
      }
      Write-Host ""
      Write-Host "Release existente: $tag"
      Write-Host "Adicionar/substituir: $($toUpload.Count)"
      Write-Host "Excluir (ausentes de dist/): $($toDelete.Count)"
      Write-Host "Inalterados: $($files.Count-$toUpload.Count)"
      if($toUpload.Count){$toUpload|ForEach-Object{Write-Host ("  UP  "+$_.Name)}}
      if($toDelete.Count){$toDelete|ForEach-Object{Write-Host ("  DEL "+$_)}}
      if(-not(YesNo "Sincronizar este Release para ficar IGUAL a dist/?" $false)){return}
      # Publica binarios, imagens e demais arquivos antes dos manifestos.
      $uploadOrdered=@($toUpload|Sort-Object @{Expression={if($_.Name -match '(?i)_manifest\.json$'){1}else{0}}},Name)
      foreach($f in $uploadOrdered){
        try{
          Run $gh @("release","upload",$tag,$f.FullName,"--clobber","--repo",$repo) "Enviando $($f.Name)"
        }catch{
          if($backup.ContainsKey($f.Name)){
            Write-Host "[ATENCAO] Tentando restaurar asset anterior: $($f.Name)"
            & $gh "release" "upload" $tag $backup[$f.Name] "--clobber" "--repo" $repo
          }
          throw
        }
      }
      # So depois de enviar e validar os novos arquivos, remove os obsoletos.
      foreach($n in $toDelete){
        Run $gh @("release","delete-asset",$tag,$n,"--yes","--repo",$repo) "Removendo asset ausente de dist/: $n"
      }
      Run $gh @("release","edit",$tag,"--repo",$repo,"--latest") "Marcando como Latest"
    }finally{
      Remove-Item -LiteralPath $tmp -Force -Recurse -ErrorAction SilentlyContinue
    }
  }
  $result=CRGetRelease $gh $repo $tag
  $localNames=@($files|ForEach-Object{$_.Name}|Sort-Object)
  $remoteNames=@($result.assets|ForEach-Object{$_.name}|Sort-Object)
  if(($localNames -join [char]10) -cne ($remoteNames -join [char]10)){
    throw "A sincronizacao terminou com diferencas entre dist/ e os nomes dos assets remotos."
  }
  Write-Host ""
  Write-Host "Release publicado: https://github.com/$repo/releases/tag/$tag"
  Write-Host "URLs /releases/latest/download/ permanecem relativas ao catalogo atual."
}
function InvokeComposite($root,$ini){
  Title "ES32Lab - Release COMPOSTO v2.0"
  if(-not $ini.ContainsKey("release")){throw "Release composto requer [release] com repository e version."}
  $global=$ini["release"]
  $repo=Repo (Ask "repository" "Repositorio de PUBLICACAO (catalogo)." (CRValue $global "repository") $true "ESDeveloperBR/ES32Lab-LIB-Examples")
  $version=Ask "version" "Versao GERAL do catalogo GitHub Release." (CRValue $global "version") $true "1.0.0"
  $dist=Join-Path $root "dist"
  if(-not(Test-Path -LiteralPath $dist -PathType Container)){
    New-Item -ItemType Directory -Path $dist -Force|Out-Null
    Write-Host "Pasta dist/ criada."
  }
  $envName=CRSelectEnv $ini
  Write-Host "Aplicativo selecionado: $envName"
  Write-Host "Repositorio do catalogo: $repo"
  Write-Host "Versao do catalogo: $version"
  Write-Host ""
  Write-Host "1 - Compilar o aplicativo, preparar em dist/ e opcionalmente publicar"
  Write-Host "2 - Publicar/sincronizar apenas dist/ (sem compilar)"
  Write-Host "0 - Cancelar"
  while($true){
    $choice=Read-Host "Opcao"
    Cancel $choice
    if($choice -in @("1","2","0")){break}
    Write-Host "Opcao invalida."
  }
  if($choice-eq"0"){throw [OperationCanceledException]::new("Cancelado pelo usuario.")}
  if($choice-eq"1"){
    CRPrepare $root $ini $envName $repo $dist
    if(-not(YesNo "Publicar/sincronizar dist/ agora?" $true)){
      Write-Host "Arquivos preparados localmente em dist/; nenhuma publicacao realizada."
      return
    }
  }
  CRPublish $root $repo $version $dist
}
# Dispatch automatico: qualquer [release_<ambiente>] habilita o novo modo.
# Nao altera a rotina original executada por projetos com apenas [release].
$crRoot=Root
$crIniPath=Join-Path $crRoot "platformio.ini"
if(Test-Path -LiteralPath $crIniPath -PathType Leaf){
  $crIni=ReadIni $crIniPath
  $crMatches=@($crIni.Keys|Where-Object {$_ -match '^release_.+'})
  if($crMatches.Count-gt 0){
    try{
      InvokeComposite $crRoot $crIni
      exit 0
    }catch [OperationCanceledException]{
      Write-Host "";Write-Host "Operacao cancelada.";exit 2
    }catch{
      Write-Host "";Write-Host "ERRO (modo composto): $($_.Exception.Message)"
      if($_.InvocationInfo -and $_.InvocationInfo.PositionMessage){
        Write-Host $_.InvocationInfo.PositionMessage
      }
      Write-Host "Arquivos existentes em dist/ foram preservados."
      exit 1
    }
  }
}
# ======================================================================
# Abaixo: implementacao original v1.8 (Release Simples, SEM ALTERACOES).
# ======================================================================

try{
  Title "ES32Lab - Preparar Release"
  $root=Root;$pioIni=Join-Path $root "platformio.ini";$hasPio=Test-Path $pioIni
  Write-Host "Projeto: $root";Write-Host ("PlatformIO: "+$(if($hasPio){"encontrado"}else{"nao encontrado - modo manual"}))
  $ini=@{};$rel=@{};$envName="";$envCfg=@{}
  if($hasPio){
    $ini=ReadIni $pioIni;if($ini.ContainsKey("release")){$rel=$ini["release"]}
    $envName=ChooseEnv $ini;$sec="env:$envName";if($ini.ContainsKey($sec)){$envCfg=$ini[$sec]}
    Write-Host "Ambiente: $envName"
  }
  function GetReleaseValue($table,$key){
    if($null -eq $table){ return "" }
    if($table.ContainsKey($key)){ return [string]$table[$key] }
    return ""
  }

  $name=Ask "name" "Nome publico da aplicacao." (GetReleaseValue $rel "name") $true "ES32Lab nas Eleicoes 2026"
  $developer=Ask "developer" "Responsavel pela aplicacao." (GetReleaseValue $rel "developer") $true "ES Developer"
  $version=Ask "version" "Versao da aplicacao." (GetReleaseValue $rel "version") $true "2.5.3"
  $date=Ask "version_date" "Data no formato AAAA-MM-DD." (GetReleaseValue $rel "version_date") $true "2026-10-09"
  while($true){
    $d=[datetime]::MinValue
    if([datetime]::TryParseExact($date,"yyyy-MM-dd",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$d)){break}
    Write-Host "[ATENCAO] Data invalida."
    $date=Ask "version_date" "Use AAAA-MM-DD." "" $true "2026-10-09"
  }
  $desc=Ask "description" "Descricao publica." (GetReleaseValue $rel "description") $true "Descricao resumida da aplicacao."
  $thumb=Ask "thumbnail_url" "Imagem de apresentacao." (GetReleaseValue $rel "thumbnail_url") $false "https://exemplo.com/imagem.jpg"
  $video=Ask "video_url" "Video relacionado." (GetReleaseValue $rel "video_url") $false "https://youtube.com/watch?v=..."
  $kwRaw=Ask "keywords" "Palavras-chave separadas por virgula." (GetReleaseValue $rel "keywords") $false "ES32Lab, ESP32, Wi-Fi, OTA"
  while($true){
    try{$bn=BinName(Ask "bin_name" "Nome-base dos BINs; .bin sera removido automaticamente." (GetReleaseValue $rel "bin_name") $true "es32lab_eleicoes");break}
    catch{Write-Host "[ATENCAO] $($_.Exception.Message)";$rel.Remove("bin_name")}
  }
  while($true){
    try{$repo=Repo(Ask "repository" "Repositorio GitHub." (GetReleaseValue $rel "repository") $true "ESDeveloperBR/ES32Lab-Eleicoes");break}
    catch{Write-Host "[ATENCAO] $($_.Exception.Message)";$rel.Remove("repository")}
  }
  $site=Ask "website" "Site oficial." (GetReleaseValue $rel "website") $false "https://www.esdeveloper.com.br/"
  $keywords=@();if($kwRaw){$keywords=@($kwRaw.Split(",")|ForEach-Object{$_.Trim()}|Where-Object{$_}|Select-Object -Unique)}

  # ----------------------------------------------------------
  # manifest_url
  # ----------------------------------------------------------
  # O batch conhece repository e, portanto, consegue derivar o endereco
  # padrao do manifest.json. Essa resolucao ocorre antes da compilacao
  # para que o mesmo valor possa ser usado pelo firmware via build_flags.
  $generatedManifestUrl=DefaultManifestUrl $repo
  $configuredManifestUrl=GetReleaseValue $rel "manifest_url"
  $manifestUrl=""

  if(-not$configuredManifestUrl){
    $manifestUrl=$generatedManifestUrl

    if($hasPio){
      Write-Host ""
      Write-Host "manifest_url nao encontrado no platformio.ini."
      Write-Host "O batch ira adicionar automaticamente:"
      Write-Host $manifestUrl

      SetReleaseIniValue $pioPath "manifest_url" $manifestUrl
      $rel["manifest_url"]=$manifestUrl
    }else{
      Write-Host ""
      Write-Host "manifest_url gerado automaticamente:"
      Write-Host $manifestUrl
    }
  }else{
    $configuredManifestUrl=$configuredManifestUrl.Trim()

    if(-not(IsValidHttpsUrl $configuredManifestUrl)){
      Write-Host ""
      Write-Host "[ATENCAO] O manifest_url existente no platformio.ini nao e uma URL HTTPS valida."
      Write-Host "Atual:"
      Write-Host $configuredManifestUrl
      Write-Host ""
      Write-Host "Sugestao calculada pelo batch:"
      Write-Host $generatedManifestUrl

      if(YesNo "Substituir o manifest_url pela URL calculada?" $true){
        $manifestUrl=$generatedManifestUrl

        if($hasPio){
          SetReleaseIniValue $pioPath "manifest_url" $manifestUrl
          $rel["manifest_url"]=$manifestUrl
        }
      }else{
        throw "manifest_url invalido. Release cancelada para evitar firmware com endereco OTA incorreto."
      }
    }elseif($configuredManifestUrl-ine$generatedManifestUrl){
      Write-Host ""
      Write-Host "[ATENCAO] O manifest_url informado e diferente do endereco calculado para repository."
      Write-Host ""
      Write-Host "Atual:"
      Write-Host $configuredManifestUrl
      Write-Host ""
      Write-Host "Calculado:"
      Write-Host $generatedManifestUrl
      Write-Host ""
      Write-Host "Uma URL diferente pode ser intencional, por exemplo para hospedagem externa."

      if(YesNo "Deseja substituir pelo endereco calculado?" $false){
        $manifestUrl=$generatedManifestUrl

        if($hasPio){
          SetReleaseIniValue $pioPath "manifest_url" $manifestUrl
          $rel["manifest_url"]=$manifestUrl
        }
      }else{
        $manifestUrl=$configuredManifestUrl
        Write-Host "manifest_url personalizado preservado."
      }
    }else{
      $manifestUrl=$configuredManifestUrl
      Write-Host ""
      Write-Host "manifest_url conferido: OK"
    }
  }

  # ----------------------------------------------------------
  # uses_wifi
  # ----------------------------------------------------------
  # No JSON esse valor deve ser booleano real, nunca string.
  # Ausencia e diferente de false: se o usuario omitir, o campo nao entra.
  $usesWifiRaw=OptionalBool `
    "uses_wifi" `
    "Indica se a aplicacao utiliza Wi-Fi." `
    (GetReleaseValue $rel "uses_wifi")

  $dist=Join-Path $root "dist"
  if(-not(Test-Path $dist)){
    New-Item -ItemType Directory -Path $dist|Out-Null
    Write-Host "Pasta dist/ criada."
  }else{
    Get-ChildItem $dist -Force -ErrorAction SilentlyContinue|Remove-Item -Recurse -Force
  }

  $fwName="$bn.bin";$dataName="$bn-data.bin";$fullName="$bn-full.bin"
  $fwOut=Join-Path $dist $fwName;$dataOut=Join-Path $dist $dataName;$fullOut=Join-Path $dist $fullName
  $hasFw=$false;$hasData=$false;$hasFull=$false

  if($hasPio){
    Title "Compilacao PlatformIO"
    $pio=FindPlatformIO
    if(-not$pio){
      throw "PlatformIO CLI nao encontrado. O batch tentou o PATH e tambem a pasta .platformio\penv\Scripts do usuario."
    }
    Write-Host ("PlatformIO CLI: " + $pio)

    Push-Location $root
    try{
      Run $pio @("run","-e",$envName) "Compilando firmware"
      $build=Join-Path $root ".pio\build\$envName"
      $fwBuild=Join-Path $build "firmware.bin"
      if(-not(Test-Path $fwBuild)){throw "firmware.bin nao encontrado em $build"}
      Copy-Item $fwBuild $fwOut -Force
      $hasFw=$true

      if(Test-Path (Join-Path $root "data") -PathType Container){
        Write-Host "Pasta data/ encontrada: gerando imagem de dados."
        Run $pio @("run","-e",$envName,"-t","buildfs") "Gerando filesystem"
        $fs=if($envCfg.ContainsKey("board_build.filesystem")){[string]$envCfg["board_build.filesystem"]}else{""}
        $fsImg=FindFs $build $fs
        if(-not$fsImg){throw "Imagem de filesystem nao localizada."}
        Copy-Item $fsImg $dataOut -Force
        $hasData=$true
      }else{
        Write-Host "Pasta data/ nao encontrada: sem imagem de dados."
      }

      if(YesNo "Gerar imagem FULL?" $true){
        $fullData=if($hasData){$dataOut}else{""}
        FullImage $build $fwBuild $fullData $fullOut
        $hasFull=$true
      }
    }finally{
      Pop-Location
    }
  }else{
    Title "Modo manual"
    while($true){
      $f=Ask "firmware_bin" "Caminho para firmware BIN." "" $false "build\firmware.bin"
      $d=Ask "data_bin" "Caminho para dados BIN." "" $false "build\data.bin"
      $u=Ask "full_bin" "Caminho para FULL BIN." "" $false "build\full.bin"
      if($f-or$u){break}
      Write-Host "[ATENCAO] Informe firmware_bin ou full_bin."
    }
    if($f){
      $x=ResolvePath $f $root
      if(-not(Test-Path $x)){throw "Firmware nao encontrado: $x"}
      Copy-Item $x $fwOut
      $hasFw=$true
    }
    if($d){
      $x=ResolvePath $d $root
      if(-not(Test-Path $x)){throw "Dados nao encontrados: $x"}
      Copy-Item $x $dataOut
      $hasData=$true
    }
    if($u){
      $x=ResolvePath $u $root
      if(-not(Test-Path $x)){throw "FULL nao encontrado: $x"}
      Copy-Item $x $fullOut
      $hasFull=$true
    }
  }

  if(-not$hasFw-and-not$hasFull){throw "E necessario firmware ou FULL."}

  Title "Manifesto"
  $m=[ordered]@{
    name=$name
    developer=$developer
    version=$version
    version_date=$date
    description=$desc
    manifest_url=$manifestUrl
  }
  if($usesWifiRaw){
    $m["uses_wifi"]=[bool]($usesWifiRaw-eq"true")
  }
  if($keywords.Count){$m["keywords"]=$keywords}
  Optional $m "thumbnail_url" $thumb
  Optional $m "video_url" $video
  Optional $m "website" $site
  $m["repository"]="https://github.com/$repo"

  if($hasFw){
    $m["firmware_url"]=AssetUrl $repo $fwName
    $m["firmware_sha256"]=Sha $fwOut
  }
  if($hasData){
    $m["data_url"]=AssetUrl $repo $dataName
    $m["data_sha256"]=Sha $dataOut
  }
  if($hasFull){
    $m["full_url"]=AssetUrl $repo $fullName
    $m["full_sha256"]=Sha $fullOut
  }

  $manifest=Join-Path $dist "manifest.json"
  NoBomJson $manifest $m
  Get-Content $manifest -Encoding UTF8

  Title "Resumo"
  Write-Host "Versao: $version"
  Write-Host "Manifest: $manifestUrl"
  if($usesWifiRaw){Write-Host "Usa Wi-Fi: $usesWifiRaw"}else{Write-Host "Usa Wi-Fi: nao informado"}
  Write-Host "dist/: $dist"
  if($hasFw){Write-Host "Firmware: $fwName";Write-Host "SHA-256: $(Sha $fwOut)"}
  if($hasData){Write-Host "Dados: $dataName";Write-Host "SHA-256: $(Sha $dataOut)"}
  if($hasFull){Write-Host "Full: $fullName";Write-Host "SHA-256: $(Sha $fullOut)"}

  if(-not(YesNo "Publicar agora como GitHub Release?" $true)){
    Write-Host "Release preparada localmente."
    exit 0
  }

  Title "Git / GitHub"
  $git=Exe @("git")
  $gh=Exe @("gh")
  if(-not$git){throw "Git nao encontrado."}
  if(-not$gh){throw "GitHub CLI (gh) nao encontrado."}

  Run $gh @("auth","status") "Verificando autenticacao GitHub"

  Push-Location $root
  try{
    & $git "rev-parse" "--is-inside-work-tree" *> $null
    if($LASTEXITCODE-ne 0){throw "Nao e um repositorio Git."}

    $origin=(& $git "remote" "get-url" "origin").Trim()
    $originRepo=$origin-replace '^git@github\.com:','' -replace '^https?://github\.com/','' -replace '\.git$',''
    $originRepo=$originRepo.Trim("/")
    if($originRepo-ine$repo){
      throw "origin aponta para '$originRepo', mas repository informa '$repo'."
    }

    $dirty=@()
    foreach($line in @(& $git "status" "--porcelain" "--untracked-files=all")){
      if($line.Length-lt 4){continue}
      $pathPart=$line.Substring(3).Trim('"')-replace '\\','/'
      if($pathPart-eq"dist"-or$pathPart.StartsWith("dist/")){continue}
      $dirty+=$line
    }
    if($dirty.Count){
      Write-Host ""
      Write-Host "[ATENCAO] Existem alteracoes fora de dist/:"
      $dirty|ForEach-Object{Write-Host $_}

      Write-Host ""
      Write-Host "Para garantir que os BINs publicados correspondam exatamente"
      Write-Host "ao codigo-fonte da tag, essas alteracoes precisam estar commitadas."
      Write-Host ""
      Write-Host "1 - Adicionar as alteracoes listadas, criar o commit e continuar"
      Write-Host "2 - Nao publicar agora e manter os arquivos gerados em dist/"
      Write-Host "0 - Cancelar"
      Write-Host ""
      Write-Host "Voce tambem pode digitar CANCELAR ou usar Ctrl+C."

      while($true){
        $choice=Read-Host "Opcao"
        Cancel $choice
        $choice=$choice.Trim()

        if($choice-eq "1"){
          $defaultCommit="Release v$version"

          Write-Host ""
          Write-Host "Mensagem do commit."
          Write-Host "Pressione Enter para usar: $defaultCommit"
          Write-Host "Ou digite CANCELAR para encerrar."
          $commitMessage=Read-Host ">"
          Cancel $commitMessage
          $commitMessage=$commitMessage.Trim()
          if(-not $commitMessage){$commitMessage=$defaultCommit}

          Write-Host ""
          Write-Host "A pasta dist/ nao sera adicionada ao commit."

          # Faz o stage normal do projeto. Arquivos ignorados por .gitignore,
          # como dist/, nao sao adicionados por "git add -A -- .".
          Run $git @("add","-A","--",".") "Preparando alteracoes para o commit"

          # Protecao adicional: se dist/ tiver sido rastreada em algum momento,
          # remove qualquer alteracao de dist/ do stage sem apagar os arquivos.
          $trackedDist=@(& $git "ls-files" "--" "dist")
          if($trackedDist.Count -gt 0){
            Write-Host ""
            Write-Host "Removendo dist/ do stage para manter os artefatos fora do commit..."
            & $git "reset" "-q" "HEAD" "--" "dist"
            if($LASTEXITCODE -ne 0){
              throw "Nao foi possivel remover dist/ do stage."
            }
          }

          & $git "diff" "--cached" "--quiet"
          if($LASTEXITCODE-eq 0){
            throw "Nenhuma alteracao fora de dist/ foi preparada para commit."
          }

          Run $git @("commit","-m",$commitMessage) "Criando commit '$commitMessage'"
          break
        }

        if($choice-eq "2"){
          Write-Host ""
          Write-Host "Publicacao nao realizada."
          Write-Host "Os arquivos gerados permanecem em dist/."
          throw [OperationCanceledException]::new("Publicacao adiada pelo usuario.")
        }

        if($choice-eq "0"){
          throw [OperationCanceledException]::new("Operacao cancelada pelo usuario.")
        }

        Write-Host "Opcao invalida. Use 1, 2, 0 ou CANCELAR."
      }
    }

    Run $gh @("repo","view",$repo,"--json","nameWithOwner") "Validando repositorio GitHub"
    Run $git @("push","origin","HEAD") "Enviando commits existentes"

    $tag="v$version"
    & $git "fetch" "--tags" "origin" *> $null
    if($LASTEXITCODE-ne 0){throw "Falha ao atualizar tags."}

    $head=(& $git "rev-parse" "HEAD").Trim()
    & $git "rev-parse" "-q" "--verify" "refs/tags/$tag" *> $null
    if($LASTEXITCODE-eq 0){
      $tagCommit=(& $git "rev-list" "-n" "1" $tag).Trim()
      if($tagCommit-ne$head){throw "Tag $tag ja existe em outro commit."}
    }else{
      Run $git @("tag","-a",$tag,"-m","Release $tag") "Criando tag $tag"
    }

    Run $git @("push","origin","refs/tags/$tag") "Enviando tag $tag"

    # "gh release view" retorna codigo diferente de zero quando a Release
    # ainda nao existe. Isso e esperado e nao deve cair no catch global,
    # mesmo com $ErrorActionPreference = "Stop".
    $previousErrorActionPreference=$ErrorActionPreference
    $ErrorActionPreference="Continue"
    try{
      & $gh "release" "view" $tag "--repo" $repo 1>$null 2>$null
      $releaseViewExitCode=$LASTEXITCODE
    }finally{
      $ErrorActionPreference=$previousErrorActionPreference
    }

    if($releaseViewExitCode-eq 0){
      throw "GitHub Release $tag ja existe. Altere a versao."
    }

    Write-Host ""
    Write-Host "GitHub Release $tag ainda nao existe: continuando com a publicacao."

    $assets=@($manifest)
    if($hasFw){$assets+=$fwOut}
    if($hasData){$assets+=$dataOut}
    if($hasFull){$assets+=$fullOut}

    $releaseArguments=@("release","create",$tag)+$assets+@(
      "--repo",$repo,
      "--title",$tag,
      "--generate-notes",
      "--latest",
      "--verify-tag"
    )
    Run $gh $releaseArguments "Criando GitHub Release $tag"

    Write-Host ""
    Write-Host "Release publicada:"
    Write-Host "https://github.com/$repo/releases/tag/$tag"
  }finally{
    Pop-Location
  }

  Title "Concluido"
  Write-Host "Release preparada e publicada com sucesso."
  exit 0
}
catch [OperationCanceledException]{
  Write-Host ""
  Write-Host "Operacao cancelada."
  exit 2
}
catch{
  Write-Host ""
  Write-Host "ERRO: $($_.Exception.Message)"
  if($_.InvocationInfo -and $_.InvocationInfo.PositionMessage){
    Write-Host ""
    Write-Host "Detalhes:"
    Write-Host $_.InvocationInfo.PositionMessage
  }
  Write-Host "Arquivos existentes em dist/ foram preservados para diagnostico."
  exit 1
}
