defmodule Camelot.Accounts.SshKeygenTest do
  use ExUnit.Case, async: true

  alias Camelot.Accounts.SshKeygen

  describe "generate/1" do
    test "returns a map with all expected fields" do
      key = SshKeygen.generate()

      assert %{
               algorithm: "ed25519",
               private_key: priv,
               public_key: pub,
               fingerprint: "SHA256:" <> _
             } = key

      assert is_binary(priv)
      assert is_binary(pub)
    end

    test "private key is in OpenSSH v1 format and parseable by ssh-keygen" do
      %{private_key: priv, public_key: pub} = SshKeygen.generate()

      assert String.starts_with?(priv, "-----BEGIN OPENSSH PRIVATE KEY-----\n")
      assert String.ends_with?(priv, "-----END OPENSSH PRIVATE KEY-----\n")

      tmp = Path.join(System.tmp_dir!(), "camelot_kg_#{:rand.uniform(1_000_000)}")

      try do
        File.write!(tmp, priv)
        File.chmod!(tmp, 0o600)
        {derived, 0} = System.cmd("ssh-keygen", ["-y", "-f", tmp])
        # derived strips trailing newline isn't guaranteed; pub_key has a
        # trailing newline, derived from ssh-keygen has one too — compare
        # the bare authorized_keys line (sans comment).
        assert derived |> String.trim() |> ssh_line() == pub |> String.trim() |> ssh_line()
      after
        File.rm(tmp)
      end
    end

    test "fingerprint matches ssh-keygen -lf output" do
      %{private_key: priv, fingerprint: fp} = SshKeygen.generate()

      tmp = Path.join(System.tmp_dir!(), "camelot_fp_#{:rand.uniform(1_000_000)}")

      try do
        File.write!(tmp, priv)
        File.chmod!(tmp, 0o600)
        {out, 0} = System.cmd("ssh-keygen", ["-lf", tmp])
        assert out =~ fp
      after
        File.rm(tmp)
      end
    end

    test "public key is a single-line authorized_keys entry" do
      %{public_key: pub} = SshKeygen.generate()
      # `ssh-ed25519 AAAA... comment\n`
      [line | rest] = String.split(pub, "\n", trim: true)
      assert rest == []
      assert [type, b64 | _] = String.split(line, " ", parts: 3)
      assert type == "ssh-ed25519"
      assert {:ok, _bytes} = Base.decode64(b64)
    end

    test "comment defaults to camelot@<host>" do
      %{public_key: pub} = SshKeygen.generate()
      assert pub =~ ~r/\scamelot@/
    end

    test "custom comment is honoured" do
      %{public_key: pub, private_key: priv} = SshKeygen.generate(comment: "abc@def")
      assert pub =~ "abc@def"
      # Comment also embedded in the private key block — verify by
      # round-tripping through ssh-keygen.
      tmp = Path.join(System.tmp_dir!(), "camelot_cmt_#{:rand.uniform(1_000_000)}")

      try do
        File.write!(tmp, priv)
        File.chmod!(tmp, 0o600)
        {out, 0} = System.cmd("ssh-keygen", ["-y", "-f", tmp])
        assert out =~ "ssh-ed25519"
      after
        File.rm(tmp)
      end
    end

    test "successive calls produce distinct keys" do
      a = SshKeygen.generate()
      b = SshKeygen.generate()
      assert a.private_key != b.private_key
      assert a.public_key != b.public_key
      assert a.fingerprint != b.fingerprint
    end
  end

  defp ssh_line(line) do
    # First two space-separated tokens — `ssh-ed25519 <base64>` —
    # drop the comment for cross-comparison.
    line |> String.split(" ", parts: 3) |> Enum.take(2) |> Enum.join(" ")
  end
end
