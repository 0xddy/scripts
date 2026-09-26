param([switch]$SkipKernelInstall)
$ErrorActionPreference = 'Stop'
$ProjectDir = Split-Path $PSScriptRoot -Parent
$ResultsDir = Join-Path $ProjectDir 'test-results'
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
function Invoke-Docker {
    & docker @args
    if ($LASTEXITCODE -ne 0) { throw "Docker failed ($LASTEXITCODE): $args" }
}
foreach ($DebianVersion in @('12', '13')) {
    $ContainerName = "vps-tune-test-$DebianVersion-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $ImageTag = "vps-tune-test:$DebianVersion"
    Invoke-Docker build --build-arg "DEBIAN_VERSION=$DebianVersion" -f (Join-Path $PSScriptRoot 'Dockerfile') -t $ImageTag $ProjectDir
    try {
        # No privileged mode, host networking, host /proc mounts or writable bind mounts.
        Invoke-Docker run -d --name $ContainerName --ulimit nofile=1048576:1048576 $ImageTag sleep infinity
        if (-not $SkipKernelInstall) {
            Invoke-Docker exec $ContainerName bash -c 'bash /src/vps-tune.sh --container-test > /tmp/kernel-install.log 2>&1; rc=$?; tail -n 35 /tmp/kernel-install.log; exit $rc'
        }
        Invoke-Docker exec $ContainerName bash -c 'bash /src/tests/integration.sh > /tmp/integration.log 2>&1; rc=$?; cat /tmp/integration.log; exit $rc'
        Invoke-Docker exec $ContainerName bash -c 'bash /src/tests/smart-bandwidth.sh > /tmp/smart-bandwidth.log 2>&1; rc=$?; cat /tmp/smart-bandwidth.log; exit $rc'
        Invoke-Docker exec $ContainerName bash -c 'python3 /src/tests/menu.py > /tmp/menu.log 2>&1; rc=$?; cat /tmp/menu.log; exit $rc'
        Invoke-Docker exec $ContainerName bash -c 'bash /src/tests/cake.sh > /tmp/cake.log 2>&1; rc=$?; cat /tmp/cake.log; exit $rc'
        Invoke-Docker exec $ContainerName bash /src/tests/prepare-runtime-fixtures.sh
        Invoke-Docker exec $ContainerName bash -c 'bash /src/tests/isolated-runtime.sh > /tmp/isolated-runtime.log 2>&1; rc=$?; cat /tmp/isolated-runtime.log; exit $rc'
        Invoke-Docker exec $ContainerName bash -c 'bash /src/tests/install-singbox.sh > /tmp/singbox-install.log 2>&1; rc=$?; tail -n 15 /tmp/singbox-install.log; exit $rc'
        Invoke-Docker exec $ContainerName bash /src/vps-tune.sh apply --container-test --kernel skip --smart-bandwidth --smart-profile overseas-bdp --bandwidth-mbps 1000
        Invoke-Docker exec $ContainerName bash -c 'python3 /src/tests/proxy-smoke.py > /tmp/proxy-smoke.log 2>&1; rc=$?; cat /tmp/proxy-smoke.log; exit $rc'
    }
    finally {
        foreach ($LogName in @('kernel-install', 'integration', 'smart-bandwidth', 'menu', 'cake', 'isolated-runtime', 'singbox-install', 'proxy-smoke')) {
            & docker exec $ContainerName test -f "/tmp/$LogName.log"
            if ($LASTEXITCODE -eq 0) {
                & docker cp "${ContainerName}:/tmp/$LogName.log" (Join-Path $ResultsDir "debian-$DebianVersion-$LogName.log")
            }
        }
        & docker rm -f $ContainerName | Out-Null
    }
}
Write-Host "Debian 12/13 tests passed. Logs: $ResultsDir"
