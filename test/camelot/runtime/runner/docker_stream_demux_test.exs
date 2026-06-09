defmodule Camelot.Runtime.Runner.DockerStreamDemuxTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.DockerStreamDemux

  defp frame(stream_type, payload) do
    size = byte_size(payload)
    <<stream_type::8, 0::24, size::32-big, payload::binary>>
  end

  describe "drain/2" do
    test "extracts a single full frame" do
      f = frame(1, "hello")
      assert {["hello"], <<>>} = DockerStreamDemux.drain(<<>>, f)
    end

    test "extracts multiple full frames in one chunk" do
      buf = frame(1, "hello") <> frame(2, "world") <> frame(1, "!")
      assert {["hello", "world", "!"], <<>>} = DockerStreamDemux.drain(<<>>, buf)
    end

    test "holds a partial header until completed" do
      <<head::binary-size(3), tail::binary>> = frame(1, "abc")
      {payloads1, buf1} = DockerStreamDemux.drain(<<>>, head)
      assert payloads1 == []
      assert byte_size(buf1) == 3

      {payloads2, buf2} = DockerStreamDemux.drain(buf1, tail)
      assert payloads2 == ["abc"]
      assert buf2 == <<>>
    end

    test "holds a partial payload until completed" do
      full = frame(1, "hello world")
      <<head::binary-size(10), tail::binary>> = full

      {payloads1, buf1} = DockerStreamDemux.drain(<<>>, head)
      assert payloads1 == []
      refute buf1 == <<>>

      {payloads2, buf2} = DockerStreamDemux.drain(buf1, tail)
      assert payloads2 == ["hello world"]
      assert buf2 == <<>>
    end

    test "handles a chunk that ends mid-frame and continues with the next frame" do
      f1 = frame(1, "first")
      f2 = frame(2, "second")
      combined = f1 <> f2
      mid = byte_size(f1) + 4
      <<part1::binary-size(mid), part2::binary>> = combined

      {payloads1, buf1} = DockerStreamDemux.drain(<<>>, part1)
      assert payloads1 == ["first"]

      {payloads2, buf2} = DockerStreamDemux.drain(buf1, part2)
      assert payloads2 == ["second"]
      assert buf2 == <<>>
    end

    test "returns empty payloads when the buffer is empty" do
      assert {[], <<>>} = DockerStreamDemux.drain(<<>>, <<>>)
    end
  end
end
