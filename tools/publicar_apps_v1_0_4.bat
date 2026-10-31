@echo off
setlocal EnableExtensions
set "ES32LAB_SCRIPT_DIR=%~dp0"
set "ES32LAB_SELF=%~f0"
set "ES32LAB_TMPPS=%TEMP%\es32lab_publicar_%RANDOM%_%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$l=[IO.File]::ReadAllLines($env:ES32LAB_SELF);$i=[Array]::IndexOf($l,'#===ES32LAB_POWERSHELL===');if($i-lt 0){exit 99};[IO.File]::WriteAllLines($env:ES32LAB_TMPPS,$l[($i+1)..($l.Length-1)],(New-Object Text.UTF8Encoding($true)))"
if errorlevel 1 exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File "%ES32LAB_TMPPS%"
set "RC=%ERRORLEVEL%"
del /q "%ES32LAB_TMPPS%" >nul 2>nul
exit /b %RC%
#===ES32LAB_POWERSHELL===

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2
function Title([string]$msg) { Write-Host ""; Write-Host ("="*62); Write-Host " $msg"; Write-Host ("="*62) }
function StopUser { throw [OperationCanceledException]::new("Cancelado pelo usuario.") }
function PromptSN([string]$message) {
  while($true) {
    $v = (Read-Host "$message [S] Sim / [N] Nao / [C] Cancelar").Trim().ToUpperInvariant()
    if($v -in @("C","CANCELAR")) { StopUser }
    if($v -in @("S","SIM")) { return $true }
    if($v -in @("N","NAO","NÃO")) { return $false }
    Write-Host "Digite S, N ou C. Enter nao confirma."
  }
}
function Required([string]$key,[string]$value) {
  if(-not $value) {
    while($true) {
      $value = (Read-Host "Informe $key (C para cancelar)").Trim()
      if($value.ToUpperInvariant() -in @("C","CANCELAR")) { StopUser }
      if($value) { break }
    }
  }
  return $value
}
function Val($section,[string]$key) {
  if($null -ne $section -and $section.ContainsKey($key)) { return ([string]$section[$key]).Trim() }
  return ""
}
function ReadIni([string]$file) {
  $result=@{}; $section=""
  foreach($raw in Get-Content -LiteralPath $file -Encoding UTF8) {
    $line=$raw.Trim()
    if(-not $line -or $line.StartsWith(";") -or $line.StartsWith("#")) { continue }
    if($line -match '^\[([^\]]+)\]$') {
      $section=$matches[1].Trim()
      if(-not $result.ContainsKey($section)) { $result[$section]=@{} }
    } elseif($section -and $line -match '^([^=]+)=(.*)$') {
      $result[$section][$matches[1].Trim()]= $matches[2].Trim()
    }
  }
  return ,$result
}
function FindCommand([string[]]$names) {
  foreach($name in $names) {
    $x=Get-Command $name -ErrorAction SilentlyContinue
    if($x) { return $x.Source }
  }
  return ""
}
function PlatformIO {
  $x=FindCommand @("pio","platformio")
  if($x) { return $x }
  foreach($dir in @($env:PLATFORMIO_CORE_DIR,(Join-Path $HOME ".platformio"))) {
    if(-not $dir) { continue }
    foreach($n in @("platformio.exe","pio.exe")) {
      $p=Join-Path $dir "penv\Scripts\$n"
      if(Test-Path -LiteralPath $p) { return $p }
    }
  }
  throw "PlatformIO CLI nao encontrado."
}
function Exec([string]$cmd,[string[]]$cliArgs,[string]$label) {
  Write-Host "[EXEC] $label"
  & $cmd @cliArgs | Out-Host
  if($LASTEXITCODE -ne 0) { throw "$label falhou (codigo $LASTEXITCODE)." }
}
function Sha([string]$file) { return (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() }
function SaveJson([string]$path,$obj) {
  [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $obj -Depth 12)+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
}
function AddIf($obj,[string]$key,[string]$value) { if($value) { $obj[$key]=$value } }
function AsBool([string]$value) {
  if($value -match '^(?i:true|1|yes|sim)$') { return $true }
  if($value -match '^(?i:false|0|no|nao|não)$') { return $false }
  throw "uses_wifi invalido: $value (use true ou false)"
}
function RepoSlug([string]$repo) {
  $r=$repo -replace '^https?://github\.com/','' -replace '^git@github\.com:','' -replace '\.git$',''
  $r=$r.Trim("/")
  if($r -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Repositorio de publicacao invalido: $repo" }
  return $r
}
function RawUrl([string]$repo,[string]$branch,[string]$filename) {
  $parts=@($branch -split '/' | ForEach-Object {[uri]::EscapeDataString($_)})
  $base=($parts -join '/')
  return "https://raw.githubusercontent.com/$repo/$base/dist/$([uri]::EscapeDataString($filename))"
}
function SourceDir([string]$root,[string]$envName,$envSection) {
  $filter=Val $envSection "build_src_filter"
  if($filter -match '\+<([^>]+?)/\*\*>') {
    $p=Join-Path $root ("src\"+$matches[1].Replace("/",[IO.Path]::DirectorySeparatorChar))
    if(Test-Path -LiteralPath $p -PathType Container) { return $p }
  }
  $src=Join-Path $root "src"
  if(Test-Path -LiteralPath $src) { return $src }
  throw "Pasta src/ nao encontrada."
}
function StageFile([string]$from,[string]$to) {
  Copy-Item -LiteralPath $from -Destination $to -Force
  if(-not(Test-Path -LiteralPath $to)) { throw "Copia falhou: $to" }
}
function PrepareApp([string]$root,$ini,[string]$envName,$meta,[string]$repo,[string]$branch,[string]$stage,[string]$pio) {
  Title "Preparando $envName"
  $en=$ini["env:$envName"]
  if(-not $en) { throw "Ambiente [env:$envName] ausente." }
  $src=SourceDir $root $envName $en
  $name=Required "name" (Val $meta "name")
  $developer=Required "developer" (Val $meta "developer")
  $version=Required "version" (Val $meta "version")
  $date=Val $meta "version_date"
  if(-not $date) { $date=(Get-Date -Format "yyyy-MM-dd"); Write-Host "version_date ausente: $date" }
  $description=Required "description" (Val $meta "description")
  $bn=Required "bin_name" (Val $meta "bin_name")
  $bn=$bn -replace '(?i)\.bin$',''
  if($bn -notmatch '^[a-zA-Z0-9_.-]+$') { throw "bin_name possui caracteres invalidos." }
  Write-Host "Aplicativo: $name | Versao: $version | bin_name: $bn"
  Exec $pio @("run","-e",$envName) "Compilacao PlatformIO - $envName"
  $build=Join-Path $root ".pio\build\$envName"
  $firmware=Join-Path $build "firmware.bin"
  if(-not(Test-Path -LiteralPath $firmware)) { throw "Firmware nao encontrado: $firmware" }
  $names=@{}
  $names["firmware"]="$bn.bin"
  StageFile $firmware (Join-Path $stage $names["firmware"])
  $dataFolder=Join-Path $src "data"
  if(-not(Test-Path $dataFolder -PathType Container)) {
    $dataFolder=Join-Path $root "data"
  }
  $dataFile=""
  if(Test-Path $dataFolder -PathType Container) {
    if((Get-ChildItem -LiteralPath $dataFolder -File -Recurse | Select-Object -First 1)) {
      Exec $pio @("run","-e",$envName,"-t","buildfs") "Compilando filesystem"
      $fsCandidates=@("spiffs.bin","littlefs.bin","fatfs.bin","ffat.bin")
      foreach($candidate in $fsCandidates) {
        $p=Join-Path $build $candidate
        if(Test-Path -LiteralPath $p) { $dataFile=$p; break }
      }
      if(-not $dataFile) { throw "Imagem de filesystem nao encontrada." }
      $names["data"]="$bn-data.bin"
      StageFile $dataFile (Join-Path $stage $names["data"])
    }
  }
  # A imagem FULL e obrigatoria, inclusive quando nao existe diretorio data/.
  $names["full"]="$bn-full.bin"
  $fullOutput=Join-Path $stage $names["full"]
  FullImage $build $firmware $dataFile $fullOutput
  $thumbName=""
  $thumbUrl=Val $meta "thumbnail_url"
  if($thumbUrl) {
    Write-Host "[OK] thumbnail_url definida no platformio.ini; procura local dispensada."
  } else {
    foreach($ext in @(".jpg",".jpeg",".png")) {
      $candidate=Join-Path $src "$bn-thumb$ext"
      if(Test-Path -LiteralPath $candidate) { $thumbName="$bn-thumb$ext"; StageFile $candidate (Join-Path $stage $thumbName); break }
    }
    if(-not $thumbName) {
      Write-Host "[AVISO] Thumbnail nao encontrada em $src"
      if(PromptSN "Deseja informar a thumbnail manualmente?") {
        while($true) {
          $p=(Read-Host "Caminho da imagem (C cancela, Enter ignora)").Trim().Trim('"')
          if($p.ToUpperInvariant() -in @("C","CANCELAR")) { StopUser }
          if(-not $p) { break }
          if(-not [IO.Path]::IsPathRooted($p)) { $p=Join-Path $src $p }
          if((Test-Path -LiteralPath $p -PathType Leaf) -and $p -match '\.(jpg|jpeg|png)$') {
            $ext=[IO.Path]::GetExtension($p).ToLowerInvariant()
            $thumbName="$bn-thumb$ext"
            StageFile $p (Join-Path $stage $thumbName)
            break
          }
          Write-Host "[AVISO] Informe um arquivo JPG, JPEG ou PNG existente."
        }
      }
    }
  }
  $manifestName=if($script:isComposite){"$bn-manifest.json"}else{"manifest.json"}
  $manifestUrl=Val $meta "manifest_url"
  if(-not $manifestUrl) { $manifestUrl=RawUrl $repo $branch $manifestName }
  $m=[ordered]@{
    name=$name; developer=$developer; version=$version; version_date=$date;
    description=$description; manifest_url=$manifestUrl
  }
  $wifi=Val $meta "uses_wifi"
  if($wifi) { $m["uses_wifi"]=AsBool $wifi }
  $keywords=Val $meta "keywords"
  if($keywords) { $m["keywords"]=@($keywords -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_} | Select-Object -Unique) }
  if(-not $thumbUrl -and $thumbName) { $thumbUrl=RawUrl $repo $branch $thumbName }
  AddIf $m "thumbnail_url" $thumbUrl
  foreach($field in @("video_url","website","repository")) { AddIf $m $field (Val $meta $field) }
  if(-not $m.Contains("repository")) { $m["repository"]="https://github.com/$repo" }
  foreach($kind in @("firmware","data","full")) {
    if(-not $names.ContainsKey($kind)) { continue }
    $f=Join-Path $stage $names[$kind]
    $url=Val $meta "${kind}_url"
    if(-not $url) { $url=RawUrl $repo $branch $names[$kind] }
    $m["${kind}_url"]=$url
    $m["${kind}_sha256"]=Sha $f
  }
  SaveJson (Join-Path $stage $manifestName) $m
  Write-Host "[OK] Manifesto preparado: $manifestName"
  return [pscustomobject]@{Name=$name;BinName=$bn;Manifest=$manifestName;Stage=$stage}
}
function GitState([string]$root,[string]$repo) {
  $git=FindCommand @("git")
  if(-not $git) { throw "Git nao encontrado." }
  Push-Location $root
  try {
    $origin=(& $git remote get-url origin)
    if($LASTEXITCODE -ne 0) { throw "Git remoto origin nao encontrado." }
    $remote=RepoSlug ([string]$origin)
    if($remote -ine $repo) { throw "origin aponta para $remote mas [release] repository e $repo" }
    $branch=(& $git branch --show-current).Trim()
    if($LASTEXITCODE -ne 0 -or -not $branch) { throw "Branch local invalida ou HEAD destacado." }
    return [pscustomobject]@{Tool=$git;Branch=$branch}
  } finally { Pop-Location }
}
function Publish([string]$root,[string]$repo,[string]$branch,[string]$version) {
  Title "Publicacao Git"
  $gs=GitState $root $repo
  $git=$gs.Tool
  if($gs.Branch -ne $branch) { throw "Branch mudou durante a preparacao." }
  Push-Location $root
  try {
    $status=@(& $git status --short)
    Write-Host "Arquivos alterados:"
    if($status.Count) { $status | ForEach-Object { Write-Host $_ } }
    else { Write-Host "(sem alteracoes locais)" }
    if(-not(PromptSN "Deseja criar um commit das alteracoes locais?")) {
      Write-Host "Nenhum novo commit criado."
    } else {
      if(-not $status.Count) {
        Write-Host "Nao ha alteracoes para adicionar."
      } else {
        if(-not(PromptSN "Confirmar git add -A (inclui exclusoes e arquivos fora de dist/)?")) { Write-Host "Stage nao realizado." }
        else {
          Exec $git @("add","-A") "Adicionando arquivos ao Git"
          # dist pode estar ignorada por projetos antigos: inclui explicitamente.
          if(Test-Path -LiteralPath (Join-Path $root "dist")) {
            Exec $git @("add","-f","-A","--","dist") "Incluindo dist/ mesmo se estiver no .gitignore"
          }
          & $git diff --cached --quiet
          if($LASTEXITCODE -eq 1) {
            $suggestion="Atualiza aplicativos v$version"
            Write-Host "Mensagem sugerida: $suggestion"
            $message=Read-Host "Mensagem de commit (Enter aceita; C cancela)"
            if($message.Trim().ToUpperInvariant() -in @("C","CANCELAR")) { StopUser }
            if(-not $message.Trim()) { $message=$suggestion }
            Exec $git @("commit","-m",$message) "Registrando commit"
          } elseif($LASTEXITCODE -ne 0) { throw "Falha ao verificar arquivos em stage." }
        }
      }
    }
    if(PromptSN "Executar git push origin $branch agora?") {
      Exec $git @("fetch","origin",$branch) "Consultando branch remota"
      & $git merge-base --is-ancestor "origin/$branch" HEAD
      if($LASTEXITCODE -ne 0) { throw "Branch remota divergiu. Resolva manualmente antes de enviar." }
      Exec $git @("push","origin","HEAD:refs/heads/$branch") "Enviando commits ao GitHub"
      Write-Host "[OK] Publicacao finalizada."
    } else { Write-Host "Push nao realizado. Arquivos locais mantidos." }
  } finally { Pop-Location }
}
function Run($exe,$cliArgs,$label){ Exec $exe $cliArgs $label }
function Exe($names){ return FindCommand $names }
function Num($v){$x=$v.Trim().ToLowerInvariant();if($x.StartsWith("0x")){return [Convert]::ToInt64($x.Substring(2),16)};if($x.EndsWith("k")){return [int64]([double]$x.TrimEnd("k")*1024)};if($x.EndsWith("m")){return [int64]([double]$x.TrimEnd("m")*1024*1024)};return [int64]$x}
function Hex($n){return ("0x{0:X}"-f$n)}
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
    & $py @a4 | Out-Host
    if($LASTEXITCODE-ne 0){
      Remove-Item $out -Force -ErrorAction SilentlyContinue
      $a5=@($esp,"--chip","esp32","merge-bin","-o",$out,"--pad-to-size",($mb.ToString()+"MB"))+$pairs
      & $py @a5 | Out-Host
    }
    if($LASTEXITCODE-ne 0-or-not(Test-Path $out)){throw "Falha ao gerar imagem FULL."}
    Write-Host "Imagem FULL gerada com $mb MB."
  }finally{Remove-Item $csv -Force -ErrorAction SilentlyContinue}
}
try {
  $root=Split-Path -Parent ($env:ES32LAB_SCRIPT_DIR.TrimEnd([char]'\'))
  $iniPath=Join-Path $root "platformio.ini"
  if(-not(Test-Path -LiteralPath $iniPath)) { throw "platformio.ini nao encontrado em $root" }
  $ini=ReadIni $iniPath
  if(-not $ini.ContainsKey("release")) { throw "Secao [release] nao encontrada." }
  $releases=@($ini.Keys | Where-Object { $_ -match '^release_.+' } | Sort-Object)
  $script:isComposite=($releases.Count -gt 0)
  $pubRepo=Required "[release] repository" (Val $ini["release"] "repository")
  $pubRepo=RepoSlug $pubRepo
  $globalVersion=Val $ini["release"] "version"
  if(-not $globalVersion) { $globalVersion="1.0.0" }
  $gitInfo=GitState $root $pubRepo
  $branch=$gitInfo.Branch
  $envs=@($ini.Keys | Where-Object { $_ -match '^env:.+' } | ForEach-Object {$_.Substring(4)} | Sort-Object)
  if(-not $envs.Count) { throw "Nenhum ambiente [env:nome] encontrado." }
  $selected=@()
  if($script:isComposite) {
    $defaults=Val $ini["platformio"] "default_envs"
    if($defaults) {
      $selected=@($defaults -split '[,\s]+' | Where-Object { $_ })
      foreach($e in $selected) {
        if(-not $ini.ContainsKey("release_$e")) { throw "Metadados [release_$e] ausentes." }
        if($e -notin $envs) { throw "Ambiente [env:$e] nao encontrado." }
      }
    } else {
      $selected=@($envs | Where-Object { $ini.ContainsKey("release_$_") })
      Write-Host "Nenhum default_envs definido. Aplicativos: $($selected -join ', ')"
      if(-not(PromptSN "Compilar TODOS os $($selected.Count) aplicativos?")) { StopUser }
    }
  } else {
    $defaults=Val $ini["platformio"] "default_envs"
    if($defaults) { $selected=@($defaults -split '[,\s]+' | Where-Object { $_ }) }
    else { $selected=@($envs); if($selected.Count -gt 1) { throw "Modo simples tem varios ambientes. Defina default_envs." } }
    if($selected.Count -ne 1) { throw "Modo simples requer exatamente um ambiente." }
  }
  Title "ES Developer - Publicar Apps v1.0.4"
  Write-Host "Modo: $(if($script:isComposite){'Composto'}else{'Simples'})"
  Write-Host "Repositorio: $pubRepo"
  Write-Host "Branch: $branch"
  Write-Host "Versao para commit: $globalVersion"
  Write-Host "Ambientes: $($selected -join ', ')"
  Write-Host ""
  Write-Host "1 - Preparar e publicar"
  Write-Host "2 - Apenas preparar"
  Write-Host "3 - Apenas publicar dist/"
  Write-Host "0 - Cancelar"
  $choice=(Read-Host "Opcao (Enter = 1)").Trim()
  if(-not $choice) { $choice="1" }
  if($choice -in @("0","C","CANCELAR")) { StopUser }
  if($choice -notin @("1","2","3")) { throw "Opcao invalida." }
  $dist=Join-Path $root "dist"
  if($choice -ne "3") {
    $pio=PlatformIO
    $stageRoot=Join-Path $root ".pio\publicar_apps_stage"
    if(Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    try {
      Push-Location $root
      try {
        $prepared=@()
        foreach($e in $selected) {
          $meta=if($script:isComposite){$ini["release_$e"]}else{$ini["release"]}
          $appStage=Join-Path $stageRoot $e
          New-Item -ItemType Directory -Path $appStage -Force | Out-Null
          $prepared+=PrepareApp $root $ini $e $meta $pubRepo $branch $appStage $pio
        }
      } finally { Pop-Location }
      if(-not(Test-Path -LiteralPath $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
      Title "Atualizando dist/"
      foreach($app in $prepared) {
        $oldPrefix=$app.BinName
        if($script:isComposite) {
          Get-ChildItem -LiteralPath $dist -File | Where-Object {
            $_.Name -eq "$oldPrefix.bin" -or $_.Name -in @("$oldPrefix-data.bin","$oldPrefix-full.bin","$oldPrefix-manifest.json") -or $_.Name -match ("^"+[regex]::Escape($oldPrefix)+"-thumb\.(jpg|jpeg|png)$")
          } | Remove-Item -Force
        }
        foreach($f in @(Get-ChildItem -LiteralPath $app.Stage -File)) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dist $f.Name) -Force }
        Write-Host "[OK] $($app.Name)"
      }
      Write-Host "[OK] Preparacao local concluida."
    } finally {
      if(Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
    }
  }
  if($choice -eq "2") { Write-Host "Sem publicacao, conforme solicitado."; exit 0 }
  if(-not(Test-Path -LiteralPath $dist)) { throw "Pasta dist/ nao existe." }
  Write-Host "Arquivos existentes em dist/: $(@(Get-ChildItem -LiteralPath $dist -File).Count)"
  Publish $root $pubRepo $branch $globalVersion
  Write-Host "Processo encerrado."
  exit 0
} catch [OperationCanceledException] {
  Write-Host "[CANCELADO] Operacao encerrada. Alteracoes ja realizadas nao foram revertidas."
  exit 2
} catch {
  Write-Host "[ERRO] $($_.Exception.Message)"
  if($_.InvocationInfo.PositionMessage) { Write-Host $_.InvocationInfo.PositionMessage }
  exit 1
}
