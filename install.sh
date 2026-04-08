#!/usr/bin/env bash
set -euo pipefail

mkdir -p /mnt/server
cd /mnt/server

if [[ ! -f "index.php" ]]; then
  cat > index.php <<'PHP'
<?php
phpinfo();
PHP
fi
