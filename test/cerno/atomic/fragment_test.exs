defmodule Cerno.Atomic.FragmentTest do
  use ExUnit.Case, async: true

  alias Cerno.Atomic.Fragment

  describe "build_id/2" do
    test "produces deterministic hash from path and content" do
      id1 = Fragment.build_id("/path/to/CLAUDE.md", "some content")
      id2 = Fragment.build_id("/path/to/CLAUDE.md", "some content")
      assert id1 == id2
    end

    test "different content produces different id" do
      id1 = Fragment.build_id("/path/to/CLAUDE.md", "content A")
      id2 = Fragment.build_id("/path/to/CLAUDE.md", "content B")
      refute id1 == id2
    end

    test "different path produces different id" do
      id1 = Fragment.build_id("/path/a/CLAUDE.md", "same content")
      id2 = Fragment.build_id("/path/b/CLAUDE.md", "same content")
      refute id1 == id2
    end

    test "returns a 64-character hex string" do
      id = Fragment.build_id("/test", "content")
      assert String.length(id) == 64
      assert String.match?(id, ~r/^[0-9a-f]+$/)
    end
  end
end
