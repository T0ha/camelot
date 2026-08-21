# Tiny reverse proxy that lets CapRover serve the Camelot docs site on a
# `docs.` hostname.
#
# CapRover rejects `docs.<caprover-root-domain>` as a *custom domain*, but it
# freely gives an app named `docs` the subdomain `docs.<root>` with auto-SSL.
# This image is that `docs` app: it forwards every request to the main Camelot
# app with the Host header rewritten to a `docs.` value, which is what
# Phoenix's docs host-route matches. See docs/docs-site-deployment.md.
FROM nginx:alpine

# Overridable per environment via the CapRover app's env vars.
#   DOCS_UPSTREAM — the main app's internal service:port on the swarm overlay
#   DOCS_HOST     — a hostname starting with "docs." (Phoenix host-matches this)
ENV DOCS_UPSTREAM=srv-captain--camelotai:4000
ENV DOCS_HOST=docs.test.camelotai.tech

# Drop the stock welcome server, otherwise it stays the default server on
# :80 (it loads first, alphabetically) and answers every request instead of
# our proxy block.
RUN rm -f /etc/nginx/conf.d/default.conf

COPY templates/docs.conf.template /etc/nginx/templates/docs.conf.template
