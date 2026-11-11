# crystkit-http-server - local HTTP server and TLS certificate pinning for CrystKit.
#
# Adds:
# * CrystKit::Features::LocalhostServer - an in-process localhost HTTP server.
# * CrystKit::Features::CertificatePinner - SPKI-based TLS certificate pinning.
# * CrystKit::Plugins::Server - IPC plugin exposing server.start/stop/status.
#
# Usage:
#
#   require "crystkit"
#   require "crystkit-http-server"
require "crystkit"

require "./features/server"
require "./features/certificate_pinner"
require "./plugins/server"
