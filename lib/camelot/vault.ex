defmodule Camelot.Vault do
  @moduledoc """
  Cloak vault used by `AshCloak` to encrypt sensitive
  attributes (API keys, OAuth tokens) at rest.

  Configured at runtime from `ENCRYPTION_KEY` (32-byte
  base64). In prod the boot fails hard if the env var is
  missing. In dev/test a stable default key is used so
  the application starts without operator setup.
  """
  use Cloak.Vault, otp_app: :camelot
end
