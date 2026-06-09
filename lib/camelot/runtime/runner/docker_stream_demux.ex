defmodule Camelot.Runtime.Runner.DockerStreamDemux do
  @moduledoc """
  Demultiplexes Docker's multiplexed stdout/stderr stream
  format (`Tty: false`). Each frame on the wire is:

      <stream_type:1>  <pad:3>  <size:32 big-endian>  <payload:size>

  where stream_type is 0 (stdin, unused here), 1 (stdout),
  or 2 (stderr). A single HTTP chunk may end mid-header
  or mid-payload, so this module is stateful per call:
  `drain/2` takes a leftover buffer plus a new chunk and
  returns `{full_payloads, new_buffer}`.

  Stream-type byte is currently discarded — we forward
  stdout and stderr as one stream because downstream
  parsers and log_log writers treat them uniformly.
  """

  @doc """
  Append `chunk` to `buffer`, peel off as many complete
  frames as possible, return them as a list of payload
  binaries plus any trailing partial bytes for the next
  call.
  """
  @spec drain(binary(), binary()) :: {[binary()], binary()}
  def drain(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    do_drain(buffer <> chunk, [])
  end

  defp do_drain(<<_stype::8, _pad::24, size::32-big, rest::binary>> = buf, acc) do
    case rest do
      <<payload::binary-size(size), tail::binary>> ->
        do_drain(tail, [payload | acc])

      _ ->
        {Enum.reverse(acc), buf}
    end
  end

  defp do_drain(buf, acc), do: {Enum.reverse(acc), buf}
end
