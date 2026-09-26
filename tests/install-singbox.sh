#!/usr/bin/env bash
set -Eeuo pipefail
[[ -e /.dockerenv ]] || { echo 'Disposable Docker container required'; exit 1; }
install -d /etc/apt/keyrings
curl --proto '=https' -fsSL --retry 3 --max-time 120 https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
chmod 644 /etc/apt/keyrings/sagernet.asc
cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sing-box
sing-box version
