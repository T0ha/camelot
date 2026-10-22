#!/bin/sh
# Uploads the esbuild sourcemaps in a directory to PostHog error
# tracking, then removes them so the release never serves them.
#
# Run by `mix assets.deploy` between esbuild and phx.digest: the CLI
# injects a `//# chunkId=` comment into each bundle, which must land
# before the bundles are digested. Credentials come from the
# environment (Docker build secrets in CI):
#
#   POSTHOG_CLI_API_KEY      personal API key, "error tracking write"
#                            and "organization read" scopes
#   POSTHOG_CLI_PROJECT_ID   the PostHog project id
#   POSTHOG_CLI_HOST         optional, e.g. https://eu.posthog.com
#   POSTHOG_RELEASE_VERSION  optional, the git sha being built
#
# Without credentials nothing is uploaded and the maps are just
# deleted. A failed upload only warns: unreadable stacks are not a
# reason to stop a deploy.
set -eu

dir="$1"
cli_version="0.18.11"

if [ -z "${POSTHOG_CLI_HOST:-}" ]; then
  unset POSTHOG_CLI_HOST
fi

if [ -n "${POSTHOG_CLI_API_KEY:-}" ] && [ -n "${POSTHOG_CLI_PROJECT_ID:-}" ]; then
  if npx --yes "@posthog/cli@${cli_version}" sourcemap process \
    --directory "$dir" \
    --release-name camelot \
    ${POSTHOG_RELEASE_VERSION:+--release-version "$POSTHOG_RELEASE_VERSION"} \
    --delete-after; then
    echo "Uploaded sourcemaps in $dir to PostHog"
  else
    echo "warning: PostHog sourcemap upload failed, stacks stay minified" >&2
  fi
else
  echo "POSTHOG_CLI_API_KEY/POSTHOG_CLI_PROJECT_ID unset, sourcemaps not uploaded"
fi

# --delete-after already removed them on success; this covers a skipped
# or failed upload, so a .map file never reaches priv/static.
find "$dir" -name '*.map' -delete
find "$dir" -name "*.js" -exec perl -ni -e "print unless m{^//# sourceMappingURL=}" {} +
