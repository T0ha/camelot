defmodule Camelot.Accounts.SshKeygen do
  @moduledoc """
  Pure SSH keypair generator. Produces Ed25519 keys in the formats
  Camelot stores and ships:

    * `:private_key` — OpenSSH v1 PEM (`-----BEGIN OPENSSH PRIVATE
      KEY-----`), what `~/.ssh/id_ed25519` expects.
    * `:public_key` — single-line `authorized_keys` entry, for pasting
      into GitHub / authorized_keys files.
    * `:fingerprint` — `SHA256:…` exactly as `ssh-keygen -lf` reports.

  Uses Erlang's `:public_key` and `:crypto` stdlib modules. We roll the
  OpenSSH v1 serialisation by hand because `:ssh_file.encode/2` writes a
  non-conformant private key blob for Ed25519 (the spec requires the
  private section to carry `priv32 ++ pub32` as one 64-byte string;
  OTP's encoder emits only the 32-byte private half).
  """

  @magic "openssh-key-v1\0"
  # OpenSSH's "none" cipher block size.
  @block_size 8

  @type key :: %{
          algorithm: String.t(),
          private_key: String.t(),
          public_key: String.t(),
          fingerprint: String.t()
        }

  @doc """
  Generate a fresh Ed25519 keypair.

  Options:

    * `:comment` — string embedded in both the private and public key
      blocks. Defaults to `camelot@<hostname>`.
  """
  @spec generate(keyword()) :: key()
  def generate(opts \\ []) do
    comment = Keyword.get_lazy(opts, :comment, &default_comment/0)

    {:ECPrivateKey, _ver, priv32, _params, pub32, _attrs} =
      :public_key.generate_key({:namedCurve, :ed25519})

    %{
      algorithm: "ed25519",
      private_key: encode_private_key(priv32, pub32, comment),
      public_key: encode_public_key(pub32, comment),
      fingerprint: fingerprint(pub32)
    }
  end

  defp default_comment do
    {:ok, host} = :inet.gethostname()
    "camelot@#{host}"
  end

  # OpenSSH PROTOCOL.key v1, unencrypted single-key form:
  #
  #   "openssh-key-v1\0"
  #   string  ciphername  ("none")
  #   string  kdfname     ("none")
  #   string  kdfoptions  ("")
  #   uint32  numkeys     (1)
  #   string  publickey_blob
  #   string  encrypted_blob   ; "encrypted" with the none-cipher = identity
  #     uint32 check
  #     uint32 check    ; must equal the first
  #     string keytype
  #     string pub
  #     string priv ++ pub        ; 64 bytes for ed25519
  #     string comment
  #     1, 2, 3, … pad to a multiple of cipher block size
  defp encode_private_key(priv32, pub32, comment) do
    check = :crypto.strong_rand_bytes(4)

    pub_blob = ssh_string("ssh-ed25519") <> ssh_string(pub32)

    inner =
      check <>
        check <>
        ssh_string("ssh-ed25519") <>
        ssh_string(pub32) <>
        ssh_string(priv32 <> pub32) <>
        ssh_string(comment)

    body =
      @magic <>
        ssh_string("none") <>
        ssh_string("none") <>
        ssh_string("") <>
        <<1::32>> <>
        ssh_string(pub_blob) <>
        ssh_string(pad(inner))

    "-----BEGIN OPENSSH PRIVATE KEY-----\n" <>
      wrap_lines(Base.encode64(body), 70) <>
      "\n-----END OPENSSH PRIVATE KEY-----\n"
  end

  defp encode_public_key(pub32, comment) do
    blob = ssh_string("ssh-ed25519") <> ssh_string(pub32)
    "ssh-ed25519 #{Base.encode64(blob)} #{comment}\n"
  end

  defp fingerprint(pub32) do
    blob = ssh_string("ssh-ed25519") <> ssh_string(pub32)
    "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)
  end

  defp ssh_string(bin) when is_binary(bin), do: <<byte_size(bin)::32, bin::binary>>

  defp pad(bin) do
    case rem(byte_size(bin), @block_size) do
      0 -> bin
      n -> bin <> :erlang.list_to_binary(Enum.to_list(1..(@block_size - n)))
    end
  end

  defp wrap_lines(s, n) do
    s
    |> String.to_charlist()
    |> Enum.chunk_every(n)
    |> Enum.map_join("\n", &List.to_string/1)
  end
end
