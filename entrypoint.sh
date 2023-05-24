#!/usr/bin/env bash

####################################################################
# START of GitHub Action specific code

# This script assumes that node, curl, sudo, python and jq are installed.

# If you want to run this script in a non-GitHub Action environment,
# all you'd need to do is set the following environment variables and
# delete the code below. Everything else is platform independent.
#
# Here, we're translating the GitHub action input arguments into environment variables
# for this script to use.
[[ -n "$INPUT_THEME_TOKEN" ]]       && export SHOP_THEME_TOKEN="$INPUT_THEME_TOKEN"
[[ -n "$INPUT_STORE" ]]             && export SHOP_STORE="$INPUT_STORE"
[[ -n "$INPUT_PASSWORD" ]]          && export SHOP_PASSWORD="$INPUT_PASSWORD"
[[ -n "$INPUT_THEME_ID" ]]          && export SHOP_THEME_ID="$INPUT_THEME_ID"
[[ -n "$INPUT_PRODUCT_HANDLE" ]]    && export SHOP_PRODUCT_HANDLE="$INPUT_PRODUCT_HANDLE"
[[ -n "$INPUT_COLLECTION_HANDLE" ]] && export SHOP_COLLECTION_HANDLE="$INPUT_COLLECTION_HANDLE"
[[ -n "$INPUT_THEME_ROOT" ]]        && export THEME_ROOT="$INPUT_THEME_ROOT"

# Optional, these are used by Lighthouse CI to add pass/fail checks on
# the GitHub Pull Request.
[[ -n "$INPUT_LHCI_GITHUB_APP_TOKEN" ]] && export LHCI_GITHUB_APP_TOKEN="$INPUT_LHCI_GITHUB_APP_TOKEN"
[[ -n "$INPUT_LHCI_GITHUB_TOKEN" ]]     && export LHCI_GITHUB_TOKEN="$INPUT_LHCI_GITHUB_TOKEN"

# Optional, these are used
[[ -n "$INPUT_LHCI_MIN_SCORE_PERFORMANCE" ]]   && export LHCI_MIN_SCORE_PERFORMANCE="$INPUT_LHCI_MIN_SCORE_PERFORMANCE"
[[ -n "$INPUT_LHCI_MIN_SCORE_ACCESSIBILITY" ]] && export LHCI_MIN_SCORE_ACCESSIBILITY="$INPUT_LHCI_MIN_SCORE_ACCESSIBILITY"

# Add global node bin to PATH (from the Dockerfile)
export PATH="$PATH:$npm_config_prefix/bin"

# END of GitHub Action Specific Code
####################################################################

# Portable code below
set -eou pipefail

log() {
  echo "$@" 1>&2
}

step() {
  cat <<-EOF 1>&2
	==============================
	$1
	EOF
}

is_installed() {
  # This works with scripts and programs. For more info, check
  # http://goo.gl/B9683D
  type $1 &> /dev/null 2>&1
}

api_request() {
  local url="$1"
  local err="$(mktemp)"
  local out="$(mktemp)"

  set +e
  curl -sS -f -X GET \
    "$url" \
    -H "X-Shopify-Access-Token: ${SHOP_THEME_TOKEN}" \
    1> "$out" \
    2> "$err"
  set -e

  local exit_code="$?"
  local errors="$(cat "$out" | jq '.errors')"

  if [[ $exit_code != '0' ]]; then
    log "There's been a curl error when querying the API"
    cat "$err" 1>&2
    return 1
  elif [[ $errors != 'null' ]]; then
    log "There's been an error when querying the API"
    log "$errors"
    cat "$err" 1>&2
    return 1
  fi

  cat "$out"
}

npm install -g @lhci/cli@0.12.x puppeteer

if ! is_installed shopify; then
  echo "shopify cli is not installed" >&2
  exit 1
fi

step "Configuring shopify CLI"

# Disable analytics
mkdir -p ~/.config/shopify && cat <<-YAML > ~/.config/shopify/config
[analytics]
enabled = false
YAML

# Use the $SHOP_PASSWORD defined as a Github Secret for password protected stores.
[[ -z ${SHOP_PASSWORD+x} ]] && shop_password='' || shop_password="$SHOP_PASSWORD"

step "Creating development theme"

# Fixes https://github.com/actions/checkout/issues/1169
git config --global --add safe.directory /github/workspace

step "Configuring Lighthouse CI"

if [[ -n "${SHOP_PRODUCT_HANDLE+x}" ]]; then
  product_handle="$SHOP_PRODUCT_HANDLE"
else
  log "Fetching product handle"
  product_response="$(api_request "$host/admin/api/2021-04/products.json?published_status=published&limit=1")"
  product_handle="$(echo "$product_response" | jq -r '.products[0].handle')"
  log "Using $product_handle"
fi

if [[ -n "${SHOP_COLLECTION_HANDLE+x}" ]]; then
  collection_handle="$SHOP_COLLECTION_HANDLE"
else
  log "Fetching collection handle"
  collection_response="$(api_request "$host/admin/api/2021-04/custom_collections.json?published_status=published&limit=1")"
  collection_handle="$(echo "$collection_response" | jq -r '.custom_collections[0].handle')"
  log "Using $collection_handle"
fi

# Disable redirects + preview bar
host="https://${SHOP_STORE#*(https://|http://)}"

if [[ -n "$SHOP_THEME_ID" ]]; then
  query_string="?preview_theme_id=$SHOP_THEME_ID&_fd=0&pb=0"
  preview_url="$host/$query_string"
else
  preview_url=$host
fi

min_score_performance="${LHCI_MIN_SCORE_PERFORMANCE:-0.6}"
min_score_accessibility="${LHCI_MIN_SCORE_ACCESSIBILITY:-0.9}"

log "Will run Lighthouse CI on $host"

cat <<- EOF > lighthouserc.yml
ci:
  collect:
    url:
      - "$host/$query_string"
      - "$host/products/$product_handle$query_string"
      - "$host/collections/$collection_handle$query_string"
    puppeteerScript: './setPreviewCookies.js'
    puppeteerLaunchOptions:
      args:
        - "--no-sandbox"
        - "--disable-setuid-sandbox"
        - "--disable-dev-shm-usage"
        - "--disable-gpu"
      headless: new
  upload:
    target: temporary-public-storage
  assert:
    assertions:
      "categories:performance":
        - error
        - minScore: $min_score_performance
          aggregationMethod: median-run
      "categories:accessibility":
        - error
        - minScore: $min_score_accessibility
          aggregationMethod: median-run
EOF

cat <<-EOF > setPreviewCookies.js
module.exports = async (browser) => {
  // launch browser for LHCI
  console.error('Getting a new page...');
  const page = await browser.newPage();
  // Get password cookie if password is set
  if ('$shop_password' !== '') {
    console.error('Getting password cookie...');
    await page.goto('$host/password$query_string');
    await page.waitForSelector('form[action*=password] input[type="password"]');
    await page.\$eval('form[action*=password] input[type="password"]', input => input.value = '$shop_password');
    await Promise.all([
      page.waitForNavigation(),
      page.\$eval('form[action*=password]', form => form.submit()),
    ])
  }
  // Get preview cookie
  console.error('Getting preview cookie...');
  await page.goto('$preview_url');
  // close session for next run
  await page.close();
};
EOF

step "Running Lighthouse CI"
lhci autorun
