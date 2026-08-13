Set-StrictMode -Version Latest

function Get-ProjectConfig {
    param([string] $Root)

    $config = Import-PowerShellDataFile (Join-Path $Root 'config.psd1')
    $localConfigPath = Join-Path $Root 'config.local.psd1'
    if (Test-Path $localConfigPath) {
        $localConfig = Import-PowerShellDataFile $localConfigPath
        foreach ($key in $localConfig.Keys) {
            $config[$key] = $localConfig[$key]
        }
    }
    if ([string]::IsNullOrWhiteSpace($config.CameraToolsPath)) {
        $config.CameraToolsPath = Join-Path $env:APPDATA 'BambuStudio\cameratools'
    }
    if ([string]::IsNullOrWhiteSpace($config.CameraUrlFile)) {
        $config.CameraUrlFile = Join-Path $config.CameraToolsPath 'url.txt'
    }
    return $config
}

function Wait-HttpReady {
    param(
        [string] $Uri,
        [int] $TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return Invoke-RestMethod -Uri $Uri -TimeoutSec 2
        } catch {
            if ((Get-Date) -ge $deadline) {
                throw "Timed out waiting for $Uri"
            }
            [Threading.Thread]::Sleep(250)
        }
    } while ($true)
}

function Test-ProcessId {
    param([int] $ProcessId)

    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function New-NginxRuntimeConfig {
    param(
        [string] $TemplatePath,
        [string] $OutputPath,
        [string] $NginxDirectory,
        [string] $BasePath,
        [int] $HttpPort,
        [ValidateSet('Legacy', 'Multi')]
        [string] $DeploymentMode = 'Legacy',
        [string] $ErrorLogPath = 'logs/error.log',
        [string] $PidPath = 'logs/nginx.pid'
    )

    $normalizedBasePath = if ([string]::IsNullOrWhiteSpace($BasePath) -or $BasePath -eq '/') {
        '/'
    } else {
        '/' + $BasePath.Trim('/') + '/'
    }
    if ($normalizedBasePath -ne '/' -and $normalizedBasePath -notmatch '^/(?:[A-Za-z0-9._~-]+/)+$') {
        throw "BasePath '$normalizedBasePath' contains characters that cannot be used in the nginx location."
    }

    $basePathLocations = ''
    if ($normalizedBasePath -ne '/') {
        $basePathWithoutSlash = $normalizedBasePath.TrimEnd('/')
        $basePathLocations = @'
        location = __BASE_PATH_WITHOUT_SLASH__ {
            return 308 __BASE_PATH__;
        }

        location __BASE_PATH__ {
            proxy_pass http://127.0.0.1:__HTTP_PORT__/;
            proxy_redirect ~^/(.*)$ __BASE_PATH__$1;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }
'@
        $basePathLocations = $basePathLocations.Replace('__BASE_PATH_WITHOUT_SLASH__', $basePathWithoutSlash).Replace('__BASE_PATH__', $normalizedBasePath).Replace('__HTTP_PORT__', [string]$HttpPort)
    }

    $template = [IO.File]::ReadAllText($TemplatePath)
    if (-not $template.Contains('        # BASE_PATH_LOCATIONS')) {
        throw "nginx template '$TemplatePath' does not contain the base-path marker."
    }
    if (-not $template.Contains('        # DEPLOYMENT_MODE_LOCATIONS')) {
        throw "nginx template '$TemplatePath' does not contain the deployment-mode marker."
    }
    $deploymentModeLocations = if ($DeploymentMode -eq 'Legacy') {
@'
        location = /api/config {
            default_type application/json;
            return 200 '{"mode":"legacy"}';
        }
'@
    } else {
        ''
    }
    $mimeTypesPath = (Join-Path $NginxDirectory 'conf\mime.types').Replace('\', '/')
    $normalizedErrorLogPath = $ErrorLogPath.Replace('\', '/')
    $normalizedPidPath = $PidPath.Replace('\', '/')
    $runtimeConfig = $template.Replace('error_log logs/error.log warn;', "error_log `"$normalizedErrorLogPath`" warn;").Replace('pid logs/nginx.pid;', "pid `"$normalizedPidPath`";").Replace('    include mime.types;', "    include `"$mimeTypesPath`";").Replace('        listen 8090;', "        listen $HttpPort;").Replace('        # BASE_PATH_LOCATIONS', $basePathLocations).Replace('        # DEPLOYMENT_MODE_LOCATIONS', $deploymentModeLocations)
    [IO.File]::WriteAllText($OutputPath, $runtimeConfig, (New-Object Text.UTF8Encoding($false)))
    return $normalizedBasePath
}

function Get-NodeToolchain {
    param(
        [string] $Root,
        [version] $MinimumVersion,
        [version] $ExactVersion
    )

    $candidates = @()
    $localNode = Join-Path $Root 'tools\node\node.exe'
    $localNpm = Join-Path $Root 'tools\node\npm.cmd'
    if ((Test-Path $localNode) -and (Test-Path $localNpm)) {
        $candidates += [pscustomobject]@{ Node = $localNode; Npm = $localNpm }
    }

    $systemNode = Get-Command node.exe -ErrorAction SilentlyContinue
    $systemNpm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($systemNode -and $systemNpm) {
        $candidates += [pscustomobject]@{ Node = $systemNode.Source; Npm = $systemNpm.Source }
    }

    foreach ($candidate in $candidates) {
        try {
            $installedVersion = [version]((& $candidate.Node --version).TrimStart('v'))
            $matchesVersion = if ($ExactVersion) {
                $installedVersion -eq $ExactVersion
            } else {
                $installedVersion -ge $MinimumVersion
            }
            if ($matchesVersion) {
                return [pscustomobject]@{
                    Node = $candidate.Node
                    Npm = $candidate.Npm
                    Version = $installedVersion
                }
            }
        } catch {
            continue
        }
    }
    return $null
}